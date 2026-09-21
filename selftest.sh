#!/usr/bin/env bash
# selftest.sh — prove the pipeline installs clean into a FRESH repo and that every guard it
# ships passes there. This is the claim the README makes, tested rather than asserted.
#
# Safe: it installs into a mktemp git repo and passes --no-shell, so nothing outside that
# directory is touched. Run it before every release.
set -uo pipefail
SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

printf '\n\033[1m### install into a fresh git repo\033[0m\n'
git -C "$T" init -q
git -C "$T" config user.email selftest@example.com
git -C "$T" config user.name  selftest
"$SRC/install.sh" --no-shell "$T" >"$T/.install.log" 2>&1
chk "installer exits 0" "$?" "0"
grep -q 'AGENTS.md' "$T/.install.log" && ok "installer reports what it did" || bad "installer reports what it did"

printf '\n\033[1m### the payload is actually there\033[0m\n'
for f in AGENTS.md .claude/settings.json .claude/bd-prime-hook.sh .claude/bd-prerun-hook.sh \
         .claude/bd-stop-hook.sh .beads-hooks/pre-commit tools/sweep.sh tools/dolt-guard.sh \
         docs/ops/hooks-and-portability.md .claude/skills/triage/SKILL.md \
         .claude/skills/README.md tools/check-no-agent-cache-paths.sh; do
  [ -e "$T/$f" ] && ok "$f" || bad "$f missing"
done
[ -L "$T/CLAUDE.md" ] && [ "$(readlink "$T/CLAUDE.md")" = AGENTS.md ] \
  && ok "CLAUDE.md is a symlink to AGENTS.md" || bad "CLAUDE.md symlink"
[ -x "$T/tools/sweep.sh" ] && ok "tools are executable" || bad "tools are executable"
chk "core.hooksPath set" "$(git -C "$T" config core.hooksPath)" ".beads-hooks"

printf '\n\033[1m### the shipped pre-commit carries all four stanzas\033[0m\n'
# The hook is one file with four independent guards. Dropping one leaves the repo SILENTLY
# unguarded, so assert each by name rather than trusting that the file copied.
for m in 'BEADS INTEGRATION' 'bd-memgraph check' 'agent-cache path guard' 'agent-docs symlink guard'; do
  grep -q "$m" "$T/.beads-hooks/pre-commit" && ok "pre-commit stanza: $m" \
    || bad "pre-commit stanza: $m"
done
# The memory-graph stanza must self-skip when the optional tool is absent, or installing the
# pipeline without bd-memgraph would block every commit.
grep -q 'command -v bd-memgraph' "$T/.beads-hooks/pre-commit" \
  && ok "memory-graph stanza self-skips when bd-memgraph is absent" \
  || bad "memory-graph stanza self-skips when bd-memgraph is absent"

printf '\n\033[1m### every shipped guard passes in the fresh repo\033[0m\n'
for s in tools/check-agent-docs-linked.sh tools/hook_portability_test.sh tools/sweep_test.sh \
         tools/bd-prerun-hook_test.sh tools/dolt-guard_test.sh tools/agent_docs_test.sh \
         tools/check-no-agent-cache-paths_test.sh; do
  if (cd "$T" && ./$s) >"$T/.suite.log" 2>&1; then ok "$s"
  else bad "$s"; sed -n '1,25p' "$T/.suite.log" | sed 's/^/        /'; fi
done

printf '\n\033[1m### the git-layer guard blocks a real commit (this is what covers OTHER harnesses)\033[0m\n'
# The session hooks are Claude Code's. This one is not: it runs from .beads-hooks/pre-commit, so
# it fires for agy, a Grok REPL, Codex, and a human typing git commit. Prove it end to end
# through git rather than by calling the script directly.
G=$(mktemp -d); git -C "$G" init -q
git -C "$G" config user.email t@example.com; git -C "$G" config user.name t
"$SRC/install.sh" --no-shell "$G" >/dev/null 2>&1
printf 'see ![f](/home/someone/.claude/projects/abc/p.png)\n' > "$G/report.md"
git -C "$G" add report.md
git -C "$G" commit -qm "should be blocked" >/dev/null 2>&1
chk "commit carrying a cache path is rejected" "$(git -C "$G" log --oneline 2>/dev/null | wc -l)" "0"
# A guard that blocks everything is not a guard. The clean path must still work.
printf 'see ![f](results/p.png)\n' > "$G/report.md"
git -C "$G" add report.md
git -C "$G" commit -qm "clean" >/dev/null 2>&1
chk "a clean commit still succeeds"          "$(git -C "$G" log --oneline 2>/dev/null | wc -l)" "1"
rm -rf "$G"

printf '\n\033[1m### the peer layer is opt-in and self-consistent\033[0m\n'
# Default install: no peer doc, no peer section, and -- the thing that actually matters --
# AGENTS.md must not cite a doc we did not install. agent_docs_test is what proves that.
[ -f "$T/docs/ops/concurrent-sessions.md" ] && bad "default: peer doc NOT installed" \
  || ok "default: peer doc not installed"
