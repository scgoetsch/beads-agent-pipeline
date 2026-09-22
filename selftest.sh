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
# A cache path for the negative controls, built at runtime so this file holds no literal the
# installed guard rejects -- the pipeline's own files must commit clean under its own hooks.
BAD_HOME=/home/someone; BADP="$BAD_HOME/.claude/projects/abc/p.png"

printf '\n\033[1m### install into a fresh git repo\033[0m\n'
git -C "$T" init -q
git -C "$T" config user.email selftest@example.com
git -C "$T" config user.name  selftest
"$SRC/install.sh" --no-shell "$T" >"$T/.install.log" 2>&1; rc=$?
# The exit code depends on the box. The installer exits 1 whenever a required command is
# missing, and that is right: a missing dependency must be loud. So the suite has to know which
# of them THIS box lacks, expect the matching exit code, check each is named, and pin the count
# -- an unrelated warning would change the count and fail here instead of hiding behind an
# expected 1. Asserting 0 unconditionally assumed a fully equipped box, which is how this suite
# passed on the machine it came from and failed on the first bare one.
REQUIRED="git bd python3"             # keep in step with need() in install.sh
missing=0; absent=""
for d in $REQUIRED; do
  command -v "$d" >/dev/null 2>&1 || { missing=$((missing+1)); absent="$absent $d"; }
done
for d in $absent; do
  grep -q " $d MISSING — " "$T/.install.log" && ok "installer names $d as missing" \
    || bad "installer names $d as missing"
done
if [ "$missing" -eq 0 ]; then
  chk "installer exits 0 (every required command present)" "$rc" "0"
else
  chk "installer exits 1 ($missing required command(s) absent:$absent)" "$rc" "1"
  chk "installer counts exactly those $missing as needing attention" \
      "$(sed -n 's/^ *\([0-9][0-9]*\) item(s) need your attention.*/\1/p' "$T/.install.log")" "$missing"
fi
grep -q 'AGENTS.md' "$T/.install.log" && ok "installer reports what it did" || bad "installer reports what it did"

printf '\n\033[1m### the payload is actually there\033[0m\n'
for f in AGENTS.md .claude/settings.json .claude/bd-prime-hook.sh .claude/bd-prerun-hook.sh \
         .claude/bd-stop-hook.sh .beads-hooks/pre-commit tools/sweep.sh tools/dolt-guard.sh \
         docs/ops/hooks-and-portability.md .claude/skills/triage/SKILL.md \
         .claude/skills/README.md tools/check-no-agent-cache-paths.sh \
         tools/check-agent-docs-linked_test.sh; do
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
         tools/bd-prerun-hook_test.sh tools/bd-prime-hook_test.sh tools/dolt-guard_test.sh tools/agent_docs_test.sh \
         tools/check-no-agent-cache-paths_test.sh tools/check-agent-docs-linked_test.sh; do
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
printf 'see ![f](%s)\n' "$BADP" > "$G/report.md"
git -C "$G" add report.md
git -C "$G" commit -qm "should be blocked" >/dev/null 2>&1
chk "commit carrying a cache path is rejected" "$(git -C "$G" log --oneline 2>/dev/null | wc -l)" "0"
# A guard that blocks everything is not a guard. The clean path must still work.
printf 'see ![f](results/p.png)\n' > "$G/report.md"
git -C "$G" add report.md
git -C "$G" commit -qm "clean" >/dev/null 2>&1
chk "a clean commit still succeeds"          "$(git -C "$G" log --oneline 2>/dev/null | wc -l)" "1"
# And the payload itself -- AGENTS.md, the docs, the tools, this guard's own suite -- must commit
# clean under the guards it installs. The first version of the template spelled out a cache path
# as its "wrong" example, and the suite held the literals it tests with, so the first commit that
# touched either was blocked by the pipeline itself.
git -C "$G" add -A
git -C "$G" commit -qm "the whole installed payload" >"$G/.payload.log" 2>&1
n=$(git -C "$G" log --oneline 2>/dev/null | wc -l)
chk "the whole installed payload commits clean under its own guards" "$n" "2"
[ "$n" = "2" ] || sed -n '1,8p' "$G/.payload.log" | sed 's/^/        /'
rm -rf "$G"

