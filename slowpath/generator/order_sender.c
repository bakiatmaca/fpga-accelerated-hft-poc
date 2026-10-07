// FPGA signal (33B, UDP) -> OUCH 5.0 Enter Order over SoupBinTCP 3.00
// gcc -O2 -Wall -Wextra order_sender.c -o order_sender
// onload:  onload --profile=latency ./order_sender -b ...
//
// Layouts verified against (nasdaqtrader.com):
//   OUCH 5.0 Order Entry Specification (rev 1.05, 10/7/2025), section 2.1
//   SoupBinTCP 3.00, sections 1.1, 1.3, 2.2, 2.3
//
// Mapping (signal -> order):
//   side   : 'B' -> 'S', 'S' -> 'B' (anything else: no order)
//   qty    : signal shares, must be 1..999,999 (OUCH limit)
//   symbol : 8 bytes copied as-is (both sides: left-justified, space padded)
//   price  : 4B ITCH price zero-extended to 8B (both: 4 implied decimals)
//   TIF    : '3' (IOC)

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <poll.h>
#include <netdb.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

/* ---- FPGA signal record (from csignal_receiver.c), big-endian ----
 *  0 magic 1 | 1 type 1 | 2 timestamp 6 | 8 order ref 8
 * 16 side 1  | 17 shares 4 | 21 stock 8 | 29 price 4
 */
#define SIG_LEN        33
#define SIG_MAGIC      0xBB
#define SIG_SIDE       16
#define SIG_SHARES     17
#define SIG_STOCK      21
#define SIG_PRICE      29

/* ---- OUCH 5.0 Enter Order (offsets inside the OUCH message) ---- */
#define O_TYPE         0   /* 'O'                         */
#define O_USERREF      1   /* 4  UserRefNum               */
#define O_SIDE         5   /* 1  B/S/T/E                  */
#define O_QTY          6   /* 4  Integer                  */
#define O_SYMBOL       10  /* 8  Alpha                    */
#define O_PRICE        18  /* 8  Price                    */
#define O_TIF          26  /* 1  '0','3','5','6','E'      */
#define O_DISPLAY      27  /* 1  Y/N/A                    */
#define O_CAPACITY     28  /* 1  A/P/R/O                  */
#define O_ISO          29  /* 1  Y/N                      */
#define O_CROSS        30  /* 1  N/O/C/H/S/R/E/A          */
#define O_CLORDID      31  /* 14 Alpha                    */
#define O_APPLEN       45  /* 2  Integer                  */
#define O_LEN          47  /* no optional appendage       */

#define SOUP_HDR       3   /* 2B length + 1B packet type  */
#define PKT_LEN        (SOUP_HDR + O_LEN)   /* 50 bytes on the wire */

#define OUCH_MAX_PRICE 0x7735939CU  /* $199,999.9900; above this = market order */
#define OUCH_MAX_QTY   999999U      /* "greater than zero and less than 1,000,000" */

#define NS_PER_MS      1000000LL
#define HB_INTERVAL_NS (800 * NS_PER_MS)    /* spec: send if >1 s idle  */
#define RX_TIMEOUT_NS  (15000 * NS_PER_MS)  /* server HB is every 1 s   */
#define SETUP_LIMIT_NS (30000 * NS_PER_MS)  /* login + account query    */

enum { ST_LOGIN_WAIT, ST_QUERY_WAIT, ST_READY };

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static int      g_tfd = -1, g_ufd = -1;
static int      g_state = ST_LOGIN_WAIT;
static int      g_dry = 0, g_verbose = 0, g_busy = 0;
static int      g_have_ref = 0;
static uint32_t g_next_ref = 0;
static uint64_t g_max_orders = 0;          /* 0 = unlimited */
static int64_t  g_last_tx = 0, g_last_rx = 0;

static uint64_t n_sent, n_skipped, n_acc, n_rej, n_exec, n_canc;

static uint8_t  g_pkt[PKT_LEN];            /* pre-built order template */
static int      g_nologin = 0, g_raw = 0, g_print = 0;
static const char *g_why = "";            /* why the last signal produced no order */
static const uint8_t *g_tx = g_pkt;        /* what goes on the wire per order */
static size_t   g_txlen = PKT_LEN;

