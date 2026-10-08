#!/usr/bin/env bash
# Measure what one exec and one socket connect cost on this machine.
#
# usage: calibrate.sh [REPO] [N]
#
# Needs no sudo, so it runs on a managed laptop. Run it on the affected
# machine and on the clean one; the difference per exec is the delay to
# inject on the clean machine to imitate the affected one.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=${1:-.}
n=${2:-50}

time_loop() {
    local label=$1; shift
    python3 - "$n" "$label" "$@" <<'PY'
import subprocess, sys, time
n, label, cmd = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
samples = []
for _ in range(n):
    start = time.monotonic()
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    samples.append(time.monotonic() - start)
samples.sort()
print("%-28s median %7.2f ms  p95 %7.2f ms  min %7.2f ms" % (
    label, 1000 * samples[len(samples) // 2],
    1000 * samples[int(0.95 * len(samples))], 1000 * samples[0]))
PY
}

time_loop "exec /usr/bin/true" /usr/bin/true
time_loop "exec cat </dev/null" cat /dev/null
time_loop "exec herdr --version" herdr --version
time_loop "git status (bench flags)" git -C "$repo" status \
    --porcelain=v2 --branch -uno
if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
    PYTHONPATH=$here python3 - "$n" <<'PY'
import os, sys
from probe import request
n, path = int(sys.argv[1]), os.environ["HERDR_SOCKET_PATH"]
samples = sorted(request(path, "ping") for _ in range(n))
print("%-28s median %7.2f ms  p95 %7.2f ms" % (
    "unix connect + ping", 1000 * samples[len(samples) // 2],
    1000 * samples[int(0.95 * len(samples))]))
PY
fi
