/*
# itch_replay.c
 
# zlib needed (Debian/Ubuntu: zlib1g-dev, RHEL: zlib-devel)
gcc -O2 -march=native -Wall -Wextra -o itch_replay itch_replay.c -lz

# All messages
./itch_replay -f 01302019.NASDAQ_ITCH50.gz -d 192.168.2.28 -p 1234

# Only Add Order ('A')
./itch_replay -f 01302019.NASDAQ_ITCH50.gz -d 192.168.2.28 -p 1234 -a

# rate limit
./itch_replay -f 01302019.NASDAQ_ITCH50.gz -d 192.168.2.28 -p 1234 -a -r 50000

*/

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <getopt.h>
#include <netinet/in.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#define RD_BUF_SZ     (8u << 20)
#define GZ_BUF_SZ     (1u << 20)
#define SNDBUF_SZ     (8 << 20)
#define BATCH_MAX     512
#define SLOT_SZ       2048
#define SESSION_LEN   10
#define MOLD_HDR_SZ   20
#define MAX_PAYLOAD   (SLOT_SZ - MOLD_HDR_SZ - 2)
#define ITCH_TS_OFF   5
#define ITCH_TS_LEN   6
#define NS_PER_SEC    1000000000ULL
#define NS_PER_DAY    (86400ULL * NS_PER_SEC)
#define PACE_SLICE_NS 1000000ULL
#define MAX_LAG_NS    10000000ULL

static const char SESSION[SESSION_LEN] = { 'S','E','S','S','I','O','N','0','0','1' };

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static inline uint64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * NS_PER_SEC + (uint64_t)ts.tv_nsec;
}

static void sleep_until_ns(uint64_t t)
{
    struct timespec ts = {
        .tv_sec  = (time_t)(t / NS_PER_SEC),
        .tv_nsec = (long)(t % NS_PER_SEC)
    };
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR && !g_stop)
        ;
}

static inline uint64_t itch_ts_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ((uint64_t)ts.tv_sec * NS_PER_SEC + (uint64_t)ts.tv_nsec) % NS_PER_DAY;
}

static inline void put_be48(uint8_t *p, uint64_t v)
{
    p[0] = (uint8_t)(v >> 40);
    p[1] = (uint8_t)(v >> 32);
    p[2] = (uint8_t)(v >> 24);
    p[3] = (uint8_t)(v >> 16);
    p[4] = (uint8_t)(v >> 8);
    p[5] = (uint8_t)v;
}

typedef struct {
    gzFile   gz;
    uint8_t *buf;
    size_t   pos;
    size_t   len;
    int      eof;
} reader_t;

static int reader_fill(reader_t *r, size_t need)
{
    if (r->len - r->pos >= need)
        return 1;

    if (r->pos) {
        memmove(r->buf, r->buf + r->pos, r->len - r->pos);
        r->len -= r->pos;
        r->pos = 0;
    }

    while (!r->eof && r->len < need) {
        int n = gzread(r->gz, r->buf + r->len, (unsigned)(RD_BUF_SZ - r->len));
        if (n < 0) {
            int err;
            fprintf(stderr, "gzread: %s\n", gzerror(r->gz, &err));
            r->eof = 1;
            break;
        }
        if (n == 0) {
            r->eof = 1;
            break;
        }
        r->len += (size_t)n;
    }

    return r->len - r->pos >= need;
}

typedef struct {
    int            fd;
    uint8_t      (*slots)[SLOT_SZ];
    struct mmsghdr msgs[BATCH_MAX];
    struct iovec   iov[BATCH_MAX];
    unsigned       n;
    unsigned       batch_limit;
    uint64_t       seq;
    uint64_t       sent_pkts;
    uint64_t       sent_msgs;
    double         ns_per_msg;
    uint64_t       pace_start_ns;
} sender_t;

