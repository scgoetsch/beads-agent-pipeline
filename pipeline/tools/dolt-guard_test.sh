#!/usr/bin/env bash
# Acceptance suite for tools/dolt-guard.sh.
#
# The property under test is the one this workspace keeps getting burned by:
# the guard must tell "server is up" apart from "I could not start it", and it
# must NEVER report success on the strength of an exit code alone. Checks 5 and
# 6 are the load-bearing ones — a `bd dolt start` that exits 0 while binding
# nothing must still fail the guard.
#
# Runs entirely against throwaway ports and stub `bd` binaries. It never touches
# the live server on 27575.

set -uo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-guard.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); LISTENERS=()

cleanup() {
    local p
    for p in "${LISTENERS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      %s\n' "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

free_port() {
    python3 -c 'import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

start_listener() {  # start_listener PORT -> binds it for the life of the suite
    local port="$1"
    setsid python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port)); s.listen(1); time.sleep(600)" </dev/null >/dev/null 2>&1 &
    LISTENERS+=("$!")
    local n=40
    while [ $n -gt 0 ]; do
        [ -n "$(ss -ltnH "sport = :$port" 2>/dev/null)" ] && return 0
        sleep 0.1; n=$((n-1))
    done
    return 1
}

make_ws() {  # a fake workspace with a .beads dir
    local d="$TMP/$1"; mkdir -p "$d/.beads"; echo "$d"
}

make_bd() {  # make_bd NAME BODY -> path to a stub bd
    local p="$TMP/bd-$1"
    { echo '#!/usr/bin/env bash'; echo "$2"; } >"$p"; chmod +x "$p"; echo "$p"
}

run_guard() {  # run_guard WS PORT BD -> prints stderr to $TMP/err, returns rc
    ( BD_DOLT_GUARD_NORUN=1 . "$GUARD"
      # TRIES=12 keeps the suite fast; the real default is 40 (10s).
      BD_DOLT_GUARD_WS="$1" BD_DOLT_GUARD_PORT="$2" BD_DOLT_GUARD_BD="$3" \
      BD_DOLT_GUARD_TRIES=12 \
        bd_dolt_guard ) 2>"$TMP/err"
}

echo "dolt-guard acceptance suite"
echo "  guard: $GUARD"
echo

# ---------------------------------------------------------------- 1
echo "no workspace on this machine"
ws_missing="$TMP/nonexistent"
stub_never=$(make_bd never "touch '$TMP/CALLED-1'; exit 0")
run_guard "$ws_missing" 29991 "$stub_never"; rc=$?
check "returns 0 when the workspace does not exist" "$rc" "0"
check "does not invoke bd" "$([ -e "$TMP/CALLED-1" ] && echo called || echo no)" "no"
check "stays silent" "$(wc -c <"$TMP/err")" "0"
echo

# ---------------------------------------------------------------- 1b
echo "embedded store (bd 1.3.0 default): no server exists, so nothing to guard"
ws1b=$(make_ws ws1b); mkdir -p "$ws1b/.beads/embeddeddolt"; port1b=$(free_port)
stub_never1b=$(make_bd never1b "touch '$TMP/CALLED-1b'; exit 0")
run_guard "$ws1b" "$port1b" "$stub_never1b"; rc=$?
check "returns 0 with no server listening" "$rc" "0"
check "does not invoke bd" "$([ -e "$TMP/CALLED-1b" ] && echo called || echo no)" "no"
check "stays silent (it used to say bd writes will NOT land)" "$(wc -c <"$TMP/err")" "0"
echo

# ---------------------------------------------------------------- 2
echo "server already up (the 99% path)"
ws2=$(make_ws ws2); port2=$(free_port)
start_listener "$port2" || { echo "could not bind test port"; exit 1; }
stub_never2=$(make_bd never2 "touch '$TMP/CALLED-2'; exit 0")
run_guard "$ws2" "$port2" "$stub_never2"; rc=$?
check "returns 0" "$rc" "0"
check "never shells out to bd" "$([ -e "$TMP/CALLED-2" ] && echo called || echo no)" "no"
check "stays silent" "$(wc -c <"$TMP/err")" "0"
echo

