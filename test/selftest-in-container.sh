#!/usr/bin/env bash
# selftest-in-container.sh — run ./selftest.sh on a clean Ubuntu, in Docker.
#
#   test/selftest-in-container.sh            # both targets: bare, then full
#   test/selftest-in-container.sh bare       # git + python3 only: no bd, jq, rg, ss
#   test/selftest-in-container.sh full       # + bd (latest release), jq, rg, ss, bd-memgraph
#   test/selftest-in-container.sh --build-only [target]
#
# WHY: the self-test had only ever run on boxes that already carried every dependency, so its
# "bare-box branch must still pass" line was a claim, not a measurement. Each run builds the
# image (cached after the first time), mounts this checkout READ-ONLY at /src, copies it to a
# scratch /work inside the container and runs ./selftest.sh there as a non-root user. Nothing is
# written to this checkout. Exit status is the self-test's; the log of a failing run is kept and
# its last lines printed.
set -uo pipefail
SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TAG=beads-agent-pipeline-test
BUILD_ONLY=0; TARGETS=()
for a in "$@"; do
  case $a in
    --build-only) BUILD_ONLY=1 ;;
    bare|full) TARGETS+=("$a") ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
[ "${#TARGETS[@]}" -gt 0 ] || TARGETS=(bare full)
command -v docker >/dev/null 2>&1 || { echo "docker is not on PATH — the container self-test did NOT run." >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable — the container self-test did NOT run." >&2; exit 2; }

LOGDIR=${TMPDIR:-/tmp}/beads-agent-pipeline-container.$$
mkdir -p "$LOGDIR"
overall=0
for t in "${TARGETS[@]}"; do
  printf '\n\033[1m### %s: build\033[0m\n' "$t"
  if ! docker build --quiet --target "$t" -t "$TAG:$t" -f "$SRC/test/Dockerfile" "$SRC/test" > "$LOGDIR/build-$t.log" 2>&1; then
    echo "build FAILED for target $t — see $LOGDIR/build-$t.log"; tail -20 "$LOGDIR/build-$t.log"; overall=1; continue
  fi
  echo "image $TAG:$t"
  [ "$BUILD_ONLY" -eq 1 ] && continue
  printf '\033[1m### %s: ./selftest.sh on a clean box\033[0m\n' "$t"
  docker run --rm -v "$SRC:/src:ro" "$TAG:$t" bash -lc '
    set -u
    cp -r /src /home/tester/work && cd /home/tester/work || exit 2
    printf "box: %s  bash %s  bd %s  jq %s  rg %s  ss %s\n" "$(. /etc/os-release; echo "$PRETTY_NAME")" "$BASH_VERSION" \
      "$(bd --version 2>/dev/null | head -1 || echo absent)" "$(command -v jq >/dev/null && echo yes || echo no)" \
      "$(command -v rg >/dev/null && echo yes || echo no)" "$(command -v ss >/dev/null && echo yes || echo no)"
    ./selftest.sh
  ' > "$LOGDIR/selftest-$t.log" 2>&1
  rc=$?
  head -1 "$LOGDIR/selftest-$t.log"
  grep -E 'RESULT:' "$LOGDIR/selftest-$t.log" | tail -1
  if [ "$rc" -ne 0 ]; then
    overall=1
    echo "selftest FAILED in $t (exit $rc) — log: $LOGDIR/selftest-$t.log"
    grep -nE 'FAIL|\bbad\b' "$LOGDIR/selftest-$t.log" | head -20
  else
    echo "selftest passed in $t"
  fi
done
[ "$overall" -eq 0 ] && rm -rf "$LOGDIR"
exit "$overall"