printf '\n\033[1m### ...and it is wired even when bd is not on the box\033[0m\n'
# On an equipped machine the block above cannot tell whether hook wiring depends on bd: bd is
# there, so the hooks get wired either way. The bug this guards against (instance 12 in
# docs/ops/checks-narrower-than-what-they-check.md) only showed on a box WITHOUT bd. Hide bd
# from PATH and prove the install still wires the hook and the hook still fires. If hiding bd
# would also hide git or python3, say so loudly rather than pass by omission.
H=$(mktemp -d); git -C "$H" init -q
git -C "$H" config user.email t@example.com; git -C "$H" config user.name t
bare_path=""; oldifs=$IFS; IFS=:
for p in $PATH; do [ -x "$p/bd" ] || bare_path="${bare_path:+$bare_path:}$p"; done
IFS=$oldifs
if PATH="$bare_path" command -v git >/dev/null 2>&1 && PATH="$bare_path" command -v python3 >/dev/null 2>&1; then
  PATH="$bare_path" command -v bd >/dev/null 2>&1 && bad "bd hidden from PATH" || ok "bd hidden from PATH"
  PATH="$bare_path" "$SRC/install.sh" --no-shell "$H" >"$H/.log" 2>&1
  chk "no-bd: installer exits 1"                 "$?" "1"
  chk "no-bd: core.hooksPath set anyway"         "$(git -C "$H" config core.hooksPath)" ".beads-hooks"
  grep -q 'core.hooksPath=.beads-hooks' "$H/.log" && ok "no-bd: installer verifies the wiring, not just the file" \
    || bad "no-bd: installer verifies the wiring, not just the file"
  printf 'see ![f](%s)\n' "$BADP" > "$H/report.md"
  git -C "$H" add report.md
  PATH="$bare_path" git -C "$H" commit -qm "should be blocked" >/dev/null 2>&1
  chk "no-bd: commit carrying a cache path is rejected" "$(git -C "$H" log --oneline 2>/dev/null | wc -l)" "0"
  printf 'see ![f](results/p.png)\n' > "$H/report.md"
  git -C "$H" add report.md
  PATH="$bare_path" git -C "$H" commit -qm "clean" >/dev/null 2>&1
  chk "no-bd: a clean commit still succeeds"     "$(git -C "$H" log --oneline 2>/dev/null | wc -l)" "1"
else
  bad "no-bd probe could not run: hiding bd from PATH also hides git or python3 — move bd to its own directory"
fi
rm -rf "$H"

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
# The four states (linked / regular file / wrong target / dangling) are asserted by the guard's
# OWN suite, tools/check-agent-docs-linked_test.sh, which the loop above runs inside this very
# install. What belongs HERE is only what is specific to installing: that the link gets created,
# and that the installer refuses to overwrite a regular file. Two places asserting one thing is
# how the two drift apart.
rm -f "$S/CLAUDE.md"; printf 'stale copy\n' > "$S/CLAUDE.md"
"$SRC/install.sh" --no-shell "$S" >"$S/.log2" 2>&1
chk "installer keeps an existing regular CLAUDE.md" "$(cat "$S/CLAUDE.md")" "stale copy"
grep -q 'REGULAR FILE' "$S/.log2" && ok "installer says why it refused" || bad "installer says why it refused"
rm -rf "$S"

printf '\n\033[1m### re-running changes nothing (idempotence)\033[0m\n'
"$SRC/install.sh" --no-shell "$T" >"$T/.install2.log" 2>&1
grep -q 'nothing to do' "$T/.install2.log" && ok "second run is a no-op" \
  || { bad "second run is a no-op"; grep -E '^\s+\+' "$T/.install2.log" | sed 's/^/        /'; }

# ...and it stays one after what `bd init` + `bd hooks install --shared` (bd 1.3.0) do to a
# checkout: core.hooksPath rewritten to an ABSOLUTE path, and bd's stanza in the pre-commit
# rewritten to its own version. Neither is drift to "repair". On the first fresh install both
# made every re-run report a change, leave a .new, warn that no guard fires, and exit 1.
git -C "$T" config core.hooksPath "$T/.beads-hooks"
sed -i 's/BEADS INTEGRATION v1\.1\.2/BEADS INTEGRATION v9.9.9/' "$T/.beads-hooks/pre-commit"
"$SRC/install.sh" --no-shell "$T" >"$T/.install3.log" 2>&1
grep -q 'nothing to do' "$T/.install3.log" && ok "still a no-op after bd rewrote hooksPath and its own stanza" \
  || { bad "still a no-op after bd rewrote hooksPath and its own stanza"; grep -E '^\s+[+!]' "$T/.install3.log" | sed 's/^/        /'; }
chk "the absolute hooksPath is left alone" "$(git -C "$T" config core.hooksPath)" "$T/.beads-hooks"
[ -e "$T/.beads-hooks/pre-commit.new" ] && bad "no pre-commit.new left behind" || ok "no pre-commit.new left behind"
grep -q 'NONE of them fires' "$T/.install3.log" && bad "verify does not cry wolf on the absolute path" \
  || ok "verify does not cry wolf on the absolute path"
git -C "$T" config core.hooksPath .beads-hooks

printf '\n\033[1m### it refuses to clobber your content, and drops nothing beside AGENTS.md\033[0m\n'
cp -f "$T/AGENTS.md" "$T/.agents.orig"
# bd init appends its managed block to AGENTS.md. That is neither the user's edit nor drift, and
# the installer used to answer it by writing AGENTS.md.new on every re-run -- a stray file that
# the first outside reader took for a truncated rewrite in progress.
{ cat "$T/.agents.orig"
  printf '\n<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:deadbeef -->\n'
  printf '## Beads Issue Tracker\n\nbd wrote this\n<!-- END BEADS INTEGRATION -->\n'; } > "$T/AGENTS.md"
