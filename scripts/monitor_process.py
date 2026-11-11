#!/usr/bin/env python3

import csv
import os
import sys
import time
from pathlib import Path

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <PID> <output.csv>", file=sys.stderr)
    sys.exit(2)

pid = int(sys.argv[1])
output_file = sys.argv[2]

proc_dir = Path(f"/proc/{pid}")

if not proc_dir.exists():
    print(f"Process is not running: {pid}", file=sys.stderr)
    sys.exit(1)

clock_ticks = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
page_size = os.sysconf("SC_PAGE_SIZE")
cpu_count = os.cpu_count() or 1


def read_metrics():
    # RSS from VmRSS in /proc/PID/status (kB)
    status = (proc_dir / "status").read_text()
    rss_kb = None

    for line in status.splitlines():
        if line.startswith("VmRSS:"):
            rss_kb = int(line.split()[1])
            break

    if rss_kb is None:
        return None

    # CPU time from /proc/PID/stat
    stat = (proc_dir / "stat").read_text()
    fields = stat[stat.rfind(")") + 2:].split()

    utime = int(fields[11])
    stime = int(fields[12])
    cpu_seconds = (utime + stime) / clock_ticks

    return rss_kb / 1024, cpu_seconds


previous = read_metrics()

if previous is None:
    print("Could not read initial process metrics.", file=sys.stderr)
    sys.exit(1)

previous_cpu = previous[1]
previous_time = time.monotonic()

rss_samples = []
cpu_samples = []

with open(output_file, "w", newline="") as file:
    writer = csv.writer(file)
    writer.writerow(["timestamp_ms", "rss_mb", "cpu_cores", "cpu_percent"])

    while proc_dir.exists():
        current = read_metrics()

        if current is None:
            break

        now = time.monotonic()
        elapsed = now - previous_time

        if elapsed <= 0:
            continue

        rss_mb, cpu_seconds = current

        cpu_cores = max(0, (cpu_seconds - previous_cpu) / elapsed)
        cpu_percent = cpu_cores * 100

        timestamp_ms = int(time.time() * 1000)

        writer.writerow([
            timestamp_ms,
            f"{rss_mb:.3f}",
            f"{cpu_cores:.3f}",
            f"{cpu_percent:.1f}"
        ])
        file.flush()

        rss_samples.append(rss_mb)
        cpu_samples.append(cpu_cores)

        previous_cpu = cpu_seconds
        previous_time = now

        time.sleep(0.1)

if rss_samples:
    print(f"Peak RSS: {max(rss_samples):.2f} MB")
    print(f"Average RSS: {sum(rss_samples) / len(rss_samples):.2f} MB")
    print(f"Average CPU: {sum(cpu_samples) / len(cpu_samples):.3f} cores")
    print(f"Peak CPU: {max(cpu_samples):.3f} cores")