static inline int64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}
static inline uint32_t be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static inline uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static inline void put_be32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}

static int send_all(const uint8_t *b, size_t len)
{
    while (len) {
        ssize_t n = send(g_tfd, b, len, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("send");
            return -1;
        }
        b += n; len -= (size_t)n;
    }
    g_last_tx = mono_ns();
    return 0;
}

static void hexdump(const uint8_t *b, size_t n)
{
    for (size_t i = 0; i < n; i++) printf("%02x%s", b[i], (i + 1 == n) ? "\n" : " ");
}

/* ------------------------------------------------------------------ */
/* Hot path: one signal record -> one Enter Order                      */
/* ------------------------------------------------------------------ */
static void build_template(char display, char capacity)
{
    uint8_t *o = g_pkt + SOUP_HDR;
    g_pkt[0] = 0; g_pkt[1] = 1 + O_LEN;    /* length excludes itself, includes type */
    g_pkt[2] = 'U';                        /* Unsequenced Data */
    memset(o, 0, O_LEN);
    o[O_TYPE]     = 'O';
    o[O_TIF]      = '3';                   /* IOC */
    o[O_DISPLAY]  = (uint8_t)display;
    o[O_CAPACITY] = (uint8_t)capacity;
    o[O_ISO]      = 'N';
    o[O_CROSS]    = 'N';                   /* continuous market */
    memcpy(o + O_CLORDID, "FPGA0000000000", 14);
    /* O_PRICE high 4 bytes and O_APPLEN stay zero */
}

/* returns 1 = order sent, 0 = no order (see g_why), -1 = fatal */
static inline int on_signal_core(const uint8_t *m)
{
    uint8_t side;
    if (m[0] != SIG_MAGIC)          { g_why = "bad magic"; n_skipped++; return 0; }
    if (m[SIG_SIDE] == 'B')         side = 'S';
    else if (m[SIG_SIDE] == 'S')    side = 'B';
    else                            { g_why = "side is not B or S"; n_skipped++; return 0; }

    uint32_t qty = be32(m + SIG_SHARES);
    uint32_t px  = be32(m + SIG_PRICE);
    if (qty == 0 || qty > OUCH_MAX_QTY || px == 0 || px > OUCH_MAX_PRICE) {
        g_why = "shares or price outside OUCH limits";
        n_skipped++;
        return 0;
    }
    if (g_max_orders && n_sent >= g_max_orders) { g_why = "-m limit reached"; n_skipped++; return 0; }
    uint64_t oref = ((uint64_t)be32(m + 8) << 32) | be32(m + 12);   /* signal OrderRef */
    if (oref > 99999999999999ULL) { g_why = "order ref does not fit 14-digit ClOrdID"; n_skipped++; return 0; }
    if (g_next_ref == UINT32_MAX) {
        fprintf(stderr, "UserRefNum exhausted\n");
        return -1;
    }

    uint8_t *o   = g_pkt + SOUP_HDR;
    uint32_t ref = g_next_ref;
    put_be32(o + O_USERREF, ref);
    o[O_SIDE] = side;
    memcpy(o + O_QTY,       m + SIG_SHARES, 4);   /* both big-endian */
    memcpy(o + O_SYMBOL,    m + SIG_STOCK,  8);
    memcpy(o + O_PRICE + 4, m + SIG_PRICE,  4);
    uint64_t v = oref;                            /* ClOrdID = signal OrderRef, 14 decimal digits */
    for (int i = 13; i >= 0; i--) { o[O_CLORDID + i] = (uint8_t)('0' + v % 10); v /= 10; }

    if (g_dry) hexdump(g_tx, g_txlen);
    else if (send_all(g_tx, g_txlen) < 0) return -1;

    g_next_ref = ref + 1;
    n_sent++;
    if (g_verbose)
        fprintf(stderr, "order ref=%u side=%c qty=%u sym=%.8s px=%u\n",
                ref, side, qty, (const char *)(m + SIG_STOCK), px);
    return 1;
}

