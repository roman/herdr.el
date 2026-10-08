"""Summarise benchmark results per variant.

usage: report.py RESULTS.jsonl

Prints the median of each metric across repetitions, with the range in
brackets. Rates are per minute of measured window so runs of different
lengths compare.
"""

import json
import statistics
import sys
from collections import defaultdict

METRICS = [
    ("launches/min", lambda r: per_minute(r, r.get("launch_count"))),
    ("launch block s/min",
     lambda r: per_minute(r, r.get("launch_blocking_seconds"))),
    ("connects/min", lambda r: per_minute(r, r.get("connect_count"))),
    ("stall s/min", lambda r: per_minute(r, r.get("stall_seconds"))),
    ("late p99 ms", lambda r: ms(r.get("lateness_p99"))),
    ("late max ms", lambda r: ms(r.get("lateness_max"))),
    ("cpu %", lambda r: percent(r)),
    ("snapshots/min",
     lambda r: per_minute(r, (r.get("api_requests") or {})
                          .get("session.snapshot"))),
    ("startup s", lambda r: r.get("startup_seconds")),
    ("ping p95 ms", lambda r: ms(r.get("ping_p95"))),
    ("snap p95 ms", lambda r: ms(r.get("snapshot_p95"))),
]


def per_minute(result, value):
    if value is None or not result.get("window_seconds"):
        return None
    return value * 60.0 / result["window_seconds"]


def ms(value):
    return None if value is None else value * 1000.0


def percent(result):
    if result.get("cpu_seconds") is None:
        return None
    return 100.0 * result["cpu_seconds"] / result["window_seconds"]


def cell(values):
    values = [v for v in values if v is not None]
    if not values:
        return "-"
    return "%.1f [%.1f-%.1f]" % (statistics.median(values),
                                 min(values), max(values))


def main():
    groups = defaultdict(list)
    errors = []
    for line in open(sys.argv[1]):
        result = json.loads(line)
        if "error" in result:
            errors.append(result)
            continue
        key = (result.get("label"), result.get("exec_delay", 0),
               bool(result.get("profiled")))
        groups[key].append(result)
    for (label, delay, profiled), results in sorted(groups.items()):
        print("%s (exec delay %ss, %d runs%s)" % (
            label, delay, len(results), ", profiled" if profiled else ""))
        for name, metric in METRICS:
            print("  %-18s %s" % (name, cell([metric(r) for r in results])))
        programs = defaultdict(list)
        for result in results:
            for program, entry in (result.get("launches") or {}).items():
                programs[program].append(per_minute(result, entry["count"]))
        for program, values in sorted(programs.items()):
            print("    %-16s %s per min" % (program, cell(values)))
    for result in errors:
        print("ERROR %s rep %s: %s" % (result.get("label"),
                                       result.get("rep"), result["error"]))


if __name__ == "__main__":
    main()
