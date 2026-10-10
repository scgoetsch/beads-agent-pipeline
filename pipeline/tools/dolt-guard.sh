#!/usr/bin/env bash
# dolt-guard.sh — make sure the beads Dolt server is running, and say so when it isn't.
#
# WHY THIS EXISTS
# The beads store is a plain `dolt sql-server` process on 127.0.0.1:27575 and
# nothing on this box restarts it. `dolt.auto-start` is false, and the systemd
# user unit `dolt-beads.service` is permanently disabled — it was a 203/EXEC
# crash-loop (~66k restarts) whose ExecStart named a binary AND a config that
# both did not exist, so it never ran the real server. Every reboot therefore
# leaves the store unreachable and every `bd` write failing.
#
# The outage is not the dangerous part; how it presents is. Reads served from
# the prime hook can still look fine, so the first symptom is usually a
# `bd note` / `bd create` / `bd close` that silently does not land.
# See memory `wsl-dolt-server-not-auto-started-after-reboot`.
#
# INSTALL — once per machine, since ~/.bashrc is not in this repo:
#   echo '[ -f "$HOME/workspace/tools/dolt-guard.sh" ] && . "$HOME/workspace/tools/dolt-guard.sh"' >> ~/.bashrc
# Put it at the BOTTOM, after the PATH exports, so `bd` is resolvable.
# ~/.bashrc is sourced in full (past its line-6 non-interactive early return)
# both by interactive terminals and by Claude Code when it builds a shell
# snapshot, so one line covers human shells and agent sessions alike.
#
# Sourced: defines the functions and runs the guard once, unless
# BD_DOLT_GUARD_NORUN=1 (which is how dolt-guard_test.sh loads it).
# Executed: runs the guard and exits with its status.
#
# Test overrides: BD_DOLT_GUARD_PORT, BD_DOLT_GUARD_WS, BD_DOLT_GUARD_BD.
#
# The workspace defaults to THIS FILE's repo (tools/ -> root), resolved once at source time,
# so a clone in any location guards its own store. BD_DOLT_GUARD_WS still
# wins for the tests, and $HOME/workspace remains the last-resort fallback.

__BD_DOLT_GUARD_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)

