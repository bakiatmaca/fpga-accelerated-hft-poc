#!/usr/bin/env python3
"""
Replay a real NASDAQ/BX BinaryFILE ITCH 5.0 dump to the FPGA over MoldUDP64/UDP,
and (optionally) listen for the 33-byte signal responses it returns.

BinaryFILE: [2B big-endian length][ITCH payload] ... back to back, no MoldUDP.
The FPGA framer is length-based and silently skips non-A messages.

Response (33 byte, big-endian, packed with signal_to_pack):
Offset	Field	Byte	İnfo
0	Magic	1	0xBB fix
1	Msg Type	1	0x01 = buy signal
2	Timestamp	6	ITCH timestamp (48-bit, big-endian)
8	Order Reference	8	ITCH order ref (big-endian)
16	Side	1	ITCH indicator ('B'/'S')
17  Shares  4   ITCH quantity 4 byte integer
21	Stock	8	ITCH stock (ASCII)
29	Price	4	ITCH Price(4), big-endian)

NOTE: in the real PoC the response is read by the order-book, it doesn't reach the feeder.
The listener here is ONLY for verification/debug (enabled with --listen).
"""

import argparse
import gzip
import socket
import struct
import sys
import threading
import time

MAGIC = 0xBB
RESP_LEN = 33

def now_itch_ts():
    return int(time.time() * 1000)   # from epoch

def stamp_now(payload):
    """Set the ITCH message's timestamp (offset 5-10, 6B big-endian) to now."""
    buf = bytearray(payload)
    buf[5:11] = now_itch_ts().to_bytes(6, "big")   # epoch ns, 6B big-endian
    return bytes(buf)

# ------------------------------------------------------------- dump reader ---
def iter_itch_messages(path, limit=None):
    """Stream (msg_type, payload) from the gzipped BinaryFILE. Streaming."""
    count = 0
    with gzip.open(path, "rb") as f:
        while True:
            hdr = f.read(2)
            if len(hdr) < 2:
                break
            (length,) = struct.unpack(">H", hdr)
            if length == 0:
                continue
            payload = f.read(length)
            if len(payload) < length:
                break
            yield payload[0:1], payload
            count += 1
            if limit is not None and count >= limit:
                break


def mold_packet(messages, session=b"SESSION001", seq=1):
    assert len(session) == 10, "session must be exactly 10 bytes"
    hdr = session + struct.pack(">Q", seq) + struct.pack(">H", len(messages))
    body = b"".join(struct.pack(">H", len(m)) + m for m in messages)
    return hdr + body


# ------------------------------------------------------------- response ---
def parse_response(resp):
    if len(resp) != RESP_LEN:
        return None, f"bad length {len(resp)} (expected {RESP_LEN})"
    fields = {
        "magic":     resp[0],
        "type":      chr(resp[1]),
        "timestamp": int.from_bytes(resp[2:8], "big"),
        "order_ref": int.from_bytes(resp[8:16], "big"),
        "side":      chr(resp[16]),
        "shares":    int.from_bytes(resp[17:21], "big"),
        "stock":     resp[21:29].decode("ascii", "replace").rstrip(),
        "price":     int.from_bytes(resp[29:33], "big"),
    }
    if fields["magic"] != MAGIC:
        return fields, f"bad magic 0x{fields['magic']:02X} (expected 0x{MAGIC:02X})"
    return fields, None


class ResponseListener(threading.Thread):
    """Collects responses in a separate thread. Shares the sock (same port)."""
    def __init__(self, sock, verbose=False):
        super().__init__(daemon=True)
        self.sock = sock
        self.verbose = verbose
        self.count = 0
        self.bad = 0
        self._stop_evt = threading.Event()

    def run(self):
        self.sock.settimeout(0.5)
        while not self._stop_evt.is_set():
            try:
                resp, _ = self.sock.recvfrom(64)
            except socket.timeout:
                continue
            except OSError:
                break
            fields, err = parse_response(resp)
            if err:
                self.bad += 1
                if self.verbose:
                    print(f"  [resp] BAD: {err}  {fields}")
                continue
            self.count += 1
            if self.verbose:
                print(f"  [resp] type={fields['type']} side={fields['side']} "
                      f"shares={fields['shares']} "                
                      f"stock={fields['stock']} price={fields['price']} "
                      f"oref={fields['order_ref']} "
                      f"ts=0x{fields['timestamp']:012X}")

    def stop(self):
        self._stop_evt.set()


