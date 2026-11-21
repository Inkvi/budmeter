#!/usr/bin/env python3
"""Write six weeks of made-up earbud history to a SQLite file, for trying the UI.

Usage:
  scripts/demo-data.py /tmp/budmeter-demo.sqlite
  open --env BUDMETER_DB=/tmp/budmeter-demo.sqlite build/Build/Products/Debug/BudMeter.app
"""
import math
import os
import random
import sqlite3
import sys
import time

SCHEMA = """
CREATE TABLE devices (address TEXT PRIMARY KEY, name TEXT NOT NULL, product_id INTEGER,
  first_seen REAL NOT NULL, last_seen REAL NOT NULL, rated_hours REAL);
CREATE TABLE samples (address TEXT NOT NULL, time REAL NOT NULL, main INTEGER, left_level INTEGER,
  right_level INTEGER, case_level INTEGER, state TEXT NOT NULL, wearing INTEGER);
CREATE INDEX samples_by_device ON samples(address, time);
"""

# Drain in percent per hour by state. `wear` is how much faster it drains by the last week.
DEVICES = [
    dict(address="aa-00-00-00-00-01", name="Galaxy Buds3 Pro", pid=None, buds=True, step=1, wear_sensor=True,
         rates=dict(listening=19, call=27, idle=3.5), wear=1.3, stop_days_ago=0),
    dict(address="aa-00-00-00-00-02", name="AirPods Pro", pid=0x2014, buds=True, step=1,
         rates=dict(listening=15, call=21, idle=1.2), wear=1.05, right_extra=1.18, stop_days_ago=1),
    dict(address="aa-00-00-00-00-03", name="Pixel Buds A-Series", pid=None, buds=False, step=10,
         rates=dict(listening=34, call=40, idle=5), wear=1.1, stop_days_ago=5),
]

# One day of use: (state, hours). A None state is a disconnect (earbuds back in the case).
DAY = [("idle", 0.8), ("call", 1.0), ("listening", 1.5), ("idle", 1.2), (None, 1.5),
       ("listening", 1.2), ("call", 0.5), ("idle", 2.0)]


def quantize(level, step):
    return max(1, min(100, int(math.ceil(level / step)) * step))


def main(path):
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    now = time.time()
    days = 42
    random.seed(7)
    for d in DEVICES:
        end = now - d["stop_days_ago"] * 86400
        start = end - days * 86400
        left = right = 100.0
        case = 100.0
        first = last = None
        for day in range(days):
            if day % 7 in (5, 6):
                continue  # weekends off
            wear = 1 + (d["wear"] - 1) * day / days
            t = start + day * 86400 + 9 * 3600
            for idx, (state, hours) in enumerate(DAY):
                if state is None:  # charging in the case
                    t += hours * 3600
                    gained = min(100 - left, hours * 70)
                    left = min(100, left + hours * 70)
                    right = min(100, right + hours * 70)
                    case = max(5, case - gained * 0.3)
                    continue
                hours *= random.uniform(0.7, 1.3)
                # Galaxy Buds report whether they're in the ears; worn idle drains more.
                wearing = None
                if d.get("wear_sensor"):
                    wearing = state != "idle" or idx == 0
                rate = d["rates"][state] * wear * random.uniform(0.9, 1.1)
                if wearing and state == "idle":
                    rate *= 1.6
                steps = int(hours * 30)
                for _ in range(steps):
                    if left <= 3 or right <= 3:
                        break
                    l, r = quantize(left, d["step"]), quantize(right, d["step"])
                    row = (d["address"], t, None if d["buds"] else min(l, r),
                           l if d["buds"] else None, r if d["buds"] else None,
                           int(case) if d["buds"] else None, state,
                           None if wearing is None else int(wearing))
                    db.execute("INSERT INTO samples VALUES (?,?,?,?,?,?,?,?)", row)
                    first = first or t
                    last = t
                    t += 120
                    left -= rate / 30
                    right -= rate / 30 * d.get("right_extra", 1)
            # Overnight charge, case topped up too.
            left = right = 100.0
            case = 100.0 if day % 3 == 0 else case
        db.execute("INSERT INTO devices VALUES (?,?,?,?,?,NULL)",
                   (d["address"], d["name"], d["pid"], first, last))
    db.commit()
    print(f"Wrote demo data to {path}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/budmeter-demo.sqlite")