static int sender_init(sender_t *s, int fd, uint64_t start_seq, double rate)
{
    memset(s, 0, sizeof(*s));
    s->fd  = fd;
    s->seq = start_seq;
    s->slots = aligned_alloc(64, (size_t)BATCH_MAX * SLOT_SZ);
    if (!s->slots)
        return -1;

    for (unsigned i = 0; i < BATCH_MAX; i++) {
        memcpy(s->slots[i], SESSION, SESSION_LEN);
        s->iov[i].iov_base = s->slots[i];
        s->msgs[i].msg_hdr.msg_iov    = &s->iov[i];
        s->msgs[i].msg_hdr.msg_iovlen = 1;
    }

    if (rate > 0.0) {
        double per_slice = rate * (double)PACE_SLICE_NS / (double)NS_PER_SEC;
        s->batch_limit = per_slice < 1.0 ? 1u
                       : per_slice > BATCH_MAX ? BATCH_MAX
                       : (unsigned)per_slice;
        s->ns_per_msg = (double)NS_PER_SEC / rate;
    } else {
        s->batch_limit = BATCH_MAX;
        s->ns_per_msg = 0.0;
    }
    return 0;
}

static void sender_pace(sender_t *s)
{
    uint64_t now = mono_ns();

    if (s->pace_start_ns == 0) {
        s->pace_start_ns = now;
        return;
    }

    uint64_t offset   = (uint64_t)((double)s->sent_msgs * s->ns_per_msg);
    uint64_t deadline = s->pace_start_ns + offset;

    if (now < deadline)
        sleep_until_ns(deadline);
    else if (now - deadline > MAX_LAG_NS)
        s->pace_start_ns = now - offset;
}

static int sender_flush(sender_t *s)
{
    unsigned off = 0;

    if (s->n == 0)
        return 0;

    if (s->ns_per_msg > 0.0)
        sender_pace(s);

    for (unsigned i = 0; i < s->n; i++) {
        uint8_t *msg = s->slots[i] + MOLD_HDR_SZ + 2;
        size_t   len = s->iov[i].iov_len - MOLD_HDR_SZ - 2;
        if (msg[0] == 'A' && len >= ITCH_TS_OFF + ITCH_TS_LEN)
            put_be48(msg + ITCH_TS_OFF, itch_ts_now());
    }

    while (off < s->n) {
        int r = sendmmsg(s->fd, &s->msgs[off], s->n - off, 0);
        if (r < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == ENOBUFS) {
                sched_yield();
                continue;
            }
            perror("sendmmsg");
            return -1;
        }
        off += (unsigned)r;
    }

    s->sent_pkts += s->n;
    s->sent_msgs += s->n;
    s->n = 0;
    return 0;
}

static inline int sender_add(sender_t *s, const uint8_t *payload, uint16_t len)
{
    uint8_t *p = s->slots[s->n];
    uint64_t seq_be = htobe64(s->seq);
    uint16_t cnt_be = htobe16(1);
    uint16_t len_be = htobe16(len);

    memcpy(p + 10, &seq_be, 8);
    memcpy(p + 18, &cnt_be, 2);
    memcpy(p + 20, &len_be, 2);
    memcpy(p + 22, payload, len);

    s->iov[s->n].iov_len = (size_t)MOLD_HDR_SZ + 2 + len;
    s->seq++;

    if (++s->n >= s->batch_limit)
        return sender_flush(s);
    return 0;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s -f <dump_file> -d <dst_ip> -p <dst_port> [-a] [-r <msg_per_sec>]\n"
            "  -f, --file      BinaryFILE ITCH 5.0 dump (.gz or plain)\n"
            "  -d, --dst-ip    destination IPv4 address\n"
            "  -p, --dst-port  destination UDP port\n"
            "  -a, --add-only  send only Add Order ('A') messages\n"
            "  -r, --rate      target messages per second (0 = unlimited, default)\n",
            prog);
}