/* ---- -p: signal dump + latency, same output as csignal_receiver.c ---- */
#define NS_PER_SEC 1000000000LL
#define NS_PER_DAY (86400LL * NS_PER_SEC)

static inline int64_t real_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * NS_PER_SEC + ts.tv_nsec;
}

static uint64_t be_load(const uint8_t *p, int n)
{
    uint64_t v = 0;
    for (int i = 0; i < n; i++) v = (v << 8) | p[i];
    return v;
}

static void fmt_tod(char *out, size_t sz, int64_t ns)
{
    int64_t s = ns / NS_PER_SEC;
    snprintf(out, sz, "%02lld:%02lld:%02lld.%09lld",
             (long long)(s / 3600), (long long)((s / 60) % 60),
             (long long)(s % 60), (long long)(ns % NS_PER_SEC));
}

static void print_signal(const uint8_t *m, int64_t now)   /* now = ns since UTC midnight */
{
    uint64_t ts     = be_load(m + 2, 6);
    uint64_t oref   = be_load(m + 8, 8);
    uint32_t shares = (uint32_t)be_load(m + SIG_SHARES, 4);
    uint32_t price  = (uint32_t)be_load(m + SIG_PRICE, 4);
    char stock[9], ts_str[32], now_str[32];
    for (int i = 0; i < 8; i++) {
        uint8_t c = m[SIG_STOCK + i];
        stock[i] = (c >= 0x20 && c <= 0x7e) ? (char)c : '.';
    }
    stock[8] = '\0';

    int64_t diff_ns = now - (int64_t)ts;
    if (diff_ns < -NS_PER_DAY / 2)      diff_ns += NS_PER_DAY;
    else if (diff_ns > NS_PER_DAY / 2)  diff_ns -= NS_PER_DAY;
    const char *sign = diff_ns < 0 ? "-" : "";
    int64_t adiff = diff_ns < 0 ? -diff_ns : diff_ns;
    fmt_tod(ts_str, sizeof ts_str, (int64_t)ts);
    fmt_tod(now_str, sizeof now_str, now);

    printf("Magic:     0x%02x\n"
           "MsgType:   0x%02x\n"
           "Timestamp: 0x%012llx (%llu) %s UTC\n"
           "OrderRef:  0x%016llx (%llu)\n"
           "Side:      %c\n"
           "Shares:    0x%08x (%u)\n"
           "Stock:     %s\n"
           "Price:     0x%08x (%u)\n"
           "Now:       %lld ns %s UTC\n"
           "Latency:   %s%lld.%03lld us (%lld ns)\n",
           m[0], m[1],
           (unsigned long long)ts, (unsigned long long)ts, ts_str,
           (unsigned long long)oref, (unsigned long long)oref,
           (m[SIG_SIDE] >= 0x20 && m[SIG_SIDE] <= 0x7e) ? m[SIG_SIDE] : '.',
           shares, shares, stock, price, price,
           (long long)now, now_str,
           sign, (long long)(adiff / 1000LL), (long long)(adiff % 1000LL), (long long)diff_ns);
}

/* rx_real: CLOCK_REALTIME taken right after recv() (only when -p is set) */
static inline int on_signal_rec(const uint8_t *m, int64_t rx_real)
{
    uint32_t ref = g_next_ref;
    int r = on_signal_core(m);                 /* order goes out before anything is printed */
    if (g_print && r >= 0) {
        int64_t d = real_ns() - rx_real;
        print_signal(m, rx_real % NS_PER_DAY);
        if (r) printf("Order:     sent ref=%u, %lld.%03lld us after receive\n",
                      ref, (long long)(d / 1000), (long long)(d % 1000));
        else   printf("Order:     not sent (%s)\n", g_why);
        puts("-----------------------------");
    }
    return r < 0 ? -1 : 0;
}

static int handle_datagram(const uint8_t *buf, ssize_t len, int64_t rx_real)
{
    ssize_t off = 0;
    while (len - off >= SIG_LEN) {
        if (on_signal_rec(buf + off, rx_real) < 0) return -1;
        off += SIG_LEN;
    }
    if (len - off > 0) n_skipped++;
    return 0;
}

