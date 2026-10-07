// FPGA signal signal receiver parser
// gcc -O2 csignal_receiver.c -o csignal_receiver

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define MSG_LEN     33
#define RECV_BUF    65536
#define SOCK_RCVBUF (8 * 1024 * 1024)
#define NS_PER_SEC  1000000000LL
#define NS_PER_DAY  (86400LL * NS_PER_SEC)

/* Message layout (byte offset, size), big-endian:
 *  0  magic 1 | 1  type 1  | 2  timestamp(ms) 6 | 8  order ref 8
 *  16 side 1  | 17 shares 4 | 21 stock 8        | 29 price 4
 */

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

static inline uint64_t be_load(const uint8_t *p, int n)
{
    uint64_t v = 0;
    for (int i = 0; i < n; i++)
        v = (v << 8) | p[i];
    return v;
}

static inline int64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ((int64_t)ts.tv_sec * NS_PER_SEC + ts.tv_nsec) % NS_PER_DAY;
}

static void fmt_tod(char *out, size_t sz, int64_t ns)
{
    int64_t s = ns / NS_PER_SEC;
    snprintf(out, sz, "%02lld:%02lld:%02lld.%09lld",
             (long long)(s / 3600), (long long)((s / 60) % 60),
             (long long)(s % 60), (long long)(ns % NS_PER_SEC));
}


static void parse_msg(const uint8_t *m, int64_t now)
{
    uint8_t  magic  = m[0];
    uint8_t  mtype  = m[1];
    uint64_t ts     = be_load(m + 2, 6);
    uint64_t oref   = be_load(m + 8, 8);
    uint8_t  side   = m[16];
    uint32_t shares = (uint32_t)be_load(m + 17, 4);
    uint32_t price  = (uint32_t)be_load(m + 29, 4);

    char stock[9];
    for (int i = 0; i < 8; i++) {
        uint8_t c = m[21 + i];
        stock[i] = (c >= 0x20 && c <= 0x7e) ? (char)c : '.';
    }
    stock[8] = '\0';

    char side_str[2] = { (char)side, '\0' };

    int64_t diff_ns = now - (int64_t)ts;
    if (diff_ns < -NS_PER_DAY / 2)
        diff_ns += NS_PER_DAY;
    else if (diff_ns > NS_PER_DAY / 2)
        diff_ns -= NS_PER_DAY;

    const char *sign = diff_ns < 0 ? "-" : "";
    int64_t adiff = diff_ns < 0 ? -diff_ns : diff_ns;

    char ts_str[32], now_str[32];
    fmt_tod(ts_str, sizeof ts_str, (int64_t)ts);
    fmt_tod(now_str, sizeof now_str, now);

    printf("Magic:     0x%02x\n"
           "MsgType:   0x%02x\n"
           "Timestamp: 0x%012llx (%llu) %s UTC\n"
           "OrderRef:  0x%016llx (%llu)\n"
           "Side:      %s\n"
           "Shares:    0x%08x (%u)\n"
           "Stock:     %s\n"
           "Price:     0x%08x (%u)\n"
           "Now:       %lld ns %s UTC\n"
           "Latency:   %s%lld.%03lld us (%lld ns)\n"
           "-----------------------------\n",
           magic, mtype,
           (unsigned long long)ts, (unsigned long long)ts, ts_str,
           (unsigned long long)oref, (unsigned long long)oref,
           side_str,
           shares, shares,
           stock,
           price, price,
           (long long)now, now_str,
           sign, (long long)(adiff / 1000LL), (long long)(adiff % 1000LL),
           (long long)diff_ns);
}

static void handle_datagram(const uint8_t *buf, ssize_t len, int64_t now)
{
    ssize_t off = 0;
    while (len - off >= MSG_LEN) {
        parse_msg(buf + off, now);
        off += MSG_LEN;
    }
    if (len - off > 0)
        fprintf(stderr, "warning: skipped %zd bytes of incomplete data\n", len - off);
}

int main(int argc, char **argv)
{
    int port = (argc > 1) ? atoi(argv[1]) : 1235;

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;  /* no SA_RESTART so recv() returns EINTR */
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);

    int rcvbuf = SOCK_RCVBUF;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf) < 0)
        perror("setsockopt(SO_RCVBUF)");

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("bind");
        close(fd);
        return 1;
    }
    fprintf(stderr, "Listening on UDP port %d...\n", port);

    static char outbuf[1 << 16];
    setvbuf(stdout, outbuf, _IOFBF, sizeof outbuf);

    static uint8_t buf[RECV_BUF];

    while (!g_stop) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("recv");
            break;
        }
        handle_datagram(buf, n, now_ns());

        /* Drain queued datagrams without blocking, then flush once */
        for (;;) {
            n = recv(fd, buf, sizeof buf, MSG_DONTWAIT);
            if (n < 0) break;
            handle_datagram(buf, n, now_ns());
        }

        fflush(stdout);
    }

    fflush(stdout);
    close(fd);
    return 0;
}