int main(int argc, char **argv)
{
    const char *file   = NULL;
    const char *dst_ip = NULL;
    long dst_port = -1;
    int add_only = 0;
    double rate = 0.0;

    static const struct option opts[] = {
        { "file",     required_argument, 0, 'f' },
        { "dst-ip",   required_argument, 0, 'd' },
        { "dst-port", required_argument, 0, 'p' },
        { "add-only", no_argument,       0, 'a' },
        { "rate",     required_argument, 0, 'r' },
        { "help",     no_argument,       0, 'h' },
        { 0, 0, 0, 0 }
    };

    int c;
    while ((c = getopt_long(argc, argv, "f:d:p:ar:h", opts, NULL)) != -1) {
        switch (c) {
        case 'f': file = optarg; break;
        case 'd': dst_ip = optarg; break;
        case 'p': dst_port = strtol(optarg, NULL, 10); break;
        case 'a': add_only = 1; break;
        case 'r': rate = strtod(optarg, NULL); break;
        default:  usage(argv[0]); return 1;
        }
    }

    if (!file || !dst_ip || dst_port <= 0 || dst_port > 65535 || rate < 0.0) {
        usage(argv[0]);
        return 1;
    }

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port   = htons((uint16_t)dst_port);
    if (inet_pton(AF_INET, dst_ip, &dst.sin_addr) != 1) {
        fprintf(stderr, "invalid destination ip: %s\n", dst_ip);
        return 1;
    }

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    int sndbuf = SNDBUF_SZ;
    if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf)) < 0)
        perror("setsockopt SO_SNDBUF");

    if (connect(fd, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
        perror("connect");
        close(fd);
        return 1;
    }

    reader_t rd;
    memset(&rd, 0, sizeof(rd));
    rd.gz = gzopen(file, "rb");
    if (!rd.gz) {
        fprintf(stderr, "cannot open %s: %s\n", file, strerror(errno));
        close(fd);
        return 1;
    }
    gzbuffer(rd.gz, GZ_BUF_SZ);

    rd.buf = malloc(RD_BUF_SZ);
    sender_t tx;
    if (!rd.buf || sender_init(&tx, fd, 1, rate) < 0) {
        fprintf(stderr, "out of memory\n");
        gzclose(rd.gz);
        close(fd);
        return 1;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    uint64_t skipped = 0, oversized = 0;
    int rc = 0;
    uint64_t t0 = mono_ns();

    while (!g_stop) {
        if (!reader_fill(&rd, 2))
            break;

        uint16_t len = (uint16_t)((rd.buf[rd.pos] << 8) | rd.buf[rd.pos + 1]);
        rd.pos += 2;
        if (len == 0)
            continue;

        if (!reader_fill(&rd, len))
            break;

        const uint8_t *payload = rd.buf + rd.pos;
        rd.pos += len;

        if (add_only && payload[0] != 'A') {
            skipped++;
            continue;
        }
        if (len > MAX_PAYLOAD) {
            oversized++;
            continue;
        }
        if (sender_add(&tx, payload, len) < 0) {
            rc = 1;
            break;
        }
    }

    if (rc == 0 && !g_stop && sender_flush(&tx) < 0)
        rc = 1;

    double dt = (double)(mono_ns() - t0) / (double)NS_PER_SEC;

    if (g_stop)
        fprintf(stderr, "\ninterrupted\n");

    printf("sent %llu msg / %llu pkt (%llu skipped, %llu oversized) in %.2fs",
           (unsigned long long)tx.sent_msgs, (unsigned long long)tx.sent_pkts,
           (unsigned long long)skipped, (unsigned long long)oversized, dt);
    if (dt > 0)
        printf(" -> %.0f msg/s", (double)tx.sent_msgs / dt);
    if (rate > 0.0)
        printf(" (target %.0f msg/s)", rate);
    printf("\n");

    free(tx.slots);
    free(rd.buf);
    gzclose(rd.gz);
    close(fd);
    return rc;
}