/* ------------------------------------------------------------------ */
/* SoupBinTCP session                                                  */
/* ------------------------------------------------------------------ */
static void pad_right(uint8_t *dst, size_t w, const char *s)
{
    size_t n = strlen(s);
    memset(dst, ' ', w);
    memcpy(dst, s, n < w ? n : w);
}

static int send_login(const char *user, const char *pass, const char *session, const char *seq)
{
    uint8_t p[2 + 47];
    size_t  sl = strlen(seq);
    p[0] = 0; p[1] = 47; p[2] = 'L';
    pad_right(p + 3,  6,  user);
    pad_right(p + 9,  10, pass);
    pad_right(p + 19, 10, session);              /* blank = currently active session */
    memset(p + 29, ' ', 20);                     /* ASCII number, left padded */
    memcpy(p + 29 + 20 - sl, seq, sl);
    return send_all(p, sizeof p);
}

static int send_account_query(void)
{
    static const uint8_t p[] = { 0, 4, 'U', 'Q', 0, 0 };   /* 'Q' + AppendageLength=0 */
    return send_all(p, sizeof p);
}

static void on_ouch(const uint8_t *m, size_t len)
{
    if (len < 1) return;
    switch (m[0]) {
    case 'Q':                                   /* Account Query Response */
        if (g_state == ST_QUERY_WAIT && len >= 13) {
            g_next_ref = be32(m + 9);
            g_have_ref = 1;
        }
        break;
    case 'A': n_acc++;  break;
    case 'E': n_exec++; break;
    case 'C': n_canc++; break;
    case 'J':
        n_rej++;
        if (len >= 15)
            fprintf(stderr, "OUCH reject: ref=%u reason=0x%04x\n", be32(m + 9), be16(m + 13));
        break;
    default: break;
    }
    if (g_verbose && len >= 13 && m[0] != 'S')
        fprintf(stderr, "ouch<- '%c' ref=%u\n", m[0], be32(m + 9));
}

static int on_soup(uint8_t type, const uint8_t *pl, size_t len)
{
    switch (type) {
    case 'A':
        if (g_state != ST_LOGIN_WAIT) break;
        if (len >= 30)
            fprintf(stderr, "login accepted: session='%.10s' next_seq='%.20s'\n",
                    (const char *)pl, (const char *)(pl + 10));
        if (g_have_ref) g_state = ST_READY;
        else {
            if (send_account_query() < 0) return -1;
            g_state = ST_QUERY_WAIT;
        }
        break;
    case 'J':
        fprintf(stderr, "login rejected: code='%c'\n", len ? pl[0] : '?');
        return -1;
    case 'S':
        on_ouch(pl, len);
        if (g_state == ST_QUERY_WAIT && g_have_ref) g_state = ST_READY;
        break;
    case 'H': break;
    case 'Z':
        fprintf(stderr, "end of session\n");
        return -1;
    case '+':
        if (g_verbose) fprintf(stderr, "debug: %.*s\n", (int)len, (const char *)pl);
        break;
    default: break;
    }
    return 0;
}

static uint8_t g_rx[1 << 17];
static size_t  g_rxlen;

static int tcp_drain(void)
{
    for (;;) {
        ssize_t n = recv(g_tfd, g_rx + g_rxlen, sizeof g_rx - g_rxlen, MSG_DONTWAIT);
        if (n == 0) { fprintf(stderr, "server closed connection\n"); return -1; }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
            if (errno == EINTR) continue;
            perror("recv(tcp)");
            return -1;
        }
        g_rxlen += (size_t)n;
        g_last_rx = mono_ns();
        if (g_raw) { g_rxlen = 0; continue; }     /* raw mode: replies are discarded */

        size_t off = 0;
        while (g_rxlen - off >= 2) {
            size_t plen = be16(g_rx + off);
            if (plen == 0) { fprintf(stderr, "soup: zero length packet\n"); return -1; }
            if (g_rxlen - off < 2 + plen) break;
            if (on_soup(g_rx[off + 2], g_rx + off + 3, plen - 1) < 0) return -1;
            off += 2 + plen;
        }
        if (off) {
            memmove(g_rx, g_rx + off, g_rxlen - off);
            g_rxlen -= off;
        }
    }
}

static int tcp_connect(const char *host, const char *port)
{
    struct addrinfo hints, *res;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int rc = getaddrinfo(host, port, &hints, &res);
    if (rc) { fprintf(stderr, "getaddrinfo: %s\n", gai_strerror(rc)); return -1; }
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { perror("socket"); freeaddrinfo(res); return -1; }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
        perror("connect"); close(fd); freeaddrinfo(res); return -1;
    }
    freeaddrinfo(res);
    return fd;
}

static int udp_open(int port)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket(udp)"); return -1; }
    int one = 1, rcvbuf = 8 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); close(fd); return -1; }
    return fd;
}

static void usage(const char *p)
{
    fprintf(stderr,
        "usage: %s -H host -P port -u user -w pass [options]\n"
        "  -l port   UDP port for FPGA signals (default 1235)\n"
        "  -S sess   SoupBinTCP requested session (default blank = current)\n"
        "  -q seq    requested sequence number (default 1)\n"
        "  -r ref    first UserRefNum; if omitted, ask host via Account Query\n"
        "  -d c      Display  Y|N|A   (default Y)\n"
        "  -c c      Capacity A|P|R|O (default P)\n"
        "  -m n      stop sending after n orders (default unlimited)\n"
        "  -x        no login: skip SoupBinTCP Login Request (-u/-w not needed)\n"
        "  -R        raw: no login and no SoupBinTCP at all; send only the 47-byte\n"
        "            Enter Order, no heartbeat/logout, replies discarded (-r default 1)\n"
        "  -p        print each parsed signal and its latency (as csignal_receiver),\n"
        "            plus receive-to-send time of the order; printed after the send\n"
        "  -b        busy-spin instead of poll()\n"
        "  -n        dry run: no TCP, hex-dump packets to stdout\n"
        "  -v        verbose\n", p);
}

int main(int argc, char **argv)
{
    const char *host = NULL, *port = NULL, *user = NULL, *pass = NULL;
    const char *session = "", *seq = "1";
    int  uport = 1235, opt;
    char display = 'Y', capacity = 'P';

    while ((opt = getopt(argc, argv, "H:P:u:w:l:S:q:r:d:c:m:xRpbnvh")) != -1) {
        switch (opt) {
        case 'H': host = optarg; break;
        case 'P': port = optarg; break;
        case 'u': user = optarg; break;
        case 'w': pass = optarg; break;
        case 'l': uport = atoi(optarg); break;
        case 'S': session = optarg; break;
        case 'q': seq = optarg; break;
        case 'r': g_next_ref = (uint32_t)strtoul(optarg, NULL, 10); g_have_ref = 1; break;
        case 'd': display = optarg[0]; break;
        case 'c': capacity = optarg[0]; break;
        case 'm': g_max_orders = strtoull(optarg, NULL, 10); break;
        case 'x': g_nologin = 1; break;
        case 'R': g_raw = 1; g_nologin = 1; break;
        case 'p': g_print = 1; break;
        case 'b': g_busy = 1; break;
        case 'n': g_dry = 1; break;
        case 'v': g_verbose = 1; break;
        default:  usage(argv[0]); return 2;
        }
    }
    if (!strchr("YNA", display) || !strchr("APRO", capacity)) { usage(argv[0]); return 2; }
    if (g_have_ref && g_next_ref == 0) { fprintf(stderr, "UserRefNum begins at 1\n"); return 2; }
    if (g_raw) {
        g_tx = g_pkt + SOUP_HDR; g_txlen = O_LEN;
        if (!g_have_ref) { g_next_ref = 1; g_have_ref = 1; }
    }
    if (g_dry) {
        if (!g_have_ref) { g_next_ref = 1; g_have_ref = 1; }
        g_state = ST_READY;
    } else {
        if (!host || !port || (!g_nologin && (!user || !pass))) { usage(argv[0]); return 2; }
        if (!g_nologin &&
            (strlen(user) > 6 || strlen(pass) > 10 || strlen(session) > 10 || strlen(seq) > 20)) {
            fprintf(stderr, "field too long (user<=6, pass<=10, session<=10, seq<=20)\n");
            return 2;
        }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sig;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    build_template(display, capacity);

    int64_t t0 = mono_ns();
    g_last_tx = g_last_rx = t0;
    if (!g_dry) {
        if ((g_tfd = tcp_connect(host, port)) < 0) return 1;
        if (!g_nologin) {
            if (send_login(user, pass, session, seq) < 0) return 1;
        } else if (g_have_ref) {
            g_state = ST_READY;
        } else {                                  /* -x without -r: still ask the host */
            if (send_account_query() < 0) return 1;
            g_state = ST_QUERY_WAIT;
        }
    }

    static uint8_t buf[65536];
    unsigned spin = 0;
    int rc = 0;

    while (!g_stop) {
        /* Signals are only accepted once the session is ready, so nothing stale is queued */
        if (g_state == ST_READY && g_ufd < 0) {
            if (g_next_ref == 0) { fprintf(stderr, "host returned NextUserRefNum=0; use -r\n"); rc = 1; break; }
            if ((g_ufd = udp_open(uport)) < 0) { rc = 1; break; }
            fprintf(stderr, "ready: UDP %d, next UserRefNum %u%s\n",
                    uport, g_next_ref, g_dry ? " (dry run)" : "");
        }

        if (!g_busy) {
            struct pollfd p[2];
            nfds_t n = 0;
            if (g_ufd >= 0) { p[n].fd = g_ufd; p[n].events = POLLIN; n++; }
            if (g_tfd >= 0) { p[n].fd = g_tfd; p[n].events = POLLIN; n++; }
            poll(p, n, 100);
        }

        if (g_ufd >= 0) {
            ssize_t n;
            int got = 0;
            while ((n = recv(g_ufd, buf, sizeof buf, MSG_DONTWAIT)) >= 0) {
                int64_t rx_real = g_print ? real_ns() : 0;
                if (handle_datagram(buf, n, rx_real) < 0) { rc = 1; goto out; }
                got = 1;
            }
            if (got && g_print) fflush(stdout);
        }

        if (g_tfd >= 0) {
            if (tcp_drain() < 0) { rc = 1; break; }

            if (!g_busy || (++spin & 0x3ff) == 0) {
                int64_t now = mono_ns();
                if (!g_raw && g_state != ST_LOGIN_WAIT && now - g_last_tx >= HB_INTERVAL_NS) {
                    static const uint8_t hb[] = { 0, 1, 'R' };
                    if (send_all(hb, sizeof hb) < 0) { rc = 1; break; }
                }
                if (!g_raw && now - g_last_rx > RX_TIMEOUT_NS) {
                    fprintf(stderr, "no data from server for 15 s\n"); rc = 1; break;
                }
                if (g_state != ST_READY && now - t0 > SETUP_LIMIT_NS) {
                    fprintf(stderr, "session setup timed out (%s)\n",
                            g_state == ST_LOGIN_WAIT ? "no Login Accepted" : "no Account Query Response; use -r");
                    rc = 1; break;
                }
            }
        }
    }
out:
    if (g_tfd >= 0) {
        static const uint8_t lo[] = { 0, 1, 'O' };   /* Logout Request */
        if (!g_raw && g_state != ST_LOGIN_WAIT) send(g_tfd, lo, sizeof lo, MSG_NOSIGNAL);
        close(g_tfd);
    }
    if (g_ufd >= 0) close(g_ufd);
    fflush(stdout);
    fprintf(stderr, "sent=%llu skipped=%llu | accepted=%llu rejected=%llu executed=%llu canceled=%llu\n",
            (unsigned long long)n_sent, (unsigned long long)n_skipped, (unsigned long long)n_acc,
            (unsigned long long)n_rej, (unsigned long long)n_exec, (unsigned long long)n_canc);
    return rc;
}
