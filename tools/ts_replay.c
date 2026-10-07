// ts_replay.c
// pcap ITCH 5.0 with MoldUDP64 data
// gcc -O2 -o ts_replay ts_replay.c -lpcap
// ./ts_replay enp0s31f6 rewritten_nq_bx_all_batch.pcap
//


#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <pcap.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <netinet/in.h>

#ifndef ETH_P_ALL
#define ETH_P_ALL 0x0003
#endif

#define ETH_HLEN        14
#define ETHERTYPE_IPV4  0x0800
#define IPPROTO_UDP_N   17

// Timestamp field inside the ITCH message (from the start of the message data)
#define ITCH_TS_OFFSET  5     // from the start of the message data
#define ITCH_TS_LEN     6     // 48-bit
#define ITCH_MIN_MSGLEN (ITCH_TS_OFFSET + ITCH_TS_LEN)  // 11

// MoldUDP64 frame fields
#define MOLD_HDR_LEN        20   // Session(10) + SeqNum(8) + MsgCount(2)
#define MOLD_MSGCOUNT_OFF   18   // message count offset within the header
#define MOLD_MSGLEN_LEN     2    // length field at the start of each block
#define MOLD_HEARTBEAT      0x0000  // message count 0 = heartbeat
#define MOLD_ENDOFSESSION   0xFFFF  // message count 0xFFFF = end of session

// --- Timestamp mode selection ---
// 0 = ns since midnight (classic ITCH; local/UTC setting below)
// 1 = monotonic ns since program start (relative, small value, 48-bit safe)
// 2 = low 48 bits of ns since epoch (WARNING: overflows 48-bit; only meaningful if
//     both sides use the same masking logic)
#define TS_MODE 3

// For TS_MODE 0: local midnight (1) / UTC (0)
#define USE_LOCAL_MIDNIGHT 1

// Set this to 1 if you only want to update a specific message type (e.g. 'A'):
#define FILTER_BY_MSGTYPE 0
#define ITCH_MSGTYPE      'A'

// Write the same timestamp to all messages in the same UDP packet (1),
// or take the current value separately for each message (0):
#define SAME_TS_PER_PACKET 0

// Pace according to the original timing in the pcap (like the tcpreplay default).
// Set to 0 to send as fast as possible (topspeed).
#define PACE_ORIGINAL_TIMING 1

// Print the written TS value of the first N packets to stderr (for verification). 0 = off.
#define DEBUG_PRINT_FIRST 5

// Base time for program start (used in TS_MODE 1)
static uint64_t g_base_ns = 0;

static uint64_t now_realtime_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static uint64_t now_monotonic_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// Produces the 48-bit value to be written to the ITCH Timestamp field
static uint64_t make_timestamp(void) {
#if TS_MODE == 0
    // ns since midnight
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
  #if USE_LOCAL_MIDNIGHT
    localtime_r(&ts.tv_sec, &tm);
  #else
    gmtime_r(&ts.tv_sec, &tm);
  #endif
    uint64_t sec = (uint64_t)tm.tm_hour * 3600ULL
                 + (uint64_t)tm.tm_min  * 60ULL
                 + (uint64_t)tm.tm_sec;
    return sec * 1000000000ULL + (uint64_t)ts.tv_nsec;

#elif TS_MODE == 1
    // Monotonic ns since program start (48-bit safe, monotonically increasing)
    return now_monotonic_ns() - g_base_ns;

#elif TS_MODE == 2
    // Low 48 bits of ns since epoch (overflows - use with care)
    return now_realtime_ns() & 0xFFFFFFFFFFFFULL;
#elif TS_MODE == 3
    // Milliseconds since epoch — same axis as Python int(time.time()*1000)
    {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return (uint64_t)ts.tv_sec * 1000ULL
             + (uint64_t)(ts.tv_nsec / 1000000ULL);
    }
#else
  #error "Invalid TS_MODE"
#endif
}