grep -q '^## Concurrent sessions' "$T/AGENTS.md" && bad "default: peer section stripped" \
  || ok "default: peer section stripped from AGENTS.md"
grep -q 'peer:begin\|peer:end' "$T/AGENTS.md" && bad "default: no marker comments leak" \
  || ok "default: no marker comments leak"
grep -q 'concurrent-sessions.md' "$T/AGENTS.md" && bad "default: AGENTS.md cites no missing doc" \
  || ok "default: AGENTS.md cites no missing doc"

P=$(mktemp -d); git -C "$P" init -q
"$SRC/install.sh" --no-shell --with-peer "$P" >/dev/null 2>&1
[ -f "$P/docs/ops/concurrent-sessions.md" ] && ok "--with-peer: peer doc installed" \
  || bad "--with-peer: peer doc installed"
grep -q '^## Concurrent sessions' "$P/AGENTS.md" && ok "--with-peer: peer section present" \
  || bad "--with-peer: peer section present"
grep -q 'peer:begin\|peer:end' "$P/AGENTS.md" && bad "--with-peer: no marker comments leak" \
  || ok "--with-peer: no marker comments leak"
if (cd "$P" && ./tools/agent_docs_test.sh) >"$P/.suite.log" 2>&1; then ok "--with-peer: agent_docs_test passes"
else bad "--with-peer: agent_docs_test passes"; sed -n '1,20p' "$P/.suite.log" | sed 's/^/        /'; fi
rm -rf "$P"

printf '\n\033[1m### the CLAUDE.md symlink, and every way it breaks\033[0m\n'
# One file, two names. The guard has to tell the four states apart, and the one that was missed
# is `dangling`: [ -e ] follows the link and is FALSE for a broken one, so the guard used to exit
# 0 on exactly the state it exists to catch.
S=$(mktemp -d); git -C "$S" init -q
"$SRC/install.sh" --no-shell "$S" >"$S/.log" 2>&1
[ -L "$S/CLAUDE.md" ] && ok "install creates CLAUDE.md as a symlink" || bad "install creates CLAUDE.md as a symlink"
chk "it points at AGENTS.md" "$(readlink "$S/CLAUDE.md")" "AGENTS.md"
guard() { (cd "$S" && ./tools/check-agent-docs-linked.sh) >/dev/null 2>&1; echo $?; }
chk "guard passes when linked"            "$(guard)" "0"
rm -f "$S/CLAUDE.md"; printf 'stale copy\n' > "$S/CLAUDE.md"
chk "guard catches a regular file"        "$(guard)" "1"
# the installer must not quietly overwrite it: that file may be the only copy of someone's edits
"$SRC/install.sh" --no-shell "$S" >"$S/.log2" 2>&1
chk "installer keeps the regular file"    "$(cat "$S/CLAUDE.md")" "stale copy"
grep -q 'REGULAR FILE' "$S/.log2" && ok "installer says why it refused" || bad "installer says why it refused"
rm -f "$S/CLAUDE.md"; touch "$S/other.md"; ln -s other.md "$S/CLAUDE.md"
chk "guard catches the wrong target"      "$(guard)" "1"
rm -f "$S/CLAUDE.md"; ln -s nowhere.md "$S/CLAUDE.md"
chk "guard catches a DANGLING link"       "$(guard)" "1"
rm -rf "$S"

printf '\n\033[1m### re-running changes nothing (idempotence)\033[0m\n'
"$SRC/install.sh" --no-shell "$T" >"$T/.install2.log" 2>&1
grep -q 'nothing to do' "$T/.install2.log" && ok "second run is a no-op" \
  || { bad "second run is a no-op"; grep -E '^\s+\+' "$T/.install2.log" | sed 's/^/        /'; }

printf '\n\033[1m### it refuses to clobber your content\033[0m\n'
printf 'MY OWN DOC\n' > "$T/AGENTS.md.mine"; cp -f "$T/AGENTS.md" "$T/.agents.orig"
printf 'MY OWN DOC\n' > "$T/AGENTS.md"
"$SRC/install.sh" --no-shell "$T" >/dev/null 2>&1
chk "existing AGENTS.md kept" "$(cat "$T/AGENTS.md")" "MY OWN DOC"
[ -f "$T/AGENTS.md.new" ] && ok "ours offered as AGENTS.md.new" || bad "ours offered as AGENTS.md.new"
cp -f "$T/.agents.orig" "$T/AGENTS.md"; rm -f "$T/AGENTS.md.new"

printf '\n\033[1m### --dry-run and --check touch nothing\033[0m\n'
D=$(mktemp -d); git -C "$D" init -q
"$SRC/install.sh" --dry-run "$D" >/dev/null 2>&1
chk "dry-run wrote no files" "$(ls -A "$D" | grep -v '^\.git$' | wc -l)" "0"
"$SRC/install.sh" --check "$D" >/dev/null 2>&1
chk "check wrote no files" "$(ls -A "$D" | grep -v '^\.git$' | wc -l)" "0"
rm -rf "$D"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
