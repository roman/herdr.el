"""Time herdr API requests from outside Emacs while a benchmark runs.

usage: probe.py SECONDS [INTERVAL]

Alternates `ping` and `session.snapshot` on HERDR_SOCKET_PATH every
INTERVAL seconds and prints one JSON object of latency percentiles.
`ping` is answered without the server's app loop, so the gap between the
two isolates app-loop wait from socket handling. Comparing a run with
Emacs attached against one without tells whether herdr.el slows the
server for every other client.
"""

import json
import os
import socket
import sys
import time


class ProbeError(Exception):
    """The server answered without a result, so the timing is not a sample."""


def request(path, method):
    """Return the seconds one METHOD request on PATH took.

    An empty reply or an error reply raises ProbeError: a renamed method
    answers quickly with an error, and timing it would report a fast
    server that was never asked the real question.
    """
    start = time.monotonic()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(5)
        conn.connect(path)
        conn.sendall(json.dumps(
            {"id": "probe", "method": method, "params": {}}).encode() + b"\n")
        reply = b""
        while not reply.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            reply += chunk
    elapsed = time.monotonic() - start
    if not reply.strip():
        raise ProbeError("empty reply to %s" % method)
    answer = json.loads(reply)
    if "error" in answer:
        raise ProbeError("%s: %s" % (method, answer["error"]))
    return elapsed


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def main():
    seconds = float(sys.argv[1])
    interval = float(sys.argv[2]) if len(sys.argv) > 2 else 0.25
    path = os.environ["HERDR_SOCKET_PATH"]
    samples = {"ping": [], "session.snapshot": []}
    failures = 0
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for method in samples:
            try:
                samples[method].append(request(path, method))
            except (OSError, ValueError, ProbeError):
                failures += 1
            time.sleep(interval / 2)
    result = {"probe_failures": failures}
    for method, values in samples.items():
        name = "ping" if method == "ping" else "snapshot"
        result[name + "_count"] = len(values)
        for label, fraction in (("p50", 0.5), ("p95", 0.95), ("max", 1.0)):
            result["%s_%s" % (name, label)] = percentile(values, fraction)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