# ------------------------------------------------------------- main ---
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("dump", help="path to .gz BinaryFILE ITCH dump")
    ap.add_argument("--dst-ip", default="192.168.2.28")
    ap.add_argument("--dst-port", type=int, default=1234)
    ap.add_argument("--src-port", type=int, default=1234)
    ap.add_argument("--batch", type=int, default=1)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--pps", type=float, default=None)
    ap.add_argument("--add-only", action="store_true")
    ap.add_argument("--start-seq", type=int, default=1)
    ap.add_argument("--session", default="SESSION001")
    ap.add_argument("--listen", action="store_true",
                    help="listen for responses (debug; off in the real PoC)")
    ap.add_argument("--verbose", action="store_true",
                    help="print every response")
    ap.add_argument("--drain", type=float, default=1.0,
                    help="wait time for responses after sending finishes (sec)")
    ap.add_argument("--stamp-now", action="store_true",
                    help="write the payload timestamp as the moment of sending (ns from UTC midnight)")                    
    args = ap.parse_args()

    session = args.session.encode("ascii")
    if len(session) != 10:
        sys.exit("session must be exactly 10 ASCII chars")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("", args.src_port))
    except OSError as e:
        print(f"warning: could not bind src port: {e}", file=sys.stderr)

    listener = None
    if args.listen:
        listener = ResponseListener(sock, verbose=args.verbose)
        listener.start()

    dst = (args.dst_ip, args.dst_port)
    seq = args.start_seq
    batch = []
    sent_pkts = sent_msgs = skipped = 0
    min_interval = (1.0 / args.pps) if args.pps else 0.0
    next_send = time.perf_counter()

    def flush():
        nonlocal seq, sent_pkts, sent_msgs, next_send
        if not batch:
            return
        pkt = mold_packet(batch, session=session, seq=seq)
        if min_interval:
            now = time.perf_counter()
            if now < next_send:
                time.sleep(next_send - now)
            next_send += min_interval
        sock.sendto(pkt, dst)
        seq += len(batch)
        sent_pkts += 1
        sent_msgs += len(batch)
        batch.clear()

    t0 = time.perf_counter()
    try:
        for mtype, payload in iter_itch_messages(args.dump, limit=None):
            if args.add_only and mtype != b"A":
                skipped += 1
                continue
            if args.stamp_now:
                payload = stamp_now(payload)
            batch.append(payload)
            if len(batch) >= args.batch:
                flush()
            if args.limit is not None and sent_msgs >= args.limit:
                break
        flush()
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)

    dt = time.perf_counter() - t0
    print(f"sent {sent_msgs} msg / {sent_pkts} pkt ({skipped} skipped) "
          f"in {dt:.2f}s -> {sent_msgs/dt:.0f} msg/s" if dt > 0
          else f"sent {sent_msgs} msg / {sent_pkts} pkt")

    if listener:
        time.sleep(args.drain)        # drain the queue for the last responses
        listener.stop()
        listener.join(timeout=2.0)
        print(f"responses: {listener.count} ok, {listener.bad} malformed")
        # Health check: warn if we sent A but got no response at all
        if sent_msgs > 0 and listener.count == 0:
            print("  WARNING: messages were sent but there is NO response at all. "
                  "Is the board alive? Did it stay below THRESHOLD? "
                  "(An Add Order with price>THRESHOLD is required.)")

    sock.close()


if __name__ == "__main__":
    main()

