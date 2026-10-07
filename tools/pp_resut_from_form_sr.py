import re
import sys

import numpy as np

DISCARD_NS = 1_000_000_000   # 1 s
BROKEN_NS = 10**12

pattern = re.compile(r"Latency:.*\((-?\d+) ns\)")

vals = []
bad = over = 0
for f in sys.argv[1:]:
    with open(f, errors="ignore") as fh:
        for line in fh:
            m = pattern.search(line)
            if not m:
                continue
            ns = int(m.group(1))
            if ns < 0 or ns > BROKEN_NS:
                bad += 1
            elif ns > DISCARD_NS:
                over += 1
            else:
                vals.append(ns / 1e3)                

print(f"Valid: {len(vals)}, >1s: {over}, broken: {bad}")
if not vals:
    sys.exit("no valid latency values")

a = np.array(vals)
print(f"min    : {a.min():.3f} us")
for p in (50, 99, 99.9, 99.99):
    print(f"p{p:<6}: {np.percentile(a, p):.3f} us")
print(f"max    : {a.max():.3f} us")