// --- Write a 48-bit value as big-endian (network byte order) ---
static void write_be48(uint8_t *p, uint64_t v) {
    p[0] = (uint8_t)((v >> 40) & 0xFF);
    p[1] = (uint8_t)((v >> 32) & 0xFF);
    p[2] = (uint8_t)((v >> 24) & 0xFF);
    p[3] = (uint8_t)((v >> 16) & 0xFF);
    p[4] = (uint8_t)((v >>  8) & 0xFF);
    p[5] = (uint8_t)( v        & 0xFF);
}

// --- UDP checksum (IPv4). udp = start of the UDP header, udp_len = header+data ---
static uint16_t udp_checksum(const uint8_t *ip_src, const uint8_t *ip_dst,
                             const uint8_t *udp, int udp_len) {
    uint32_t sum = 0;
    // Pseudo header
    sum += (ip_src[0] << 8) | ip_src[1];
    sum += (ip_src[2] << 8) | ip_src[3];
    sum += (ip_dst[0] << 8) | ip_dst[1];
    sum += (ip_dst[2] << 8) | ip_dst[3];
    sum += IPPROTO_UDP_N;
    sum += udp_len;
    // UDP header + data
    for (int i = 0; i + 1 < udp_len; i += 2)
        sum += (udp[i] << 8) | udp[i + 1];
    if (udp_len & 1)
        sum += (udp[udp_len - 1] << 8);
    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);
    uint16_t res = (uint16_t)(~sum);
    return res == 0 ? 0xFFFF : res;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <interface> <file.pcap>\n", argv[0]);
        return 1;
    }
    const char *ifname = argv[1];
    const char *pcap_path = argv[2];

    // Set the base time (for TS_MODE 1)
    g_base_ns = now_monotonic_ns();

    // Open the pcap file
    char errbuf[PCAP_ERRBUF_SIZE];
    pcap_t *ph = pcap_open_offline(pcap_path, errbuf);
    if (!ph) { fprintf(stderr, "failed to open pcap: %s\n", errbuf); return 1; }

    // AF_PACKET raw socket
    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) { perror("socket (root required)"); return 1; }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) { perror("SIOCGIFINDEX"); return 1; }
    int ifindex = ifr.ifr_ifindex;

    struct sockaddr_ll sll;
    memset(&sll, 0, sizeof(sll));
    sll.sll_family   = AF_PACKET;
    sll.sll_ifindex  = ifindex;
    sll.sll_protocol = htons(ETH_P_ALL);
    sll.sll_halen    = 6;

    const u_char *pkt;
    struct pcap_pkthdr *hdr;
    uint8_t buf[65536];

    long total = 0, modified = 0, sent = 0;
    struct timespec prev_pcap = {0, 0};
    int have_prev = 0;
#if DEBUG_PRINT_FIRST > 0
    int dbg_printed = 0;