printf 'left by an earlier run\n' > "$T/AGENTS.md.new"
"$SRC/install.sh" --no-shell "$T" >"$T/.agents1.log" 2>&1
grep -q 'AGENTS.md (current' "$T/.agents1.log" && ok "AGENTS.md with bd's block appended counts as current" \
  || bad "AGENTS.md with bd's block appended counts as current"
[ -e "$T/AGENTS.md.new" ] && bad "a stale AGENTS.md.new is removed" || ok "a stale AGENTS.md.new is removed"
# The user's own edits are the whole point of the file: kept, nothing written beside it, and the
# log says where our template is instead.
printf 'MY OWN DOC\n' > "$T/AGENTS.md"
"$SRC/install.sh" --no-shell "$T" >"$T/.agents2.log" 2>&1
chk "existing AGENTS.md kept" "$(cat "$T/AGENTS.md")" "MY OWN DOC"
[ -e "$T/AGENTS.md.new" ] && bad "no AGENTS.md.new dropped beside an edited AGENTS.md" \
  || ok "no AGENTS.md.new dropped beside an edited AGENTS.md"
grep -q "our template: $SRC/pipeline/AGENTS.md" "$T/.agents2.log" && ok "the log points at the template instead" \
  || bad "the log points at the template instead"
cp -f "$T/.agents.orig" "$T/AGENTS.md"

printf '\n\033[1m### an installed file the target gitignores is named\033[0m\n'
# The origin workspace ignores *.txt, which ate .claude/memory-hot.txt: every clone would have
# taken the SessionStart hook's full-dump fallback. Verify checks every payload file that landed.
printf '*.txt\n' > "$T/.gitignore"
"$SRC/install.sh" --no-shell "$T" >"$T/.eaten.log" 2>&1
grep -q 'GITIGNORED in this repo' "$T/.eaten.log" && grep -qE '^ *\.claude/memory-hot\.txt$' "$T/.eaten.log" \
  && ok "memory-hot.txt under a *.txt rule is reported, by path" || bad "memory-hot.txt under a *.txt rule is reported, by path"
rm -f "$T/.gitignore"
"$SRC/install.sh" --no-shell "$T" >"$T/.eaten2.log" 2>&1
grep -q 'no installed file is gitignored' "$T/.eaten2.log" && ok "and the clean state is stated, not silent" \
  || bad "and the clean state is stated, not silent"

printf '\n\033[1m### the memory-graph ledger: ignored, untracked, tracked — each named\033[0m\n'
# The doc used to recommend `.beads/` + `!.beads/memgraph-ledger.json`, which ignores the ledger:
# git cannot re-include a file under an excluded directory. Verify says which state it is in.
mkdir -p "$T/.beads"; printf '{}\n' > "$T/.beads/memgraph-ledger.json"
printf '.beads/\n' > "$T/.gitignore"
"$SRC/install.sh" --no-shell "$T" >"$T/.ledger1.log" 2>&1
grep -q 'memgraph-ledger.json is GITIGNORED' "$T/.ledger1.log" && ok "ledger under an excluded .beads/ is reported as ignored" \
  || bad "ledger under an excluded .beads/ is reported as ignored"
printf '.beads/*\n!.beads/memgraph-ledger.json\n' > "$T/.gitignore"
"$SRC/install.sh" --no-shell "$T" >"$T/.ledger2.log" 2>&1
grep -q 'memgraph-ledger.json is untracked' "$T/.ledger2.log" && ok "with the working re-include it is reported as untracked" \
  || bad "with the working re-include it is reported as untracked"
git -C "$T" add .beads/memgraph-ledger.json
"$SRC/install.sh" --no-shell "$T" >"$T/.ledger3.log" 2>&1
grep -q 'memgraph-ledger.json is tracked' "$T/.ledger3.log" && ok "once added it is reported as tracked" \
  || bad "once added it is reported as tracked"
git -C "$T" rm -q --cached .beads/memgraph-ledger.json; rm -rf "$T/.beads" "$T/.gitignore"

printf '\n\033[1m### --dry-run and --check touch nothing\033[0m\n'
D=$(mktemp -d); git -C "$D" init -q
"$SRC/install.sh" --dry-run "$D" >/dev/null 2>&1
chk "dry-run wrote no files" "$(ls -A "$D" | grep -v '^\.git$' | wc -l)" "0"
"$SRC/install.sh" --check "$D" >/dev/null 2>&1
chk "check wrote no files" "$(ls -A "$D" | grep -v '^\.git$' | wc -l)" "0"
rm -rf "$D"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