# ---------------------------------------------------------------- 3
echo "server down, bd starts it successfully"
ws3=$(make_ws ws3); port3=$(free_port)
stub_good=$(make_bd good "
echo \"\$@\" >>'$TMP/calls-3'
setsid python3 -c \"
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port3)); s.listen(1); time.sleep(600)\" </dev/null >/dev/null 2>&1 &
exit 0")
run_guard "$ws3" "$port3" "$stub_good"; rc=$?
LISTENERS+=("$(pgrep -f "127.0.0.1',$port3" | head -1)")
check "returns 0" "$rc" "0"
check "invoked 'bd dolt start'" "$(cat "$TMP/calls-3" 2>/dev/null)" "dolt start"
check "port is now listening" "$([ -n "$(ss -ltnH "sport = :$port3")" ] && echo up || echo down)" "up"
grep -q 'started dolt server' "$TMP/err" \
    && ok "announces the start on stderr" \
    || bad "announces the start on stderr" "stderr: $(cat "$TMP/err")"
grep -q 'started dolt server' "$ws3/.beads/dolt-guard.log" \
    && ok "records the start in .beads/dolt-guard.log" \
    || bad "records the start in .beads/dolt-guard.log" "log missing or empty"
echo

# ---------------------------------------------------------------- 4
echo "server down, bd binary missing"
ws4=$(make_ws ws4); port4=$(free_port)
run_guard "$ws4" "$port4" "$TMP/no-such-bd"; rc=$?
check "returns 1" "$rc" "1"
grep -q 'FAILED' "$TMP/err" \
    && ok "fails LOUDLY (says FAILED on stderr)" \
    || bad "fails LOUDLY" "stderr: $(cat "$TMP/err")"
grep -q 'will NOT land' "$TMP/err" \
    && ok "warns that bd writes will not land" \
    || bad "warns that bd writes will not land" "stderr: $(cat "$TMP/err")"
echo

# ---------------------------------------------------------------- 5
echo "server down, bd start FAILS (nonzero)"
ws5=$(make_ws ws5); port5=$(free_port)
stub_fail=$(make_bd fail "exit 1")
run_guard "$ws5" "$port5" "$stub_fail"; rc=$?
check "returns 1" "$rc" "1"
grep -q 'FAILED to start dolt server' "$TMP/err" \
    && ok "fails LOUDLY, not as a silent zero" \
    || bad "fails LOUDLY" "stderr: $(cat "$TMP/err")"
grep -q 'bd dolt start' "$TMP/err" \
    && ok "prints the manual recovery command" \
    || bad "prints the manual recovery command" "stderr: $(cat "$TMP/err")"
echo

# ---------------------------------------------------------------- 6  (the one that matters)
echo "server down, bd start LIES (exits 0, binds nothing)"
ws6=$(make_ws ws6); port6=$(free_port)
stub_liar=$(make_bd liar "exit 0")
run_guard "$ws6" "$port6" "$stub_liar"; rc=$?
check "returns 1 — exit code alone is NOT accepted as success" "$rc" "1"
grep -q 'FAILED to start dolt server' "$TMP/err" \
    && ok "reports failure despite bd exiting 0" \
    || bad "reports failure despite bd exiting 0" "stderr: $(cat "$TMP/err")"
echo

echo "server down, lock cannot be opened"
wslock=$(make_ws wslock); portlock=$(free_port)
mkdir -p "$wslock/.beads/.dolt-guard.lock"
stub_lock=$(make_bd lock "touch '$TMP/CALLED-lock'; exit 0")
run_guard "$wslock" "$portlock" "$stub_lock"; rc=$?
check "lock open failure is nonzero" "$rc" "1"
grep -q 'cannot open.*lock' "$TMP/err" && ok "lock failure is loud" || bad "lock failure is loud" "$(cat "$TMP/err")"
[ ! -e "$TMP/CALLED-lock" ] && ok "no unlocked start on lock failure" || bad "no unlocked start on lock failure" "bd ran"

# ---------------------------------------------------------------- 7
echo "concurrent shells race to start it"
ws7=$(make_ws ws7); port7=$(free_port)
stub_race=$(make_bd race "
echo x >>'$TMP/calls-7'
sleep 1
setsid python3 -c \"
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port7)); s.listen(1); time.sleep(600)\" </dev/null >/dev/null 2>&1 &
exit 0")
racers=()
for _ in 1 2 3 4; do run_guard "$ws7" "$port7" "$stub_race" & racers+=("$!"); done
# Wait only on the racers: a bare `wait` also waits on the still-sleeping
# listeners this suite started, which hangs it for their full 600s.
wait "${racers[@]}"
LISTENERS+=("$(pgrep -f "127.0.0.1',$port7" | head -1)")
check "bd dolt start ran exactly once across 4 shells" "$(wc -l <"$TMP/calls-7" 2>/dev/null | tr -d ' ')" "1"
check "port ends up listening" "$([ -n "$(ss -ltnH "sport = :$port7")" ] && echo up || echo down)" "up"
echo

# ---------------------------------------------------------------- 9
echo "no listener prober on PATH (no ss, lsof, netstat): says so, touches nothing"
# The probe used to be `ss` alone. Absent (stock macOS), its empty output read as "not
# listening" and every new shell tried to start a server. Build a PATH holding the tools the
# guard needs and none of the three probers.
NOPROBE="$TMP/noprobe"; mkdir -p "$NOPROBE"
for t in bash sh date sleep cat grep mkdir touch dirname; do
    b=$(command -v "$t" 2>/dev/null) && ln -sf "$b" "$NOPROBE/$t"
done
ws9=$(make_ws ws9); port9=$(free_port)
stub_never9=$(make_bd never9 "touch '$TMP/CALLED-9'; exit 0")
PATH="$NOPROBE" run_guard "$ws9" "$port9" "$stub_never9"; rc=$?
check "returns 0" "$rc" "0"
grep -q 'cannot probe' "$TMP/err" \
    && ok "says it cannot probe (not 'not listening')" \
    || bad "says it cannot probe" "stderr: $(cat "$TMP/err")"
[ ! -e "$TMP/CALLED-9" ] && ok "bd dolt start NOT called" || bad "bd dolt start NOT called" "it was"
echo

# ---------------------------------------------------------------- 10
echo "no flock on PATH: starts the server unlocked and says so, not 'timed out'"
# A missing flock exited 127, `if ! flock` took the failure branch, and the guard reported a
# 30-second timeout that never happened -- and gave up on exactly the box it was needed on.
NOFLOCK="$TMP/noflock"; mkdir -p "$NOFLOCK"
for t in bash sh date sleep cat grep mkdir touch dirname ss python3 setsid; do
    b=$(command -v "$t" 2>/dev/null) && ln -sf "$b" "$NOFLOCK/$t"
done
ws10=$(make_ws ws10); port10=$(free_port)
stub_start10=$(make_bd start10 "
setsid python3 -c \"
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port10)); s.listen(1); time.sleep(600)\" </dev/null >/dev/null 2>&1 &
exit 0")
PATH="$NOFLOCK" run_guard "$ws10" "$port10" "$stub_start10"; rc=$?
LISTENERS+=("$(pgrep -f "127.0.0.1',$port10" | sed -n 1p)")
check "returns 0" "$rc" "0"
grep -q 'no flock' "$TMP/err" \
    && ok "says it ran without the lock" \
    || bad "says it ran without the lock" "stderr: $(cat "$TMP/err")"
grep -q 'started dolt server' "$TMP/err" \
    && ok "and started the server" \
    || bad "and started the server" "stderr: $(cat "$TMP/err")"
grep -q 'timed out' "$TMP/err" \
    && bad "no false 'timed out'" "stderr: $(cat "$TMP/err")" \
    || ok "no false 'timed out'"
echo

# ----------------------------------------------------------------
echo "─────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mPASS\033[0m — %d checks\n' "$PASS"; exit 0
else
    printf '\033[31mFAIL\033[0m — %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi
