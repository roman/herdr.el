#!/usr/bin/env bash
# Run interleaved benchmark repetitions of herdr.el variants.
#
# usage: run.sh ROOT [--reps N] [--seconds S] [--warmup W]
#               [--exec-delay SECONDS] [--out FILE] [--panes "ID ..."]
#               [--profile]
#               LABEL=DIR[,CONFIG.el] ...
#
# Run it inside `nix develop .#perf`, which pins every program used here,
# including the GNU timeout that macOS does not ship.
#
# ROOT is a directory prepared by fixture.sh. Each variant names a
# herdr.el checkout and an optional file of settings loaded before the
# run. DIR "-" runs no Emacs at all and measures the server alone, which
# is the control for "does herdr.el slow herdr down".
#
# Variants are interleaved and the order rotates every repetition, so a
# drift in machine load spreads over all variants instead of landing on
# one.
#
# --exec-delay puts shims for herdr, git and cat ahead of PATH. Each shim
# sleeps before it executes the real program, which reproduces the
# per-exec authorization cost of an endpoint security agent on a machine
# that has none. Calibrate the value on the affected machine. The sleep
# runs in the child after posix_spawn has returned, so the shim charges
# the full delay to synchronous calls (git status, herdr machine list) but
# not to asynchronous launches such as terminal streams, where a real
# agent also delays the parent. Treat it as a lower bound for those.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "${1:?usage: run.sh ROOT [options] LABEL=DIR...}" && pwd)
shift
reps=5
seconds=60
warmup=10
exec_delay=
out=$root/results-$(date +%Y%m%d-%H%M%S).jsonl
panes=
profile=
while [ $# -gt 0 ]; do
    case $1 in
        --reps) reps=$2; shift 2 ;;
        --seconds) seconds=$2; shift 2 ;;
        --warmup) warmup=$2; shift 2 ;;
        --exec-delay) exec_delay=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --panes) panes=$2; shift 2 ;;
        --profile) profile=1; shift ;;
        --*) echo "unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || { echo "no variants given" >&2; exit 2; }
variants=("$@")

# shellcheck source=/dev/null
. "$root/env.sh"
emacs=${EMACS:-emacs}
[ -n "$panes" ] && HERDR_BENCH_PANES=$panes

# Compile every variant once, the way a user runs the package, so an
# A/B compares revisions instead of compile states. load-prefer-newer
# below keeps a stale .elc from running in place of an edited source.
for spec in "${variants[@]}"; do
    rest=${spec#*=}
    dir=${rest%%,*}
    [ "$dir" = - ] && continue
    if [ "$rest" != "$dir" ] && [ ! -f "${rest#*,}" ]; then
        echo "no settings file ${rest#*,} for ${spec%%=*}" >&2
        exit 2
    fi
    printf 'Compiling %s\n' "$dir"
    "$emacs" -Q --batch -L "$dir" \
        --eval '(setq load-prefer-newer t)' \
        -f batch-byte-compile "$dir"/*.el >"$root/compile.log" 2>&1 || {
        echo "byte-compile failed for $dir; see $root/compile.log" >&2
        exit 1
    }
done

path=$PATH
if [ -n "$exec_delay" ]; then
    shim=$root/shim
    mkdir -p "$shim"
    for program in herdr git cat; do
        real=$(command -v "$program")
        printf '#!/bin/sh\nsleep %s\nexec %s "$@"\n' \
            "$exec_delay" "$real" >"$shim/$program"
        chmod +x "$shim/$program"
    done
    path=$shim:$PATH
fi

run_one() {
    local label=$1 dir=$2 config=$3 rep=$4
    local probe_out marker
    probe_out=$(mktemp)
    marker=$probe_out.window
    printf '[%s] rep %s: %s\n' "$(date +%T)" "$rep" "$label"
    if [ "$dir" = - ]; then
        sleep "$warmup"
        python3 "$here/probe.py" "$seconds" >"$probe_out"
        printf '{"label":"%s","window_seconds":%s}\n' "$label" "$seconds" \
            >"$probe_out.emacs"
    else
        # The probe starts when Emacs opens its window, not after a fixed
        # sleep, because startup time differs between variants.
        (
            for _ in $(seq 1 600); do
                [ -e "$marker" ] && break
                sleep 0.2
            done
            if [ -e "$marker" ]; then
                python3 "$here/probe.py" "$seconds" >"$probe_out"
            fi
        ) &
        local probe_pid=$!
        # A GUI Emacs on macOS starts in the home directory rather than
        # the one it was launched from, so every path it loads is absolute.
        # The timeout below covers an error while Emacs loads these, which
        # leaves it idle before herdr-bench.el schedules its own watchdog.
        # GNU timeout signals from a separate parent; an alarm inside Emacs
        # would not work, because Emacs handles SIGALRM for its timers.
        dir=$(cd "$dir" && pwd)
        local load=(-L "$dir")
        [ -n "$config" ] &&
            load+=(-l "$(cd "$(dirname "$config")" && pwd)/$(basename "$config")")
        PATH=$path \
        HERDR_BENCH_OUT=$probe_out.emacs \
        HERDR_BENCH_LABEL=$label \
        HERDR_BENCH_WARMUP=$warmup \
        HERDR_BENCH_SECONDS=$seconds \
        HERDR_BENCH_PROFILE=${profile:+$root/profile-$label-$rep.txt} \
        HERDR_BENCH_MARKER=$marker \
            timeout --foreground $((warmup + seconds + 180)) \
            "$emacs" -Q --geometry 200x60 \
            --eval '(setq load-prefer-newer t)' "${load[@]}" \
            -L "$here" -l herdr-bench -f herdr-bench-run \
            >"$root/emacs-$label-$rep.log" 2>&1 || true
        wait "$probe_pid" || true
    fi
    python3 - "$probe_out.emacs" "$probe_out" "$rep" "$exec_delay" "$label" \
        >>"$out" <<'EOF'
import json, sys
emacs_file, probe_file, rep, delay, label = sys.argv[1:6]
try:
    result = json.loads(open(emacs_file).read().splitlines()[-1])
except (OSError, IndexError):
    result = {"label": label, "error": "emacs wrote no result"}
try:
    result.update(json.loads(open(probe_file).read()))
except ValueError:
    pass
result["rep"] = int(rep)
result["exec_delay"] = float(delay) if delay else 0.0
print(json.dumps(result))
EOF
    rm -f "$probe_out" "$probe_out.emacs" "$marker"
    # Let stream teardown and the server's own reaction settle.
    sleep 5
}

for rep in $(seq 1 "$reps"); do
    count=${#variants[@]}
    for offset in $(seq 0 $((count - 1))); do
        spec=${variants[$(((rep + offset) % count))]}
        label=${spec%%=*}
        rest=${spec#*=}
        dir=${rest%%,*}
        config=
        [ "$rest" != "$dir" ] && config=${rest#*,}
        run_one "$label" "$dir" "$config" "$rep"
    done
done
python3 "$here/report.py" "$out"