__bd_dolt_guard_listening() {
    # Reads the kernel's listen table; does NOT open a connection. ~4ms.
    # `ss -H` suppresses the header, so "no listener" is genuinely empty output. ss is iproute2,
    # Linux only: fall back to lsof, then netstat (stock macOS has both). Returns 2 when NONE is
    # on PATH, so a box with no prober says so instead of reading "not listening" and trying to
    # start a server from every shell (2026-09-22 review; check 9 in dolt-guard_test.sh).
    # A minimal Linux (a fresh container: no iproute2, lsof or net-tools) has none of the three
    # but always has the kernel's own table, /proc/net/tcp: local_address is hex ip:port and
    # state 0A is LISTEN. Read that before giving up (container self-test, 2026-10-06).
    local hexport
    if command -v ss >/dev/null 2>&1; then
        [ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -an 2>/dev/null | command grep -qE "[.:]$1[[:space:]].*LISTEN"
    elif [ -r /proc/net/tcp ]; then
        # awk must READ TO THE END: an early `exit` on the first match sends SIGPIPE to the
        # writer, and under `set -o pipefail` (any script that sources this guard) a live
        # listener then reads as "not listening". The trailing `true` keeps a missing tcp6
        # from failing the pipeline for the same reason. Found by the suite, 2026-10-06.
        hexport=$(printf ':%04X' "$1")
        { for f in /proc/net/tcp /proc/net/tcp6; do [ -r "$f" ] && cat "$f"; done; true; } 2>/dev/null \
          | awk -v p="$hexport" '$4 == "0A" && substr($2, length($2) - length(p) + 1) == p { found = 1 }
                                 END { exit !found }'
    else
        return 2
    fi
}

__bd_dolt_guard_say() {
    local ws="$1" msg="$2"
    # stderr, never stdout: this runs while Claude Code is capturing shell state
    # into a snapshot file, and stray stdout would corrupt it.
    printf 'dolt-guard: %s\n' "$msg" >&2
    # strftime, not `date -Is`: -I is GNU; BSD date (macOS) rejects it and the log line was lost.
    printf '%s dolt-guard: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$msg" >>"$ws/.beads/dolt-guard.log" 2>/dev/null || true
}

__bd_dolt_guard_await() {
    # `bd dolt start` returning 0 is not proof the port is bound, and the bind
    # is not instant. Poll for the thing we actually care about.
    local port="$1" tries="${BD_DOLT_GUARD_TRIES:-40}"
    while [ "$tries" -gt 0 ]; do
        __bd_dolt_guard_listening "$port" && return 0
        sleep 0.25
        tries=$((tries - 1))
    done
    return 1
}

bd_dolt_guard() {
    local port="${BD_DOLT_GUARD_PORT:-27575}"
    local ws="${BD_DOLT_GUARD_WS:-${__BD_DOLT_GUARD_ROOT:-$HOME/workspace}}"
    local bd_bin="${BD_DOLT_GUARD_BD:-}"
    local lockfd

    # Nothing to guard on a machine that has no such workspace.
    [ -d "$ws/.beads" ] || return 0

    # Nothing to guard on an EMBEDDED store either: bd 1.3.0's default is in-process Dolt with
    # no server (`bd dolt status`: "embedded (in-process, no server)", data under
    # .beads/embeddeddolt/). The hazard this guard exists for -- a server that did not come back
    # after a reboot -- cannot occur there, and probing :27575 instead printed "FAILED to start
    # dolt server — bd writes will NOT land" in every new shell of the first fresh install we
    # did, while bd writes landed fine. A false alarm on every shell is how a guard gets ignored.
    [ -d "$ws/.beads/embeddeddolt" ] && return 0

    # The only path taken 99% of the time. No lock, no subprocess but the prober.
    __bd_dolt_guard_listening "$port"
    case $? in
        0) return 0 ;;
        2) __bd_dolt_guard_say "$ws" "cannot probe :$port — none of ss, lsof, netstat on PATH and no /proc/net/tcp; leaving the server alone"
           return 0 ;;
    esac

    if [ -z "$bd_bin" ]; then
        bd_bin=$(command -v bd 2>/dev/null) || bd_bin="$HOME/.local/bin/bd"
    fi
    if [ ! -x "$bd_bin" ]; then
        __bd_dolt_guard_say "$ws" "FAILED: dolt server down on :$port and no bd binary found — bd writes will NOT land"
        return 1
    fi

    # The brace group is load-bearing: `exec {fd}>file 2>/dev/null` with no
    # command applies the 2>/dev/null to THIS SHELL, permanently silencing every
    # message below — the exact silent failure this guard exists to prevent.
    if ! { exec {lockfd}>"$ws/.beads/.dolt-guard.lock"; } 2>/dev/null; then
        __bd_dolt_guard_say "$ws" "FAILED: cannot open $ws/.beads/.dolt-guard.lock — server down on :$port; no start attempted"
        return 1
    fi

    # Concurrent shells must not each spawn a server: a Claude Code session can
    # open several at once (parallel tool calls). The first one through starts
    # it; the rest block here and find the port already up on the re-check.
    # flock is util-linux; stock macOS has none. A missing flock exited 127 and read as "timed
    # out", so the guard gave up on exactly the box it was needed on. Proceed unlocked and say so:
    # two shells racing to `bd dolt start` is a nuisance, a server nobody starts is the outage.
    if ! command -v flock >/dev/null 2>&1; then
        __bd_dolt_guard_say "$ws" "no flock on this box — starting dolt without the concurrency lock"
    elif ! flock -w 30 "$lockfd"; then
        __bd_dolt_guard_say "$ws" "FAILED: timed out waiting for another shell to start dolt on :$port"
        exec {lockfd}>&-
        return 1
    fi

    # `{lockfd}>&-` closes the lock for the child only. Without it the daemonised
    # server inherits the fd, and since flock belongs to the open file description
    # the lock stays held for the server's whole life: every shell waiting above
    # burns the full 30s and then reports a FAILED that is not true.
    if __bd_dolt_guard_listening "$port"; then
        :  # another shell won the race while we waited — nothing to do
    elif ( cd "$ws" && "$bd_bin" dolt start ) {lockfd}>&- >/dev/null 2>&1 && __bd_dolt_guard_await "$port"; then
        __bd_dolt_guard_say "$ws" "started dolt server on :$port"
    else
        __bd_dolt_guard_say "$ws" "FAILED to start dolt server on :$port — bd writes will NOT land; run: (cd $ws && bd dolt start)"
        exec {lockfd}>&-
        return 1
    fi

    exec {lockfd}>&-
    return 0
}

if [ "${BD_DOLT_GUARD_NORUN:-0}" != "1" ]; then
    bd_dolt_guard
fi
