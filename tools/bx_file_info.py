#!/usr/bin/env python3
"""Dump'taki mesaj tiplerini say. Kod mu veri mi sorusunu çözer."""
import gzip, struct, sys
from collections import Counter

path = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 else None

c = Counter()
first_A_at = None
n = 0
with gzip.open(path, "rb") as f:
    while True:
        hdr = f.read(2)
        if len(hdr) < 2:
            break
        (length,) = struct.unpack(">H", hdr)
        payload = f.read(length)
        if len(payload) < length:
            break
        t = payload[0:1].decode("ascii", "replace")
        c[t] += 1
        if t == "A" and first_A_at is None:
            first_A_at = n
        n += 1
        if limit and n >= limit:
            break

print(f"toplam {n} mesaj")
print(f"ilk 'A' (Add Order No MPID): {first_A_at if first_A_at is not None else 'YOK'}")
print("tip dağılımı (çoktan aza):")
for t, cnt in c.most_common():
    print(f"  {t!r}: {cnt}")
