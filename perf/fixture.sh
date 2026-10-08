#!/usr/bin/env bash
# Build a throwaway herdr session for the benchmark.
#
# usage: fixture.sh ROOT [--repos N] [--files N] [--agents N]
#
# Creates N git repositories of F tracked files under ROOT/repos, starts an
# isolated herdr server whose config and sockets live under ROOT/cfg, opens
# one workspace per repository, and runs a synthetic agent in the first A
# panes. ROOT/env.sh exports what the benchmark and the probes need.
#
# The server is isolated through XDG_CONFIG_HOME so the operator's own
# herdr session on the same machine is never touched. It keeps running
# after this script exits; the last line printed says how to stop it.
#
# A repository is rebuilt when its file count differs from --files, so a
# rerun with another size, or after an interrupted build, measures the
# size that was asked for.
set -euo pipefail

root=$(cd "${1:?usage: fixture.sh ROOT [options]}" && pwd)
shift
repos=4
files=20000
agents=2
while [ $# -gt 0 ]; do
    case $1 in
        --repos) repos=$2; shift 2 ;;
        --files) files=$2; shift 2 ;;
        --agents) agents=$2; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

export XDG_CONFIG_HOME=$root/cfg
export HERDR_SOCKET_PATH=$XDG_CONFIG_HOME/herdr/herdr.sock
# macOS caps a unix socket path at 104 bytes, and herdr gives no clear
# error when its socket cannot be created.
if [ ${#HERDR_SOCKET_PATH} -ge 104 ]; then
    echo "ROOT is too deep for a unix socket: $HERDR_SOCKET_PATH" >&2
    exit 2
fi
mkdir -p "$XDG_CONFIG_HOME" "$root/repos"

for i in $(seq 1 "$repos"); do
    repo=$root/repos/repo$i
    if [ "$(cat "$repo/.fixture-files" 2>/dev/null)" = "$files" ]; then
        continue
    fi
    printf 'Creating %s with %s files\n' "$repo" "$files"
    rm -rf "$repo"
    mkdir -p "$repo"
    # One process writes every file: a shell loop would spend minutes in
    # fork on a machine where each exec is audited.
    perl -e 'for $n (1..$ARGV[1]) {
        $d = sprintf "%s/d%03d", $ARGV[0], $n % 200;
        mkdir $d; open F, ">", "$d/f$n.txt"; print F "line $n\n"; close F }' \
        "$repo" "$files"
    git -C "$repo" init -q
    git -C "$repo" add -A
    git -C "$repo" -c user.name=bench -c user.email=bench@localhost \
        commit -qm fixture
    echo dirty >>"$repo/d001/f1.txt"
    echo "$files" >"$repo/.fixture-files"
done

if ! herdr workspace list >/dev/null 2>&1; then
    (nohup herdr server >"$root/server.log" 2>&1 &)
    for _ in $(seq 1 50); do
        herdr workspace list >/dev/null 2>&1 && break
        sleep 0.2
    done
fi

for id in $(herdr workspace list | python3 -c '
import json, sys
for w in json.load(sys.stdin)["result"]["workspaces"]:
    print(w["workspace_id"])'); do
    herdr workspace close "$id" >/dev/null
done

# The agent writes coloured lines from one long-lived perl process, so the
# pane produces steady terminal output without launching a process per line.
agent='$|=1; for ($i=0;;$i++) {
    printf "\e[3%dm%06d agent output %s\e[0m\n", $i % 7 + 1, $i, "x" x 60;
    select undef, undef, undef, 0.05 }'

panes=()
for i in $(seq 1 "$repos"); do
    pane=$(herdr workspace create --cwd "$root/repos/repo$i" \
        --label "repo$i" --no-focus | python3 -c '
import json, sys
print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])')
    panes+=("$pane")
    if [ "$i" -le "$agents" ]; then
        herdr pane run "$pane" "perl -e '$agent'" >/dev/null
    fi
done

cat >"$root/env.sh" <<EOF
export XDG_CONFIG_HOME='$XDG_CONFIG_HOME'
export HERDR_SOCKET_PATH='$HERDR_SOCKET_PATH'
export HERDR_BENCH_PANES='${panes[*]}'
EOF
printf 'Fixture ready: %s panes, env in %s/env.sh\n' "${#panes[@]}" "$root"
printf 'Stop its server with: . %s/env.sh && herdr server stop\n' "$root"