#endif

    int rc;
    while ((rc = pcap_next_ex(ph, &hdr, &pkt)) == 1) {
        total++;
        unsigned len = hdr->caplen;
        if (len < ETH_HLEN || len > sizeof(buf)) continue;

        memcpy(buf, pkt, len);  // local copy to modify

#if PACE_ORIGINAL_TIMING
        // Inter-packet delay from the original
        struct timespec cur = { hdr->ts.tv_sec, hdr->ts.tv_usec * 1000L };
        if (have_prev) {
            long dsec = cur.tv_sec - prev_pcap.tv_sec;
            long dnsec = cur.tv_nsec - prev_pcap.tv_nsec;
            if (dnsec < 0) { dsec--; dnsec += 1000000000L; }
            if (dsec >= 0 && (dsec > 0 || dnsec > 0)) {
                struct timespec delay = { dsec, dnsec };
                nanosleep(&delay, NULL);
            }
        }
        prev_pcap = cur; have_prev = 1;
#endif

        // Is the ethertype IPv4? (assumes no VLAN)
        uint16_t ethertype = (buf[12] << 8) | buf[13];
        if (ethertype != ETHERTYPE_IPV4) goto send_it;

        unsigned ip_off = ETH_HLEN;
        if (len < ip_off + 20) goto send_it;
        unsigned ihl = (buf[ip_off] & 0x0F) * 4;
        if (ihl < 20 || len < ip_off + ihl) goto send_it;
        uint8_t proto = buf[ip_off + 9];
        if (proto != IPPROTO_UDP_N) goto send_it;

        uint8_t *ip_src = &buf[ip_off + 12];
        uint8_t *ip_dst = &buf[ip_off + 16];

        unsigned udp_off = ip_off + ihl;
        if (len < udp_off + 8) goto send_it;
        unsigned payload_off = udp_off + 8;
        if (len < payload_off) goto send_it;

        // --- Parse the MoldUDP64 frame ---
        unsigned udp_payload_len = len - payload_off;
        if (udp_payload_len < MOLD_HDR_LEN) goto send_it;  // not even a header

        uint8_t *mold = &buf[payload_off];
        uint16_t msg_count = (mold[MOLD_MSGCOUNT_OFF] << 8)
                           |  mold[MOLD_MSGCOUNT_OFF + 1];

        // Heartbeat (0) or end-of-session (0xFFFF) -> no messages, leave untouched
        if (msg_count == MOLD_HEARTBEAT || msg_count == MOLD_ENDOFSESSION)
            goto send_it;

#if SAME_TS_PER_PACKET
        uint64_t now_ts = make_timestamp();
#endif

        int did_modify = 0;
        unsigned pos = MOLD_HDR_LEN;  // start of the first message block (within payload)

        for (uint16_t m = 0; m < msg_count; m++) {
            // Can we read the length field?
            if (pos + MOLD_MSGLEN_LEN > udp_payload_len) break;

            uint16_t msg_len = (mold[pos] << 8) | mold[pos + 1];
            unsigned msg_data_off = pos + MOLD_MSGLEN_LEN;

            // Does the message data exceed the packet boundary?
            if (msg_data_off + msg_len > udp_payload_len) break;

            uint8_t *msg = &mold[msg_data_off];

#if FILTER_BY_MSGTYPE
            int do_update = (msg_len >= 1 && msg[0] == (uint8_t)ITCH_MSGTYPE);
#else
            int do_update = 1;
#endif
            // Does the timestamp field fit within this message?
            if (do_update && msg_len >= ITCH_MIN_MSGLEN) {
#if SAME_TS_PER_PACKET
                uint64_t tsv = now_ts;
#else
                uint64_t tsv = make_timestamp();
#endif
                write_be48(&msg[ITCH_TS_OFFSET], tsv);
                did_modify = 1;
                modified++;

#if DEBUG_PRINT_FIRST > 0
                if (dbg_printed < DEBUG_PRINT_FIRST) {
                    fprintf(stderr,
                        "[dbg] pkt#%ld msg_type=0x%02X written_ts=%llu\n",
                        total, msg[0], (unsigned long long)tsv);
                    dbg_printed++;
                }
#endif
            }

            // Move to the next block
            pos = msg_data_off + msg_len;
        }

        // If no message was updated, no need to touch the checksum
        if (!did_modify) goto send_it;

        // --- Recompute the UDP checksum ---
        {
            unsigned udp_len = len - udp_off;   // header + data
            uint8_t *udp = &buf[udp_off];
            udp[6] = 0; udp[7] = 0;
            uint16_t csum = udp_checksum(ip_src, ip_dst, udp, (int)udp_len);
            udp[6] = (uint8_t)(csum >> 8);
            udp[7] = (uint8_t)(csum & 0xFF);
        }

    send_it:
        memcpy(sll.sll_addr, buf, 6);  // destination MAC from the frame
        if (sendto(fd, buf, len, 0, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
            if (errno == ENOBUFS) { usleep(1000); continue; }
            perror("sendto");
        } else {
            sent++;
        }
    }

    if (rc == -1)
        fprintf(stderr, "pcap read error: %s\n", pcap_geterr(ph));

    printf("Total: %ld  Updated(message TS): %ld  Sent: %ld\n",
           total, modified, sent);

    close(fd);
    pcap_close(ph);
    return 0;
}
