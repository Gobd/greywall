#!/bin/bash
# LuLu experiment only. No settings/rules writes, installation, sudo or UI automation.
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "Apple Silicon macOS only" >&2; exit 1
fi
work="$PWD/.build/lulu-test"
bin="$work/bin"
mkdir -p "$bin"
command=${1:-help}
parent_pid() {
    if [ ! -f "$work/parent.pid" ]; then echo "No test root recorded" >&2; return 1; fi
    local pid actual
    read -r pid < "$work/parent.pid"
    case "$pid" in ''|*[!0-9]*) echo "Invalid recorded PID" >&2; return 1;; esac
    actual=$(ps -ww -p "$pid" -o command= 2>/dev/null || true)
    # Never signal a reused PID belonging to another process.
    if [ "$actual" != "$bin/gw-lulu-parent --hold" ]; then
        echo "Recorded PID is not our live test root; refusing to signal it" >&2; return 1
    fi
    printf '%s\n' "$pid"
}
case "$command" in
    build)
        if parent_pid >/dev/null 2>&1; then echo "Stop the live test before rebuilding" >&2; exit 1; fi
        for role in parent child grandchild detached unrelated; do
            xcrun clang -arch arm64 -Wall -Wextra -Werror -O0 -g \
                "-DTEST_ROLE=\"$role\"" fixtures/lulu-tree.c -o "$bin/gw-lulu-$role"
        done
        echo "Fresh ARM-only test executables built under $bin" ;;
    baseline)
        test -x "$bin/gw-lulu-parent" || { echo "Run: bash lulu-test.sh build" >&2; exit 1; }
        "$bin/gw-lulu-parent" --baseline ;;
    start)
        test -x "$bin/gw-lulu-parent" || { echo "Run build first" >&2; exit 1; }
        if parent_pid >/dev/null 2>&1; then echo "Test root already running" >&2; exit 1; fi
        nohup "$bin/gw-lulu-parent" --hold > "$work/parent.log" 2>&1 < /dev/null &
        printf '%s\n' "$!" > "$work/parent.pid"
        echo "Test root started: PID $!. No connection until trigger. Log: $work/parent.log" ;;
    trigger|descendants)
        pid=$(parent_pid)
        kill -USR1 "$pid"
        echo "Signaled root $pid. First signal requests the parent alert; later signals test child/grandchild." ;;
    detached)
        pid=$(parent_pid)
        kill -USR2 "$pid"
        echo "Scheduled detached descendant under live root $pid. Check log after its bounded request." ;;
    unrelated)
        "$bin/gw-lulu-unrelated" ;;
    stop)
        pid=$(parent_pid)
        kill -TERM "$pid"
        echo "Requested test-root shutdown. It finishes any bounded in-flight attempt first." ;;
    status)
        parent_pid || true
        python3 - "$work/parent.log" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
print(path.read_text() if path.exists() else "No test log yet")
PY
        ;;
    *)
        echo "Usage: bash lulu-test.sh build|baseline|start|trigger|descendants|detached|unrelated|status|stop"
        echo "One harmless HTTP request per role to 1.1.1.1:80; no credentials/data sent."
        echo "Rules are created ONLY by your LuLu GUI actions. Read fixtures/LULU.md first." ;;
esac
