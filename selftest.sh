#!/usr/bin/env bash
# selftest.sh — prove the pipeline installs clean into a FRESH repo and that every guard it
# ships passes there. This is the claim the README makes, tested rather than asserted.
#
# Safe: it installs into mktemp git repos. The installer writes nothing outside the target except
# to remove its old ~/.bashrc block for THAT target, which a fresh mktemp target never has; the
# one probe that exercises that removal runs with HOME pointed at a scratch directory. Run it
# before every release.
set -uo pipefail
SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# Git Bash's `ln -s` COPIES by default; this makes it a real symlink or a failure, which is what
# every link proof below needs. Inert anywhere else.
export MSYS=winsymlinks:nativestrict
# The link, in either of its forms: a real symlink, or on a filesystem without symlinks the
# installer's pointer file (holding "AGENTS.md") staged as a symlink (index mode 120000).
linked_to_agents() {  # linked_to_agents DIR -> 0 when CLAUDE.md there is the link to AGENTS.md
  if [ -L "$1/CLAUDE.md" ]; then [ "$(readlink "$1/CLAUDE.md")" = AGENTS.md ]; return; fi
  [ -f "$1/CLAUDE.md" ] && [ "$(cat "$1/CLAUDE.md")" = AGENTS.md ] || return 1
  case "$(git -C "$1" ls-files --stage -- CLAUDE.md 2>/dev/null)" in "120000 "*) return 0 ;; esac
  return 1
}
# One directory, one spelling: git on Windows reports a hooksPath it was handed as /tmp/... in
# the form MSYS converted it to (C:/Users/RUNNER~1/...), so compare canonical forms.
canon_dir() {  # canon_dir PATH -> physical path; on MSYS the Windows long name, lower-cased
  local p; p=$(cd -- "$1" 2>/dev/null && pwd -P) || p=$1
  if command -v cygpath >/dev/null 2>&1; then cygpath -ml "$p" 2>/dev/null | tr '[:upper:]' '[:lower:]'
  else printf '%s\n' "$p"; fi
}
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
"$SRC/install.sh" "$T" >"$T/.install.log" 2>&1; rc=$?
# The exit code depends on the box. The installer exits 1 whenever a required command is
# missing, and that is right: a missing dependency must be loud. So the suite has to know which
# of them THIS box lacks, expect the matching exit code, check each is named, and pin the count
# -- an unrelated warning would change the count and fail here instead of hiding behind an
# expected 1. Asserting 0 unconditionally assumed a fully equipped box, which is how this suite
# passed on the machine it came from and failed on the first bare one.
REQUIRED="git cairn python3"          # keep in step with need() in install.sh
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
         .claude/bd-stop-hook.sh .beads-hooks/pre-commit .beads-hooks/post-merge .beads-hooks/post-checkout tools/sweep.sh \
         tools/refresh-beads-exports.sh tools/new-worktree.sh \
         docs/ops/hooks-and-portability.md .claude/skills/triage/SKILL.md \
         .claude/skills/README.md tools/check-no-agent-cache-paths.sh \
         tools/check-agent-docs-linked_test.sh .claude/site-checks/memory-curation-gate.sh \
         tools/memory-curation-gate_test.sh; do
  [ -e "$T/$f" ] && ok "$f" || bad "$f missing"
done
# The curation stamp is written by the installer, not shipped: today's date, a count, one line.
if [ -f "$T/.claude/memory-curation.txt" ] \
   && grep -qE "^$(date +%Y-%m-%d)	[0-9]+$" "$T/.claude/memory-curation.txt"; then
  ok ".claude/memory-curation.txt stamped by the installer (today, a count)"
else bad ".claude/memory-curation.txt stamped by the installer"; fi
[ -x "$T/.claude/site-checks/memory-curation-gate.sh" ] && ok "site check is executable" \
  || bad "site check is executable"
linked_to_agents "$T" && ok "CLAUDE.md is the link to AGENTS.md (a symlink, or its pointer form where there are none)" \
  || bad "CLAUDE.md symlink"
[ -x "$T/tools/sweep.sh" ] && ok "tools are executable" || bad "tools are executable"
[ -x "$T/.claude/skills/memory-curate/audit_wikilinks.py" ] && ok "skill scripts are executable" \
  || bad "skill scripts are executable"
chk "core.hooksPath set" "$(git -C "$T" config core.hooksPath)" ".beads-hooks"

printf '\n\033[1m### the shipped pre-commit carries all four stanzas, and nothing of bd\033[0m\n'
# The hook is one file with four independent guards. Dropping one leaves the repo SILENTLY
# unguarded, so assert each by name rather than trusting that the file copied.
for m in '>>> store check >>>' 'agent-cache path guard' 'agent-docs symlink guard' 'export freshness guard'; do
  grep -q "$m" "$T/.beads-hooks/pre-commit" && ok "pre-commit stanza: $m" \
    || bad "pre-commit stanza: $m"
done
# This release does not read bd. Nothing installed may call it or carry its managed block.
chk "no installed hook runs \`bd hooks run\`" \
    "$(cat "$T"/.beads-hooks/* "$T"/.claude/*.sh | grep -c 'bd hooks run' | tr -d ' ')" 0
chk "no installed hook carries a BEGIN BEADS block" \
    "$(cat "$T"/.beads-hooks/* "$T"/.claude/*.sh | grep -c 'BEGIN BEADS' | tr -d ' ')" 0
chk "no installed hook reads .claude/store-cli" \
    "$(cat "$T"/.beads-hooks/* "$T"/.claude/*.sh | grep -c '\.claude/store-cli' | tr -d ' ')" 0
[ ! -e "$T/.claude/store-cli" ] && ok "no .claude/store-cli written" || bad "the installer wrote .claude/store-cli"
chk "no store-cli or dolt-guard tool installed" \
    "$(ls "$T"/tools/store-cli* "$T"/tools/dolt-guard* 2>/dev/null | wc -l | tr -d ' ')" 0
# The store stanza must self-skip without cairn or a store, or installing before `cairn init`
# would block every commit.
grep -q 'command -v cairn >/dev/null 2>&1 && \[ -d .cairn \]' "$T/.beads-hooks/pre-commit" \
  && ok "store stanza self-skips without cairn or .cairn/" \
  || bad "store stanza self-skips without cairn or .cairn/"
grep -q 'note: --no-shell does nothing' "$T/.install.log" && bad "no --no-shell note without the flag" \
  || ok "no --no-shell note without the flag"

printf '\n\033[1m### every shipped guard passes in the fresh repo\033[0m\n'
for s in tools/check-agent-docs-linked.sh tools/hook_portability_test.sh tools/sweep_test.sh \
         tools/bd-prerun-hook_test.sh tools/bd-prime-hook_test.sh tools/bd-stop-hook_test.sh \
         tools/agent_docs_test.sh \
         tools/check-no-agent-cache-paths_test.sh tools/check-agent-docs-linked_test.sh \
         tools/audit_wikilinks_test.sh tools/memory-curation-gate_test.sh \
         tools/refresh-beads-exports_test.sh tools/new-worktree_test.sh; do
  suite_tmp=$(mktemp -d)
  if (cd "$T" && TMPDIR="$suite_tmp" ./$s) >"$T/.suite.log" 2>&1; then ok "$s"
  else bad "$s"; tail -35 "$T/.suite.log" | sed 's/^/        /'; fi
  if [ -z "$(find "$suite_tmp" -mindepth 1 -print -quit)" ]; then ok "$s cleans its scratch directory"
  else bad "$s leaked scratch files"; fi
  rm -rf "$suite_tmp"
done

printf '\n\033[1m### the git-layer guard blocks a real commit (this is what covers OTHER harnesses)\033[0m\n'
# The session hooks are Claude Code's. This one is not: it runs from .beads-hooks/pre-commit, so
# it fires for agy, a Grok REPL, Codex, and a human typing git commit. Prove it end to end
# through git rather than by calling the script directly.
G=$(mktemp -d); git -C "$G" init -q
git -C "$G" config user.email t@example.com; git -C "$G" config user.name t
"$SRC/install.sh" "$G" >/dev/null 2>&1
printf 'see ![f](%s)\n' "$BADP" > "$G/report.md"
git -C "$G" add report.md
git -C "$G" commit -qm "should be blocked" >/dev/null 2>&1
# BSD wc pads its count ("       0"), so every count below is stripped before the comparison.
chk "commit carrying a cache path is rejected" "$(git -C "$G" log --oneline 2>/dev/null | wc -l | tr -d ' ')" "0"
# A guard that blocks everything is not a guard. The clean path must still work.
printf 'see ![f](results/p.png)\n' > "$G/report.md"
git -C "$G" add report.md
git -C "$G" commit -qm "clean" >/dev/null 2>&1
chk "a clean commit still succeeds"          "$(git -C "$G" log --oneline 2>/dev/null | wc -l | tr -d ' ')" "1"
# And the payload itself -- AGENTS.md, the docs, the tools, this guard's own suite -- must commit
# clean under the guards it installs. The first version of the template spelled out a cache path
# as its "wrong" example, and the suite held the literals it tests with, so the first commit that
# touched either was blocked by the pipeline itself.
git -C "$G" add -A
git -C "$G" commit -qm "the whole installed payload" >"$G/.payload.log" 2>&1
n=$(git -C "$G" log --oneline 2>/dev/null | wc -l | tr -d ' ')
chk "the whole installed payload commits clean under its own guards" "$n" "2"
[ "$n" = "2" ] || sed -n '1,8p' "$G/.payload.log" | sed 's/^/        /'
# Partial staging must not let a clean working copy launder a bad index.
printf 'see ![f](%s)\n' "$BADP" > "$G/report.md"; git -C "$G" add report.md
printf 'see ![f](results/p.png)\n' > "$G/report.md"
git -C "$G" commit -qm "bad staged report" >"$G/.proof.log" 2>&1
chk "bad staged document with clean working copy is refused" "$?" "1"
grep -q 'forbidden agent-cache' "$G/.proof.log" && ok "refusal came from cache-path guard" || bad "refusal came from cache-path guard"
git -C "$G" add report.md
rm -f "$G/CLAUDE.md"; ln -s wrong.md "$G/CLAUDE.md"; git -C "$G" add CLAUDE.md
rm -f "$G/CLAUDE.md"; ln -s AGENTS.md "$G/CLAUDE.md"
git -C "$G" commit -qm "bad staged link" >"$G/.proof.log" 2>&1
chk "bad staged link with good working link is refused" "$?" "1"
grep -q 'agent-docs:' "$G/.proof.log" && ok "refusal came from agent-docs guard" || bad "refusal came from agent-docs guard"
git -C "$G" add CLAUDE.md
# Conversely an unstaged problem must NOT reject an otherwise clean staged change.
printf 'clean change\n' >> "$G/report.md"; git -C "$G" add report.md
printf 'see ![f](%s)\n' "$BADP" > "$G/report.md"
rm -f "$G/CLAUDE.md"; printf 'unstaged divergent copy\n' > "$G/CLAUDE.md"
git -C "$G" commit -qm "clean index despite dirty working copies" >"$G/.proof.log" 2>&1
chk "clean staged document and link pass despite dirty working copies" "$?" "0"
rm -rf "$G"

printf '\n\033[1m### ...and it is wired even when cairn is not on the box\033[0m\n'
# On an equipped machine the block above cannot tell whether hook wiring depends on the store
# CLI: it is there, so the hooks get wired either way. The bug this guards against (instance 12
# in docs/ops/checks-narrower-than-what-they-check.md) only showed on a box WITHOUT the tracker.
# Hide cairn from PATH and prove the install still wires the hook and the hook still fires. If
# hiding it would also hide git or python3, say so loudly rather than pass by omission.
H=$(mktemp -d); git -C "$H" init -q
git -C "$H" config user.email t@example.com; git -C "$H" config user.name t
bare_path=""; oldifs=$IFS; IFS=:
for p in $PATH; do [ -x "$p/cairn" ] || bare_path="${bare_path:+$bare_path:}$p"; done
IFS=$oldifs
if PATH="$bare_path" command -v git >/dev/null 2>&1 && PATH="$bare_path" command -v python3 >/dev/null 2>&1; then
  PATH="$bare_path" command -v cairn >/dev/null 2>&1 && bad "cairn hidden from PATH" || ok "cairn hidden from PATH"
  PATH="$bare_path" "$SRC/install.sh" "$H" >"$H/.log" 2>&1
  chk "no-cairn: installer exits 1"              "$?" "1"
  grep -q ' cairn MISSING — ' "$H/.log" && ok "no-cairn: installer names cairn as missing" || bad "no-cairn: installer names cairn as missing"
  chk "no-cairn: core.hooksPath set anyway"      "$(git -C "$H" config core.hooksPath)" ".beads-hooks"
  grep -q 'core.hooksPath=.beads-hooks' "$H/.log" && ok "no-cairn: installer verifies the wiring, not just the file" \
    || bad "no-cairn: installer verifies the wiring, not just the file"
  printf 'see ![f](%s)\n' "$BADP" > "$H/report.md"
  git -C "$H" add report.md
  PATH="$bare_path" git -C "$H" commit -qm "should be blocked" >/dev/null 2>&1
  chk "no-cairn: commit carrying a cache path is rejected" "$(git -C "$H" log --oneline 2>/dev/null | wc -l | tr -d ' ')" "0"
  printf 'see ![f](results/p.png)\n' > "$H/report.md"
  git -C "$H" add report.md
  PATH="$bare_path" git -C "$H" commit -qm "clean" >/dev/null 2>&1
  chk "no-cairn: a clean commit still succeeds"  "$(git -C "$H" log --oneline 2>/dev/null | wc -l | tr -d ' ')" "1"
else
  bad "no-cairn probe could not run: hiding cairn from PATH also hides git or python3 — move cairn to its own directory"
fi
rm -rf "$H"
rm -rf "$H"

printf '\n\033[1m### the peer layer is opt-in and self-consistent\033[0m\n'
# Default install: no peer doc, no peer section, and -- the thing that actually matters --
# AGENTS.md must not cite a doc we did not install. agent_docs_test is what proves that.
[ -f "$T/docs/ops/concurrent-sessions.md" ] && bad "default: peer doc NOT installed" \
  || ok "default: peer doc not installed"
grep -q '^## Concurrent sessions' "$T/AGENTS.md" && bad "default: peer section stripped" \
  || ok "default: peer section stripped from AGENTS.md"
grep -q 'concurrent:begin\|concurrent:end' "$T/AGENTS.md" && bad "default: no marker comments leak" \
  || ok "default: no marker comments leak"
grep -q 'concurrent-sessions.md' "$T/AGENTS.md" && bad "default: AGENTS.md cites no missing doc" \
  || ok "default: AGENTS.md cites no missing doc"

P=$(mktemp -d); git -C "$P" init -q
"$SRC/install.sh" --with-concurrent "$P" >/dev/null 2>&1
[ -f "$P/docs/ops/concurrent-sessions.md" ] && ok "--with-concurrent: concurrency doc installed" \
  || bad "--with-concurrent: concurrency doc installed"
grep -q '^## Concurrent sessions' "$P/AGENTS.md" && ok "--with-concurrent: concurrency section present" \
  || bad "--with-concurrent: concurrency section present"
grep -q 'concurrent:begin\|concurrent:end' "$P/AGENTS.md" && bad "--with-concurrent: no marker comments leak" \
  || ok "--with-concurrent: no marker comments leak"
if (cd "$P" && ./tools/agent_docs_test.sh) >"$P/.suite.log" 2>&1; then ok "--with-concurrent: agent_docs_test passes"
else bad "--with-concurrent: agent_docs_test passes"; sed -n '1,20p' "$P/.suite.log" | sed 's/^/        /'; fi
"$SRC/install.sh" --with-peer "$P" >"$P/.alias.log" 2>&1
grep -q -- '--with-peer is now --with-concurrent' "$P/.alias.log" && ok "--with-peer: deprecated alias still accepted, with a note" \
  || bad "--with-peer: deprecated alias still accepted, with a note"
rm -rf "$P"

printf '\n\033[1m### the Pi adapter is opt-in and does not overwrite user files\033[0m\n'
[ -e "$T/.pi/extensions/beads-pipeline.ts" ] && bad "default: Pi adapter not installed" \
  || ok "default: Pi adapter not installed"
Q=$(mktemp -d); git -C "$Q" init -q
mkdir -p "$Q/.pi/extensions"; printf 'my own extension\n' > "$Q/.pi/extensions/local.ts"
printf '{"extensions":["./my.ts"]}\n' > "$Q/.pi/settings.json"
"$SRC/install.sh" --with-pi "$Q" >"$Q/.install.log" 2>&1; pi_rc=$?
pi_missing=0; { command -v pi >/dev/null 2>&1 && pi --version >/dev/null 2>&1; } || pi_missing=1
chk "--with-pi: installer exit matches dependencies" "$pi_rc" "$((missing > 0 || pi_missing > 0))"
[ -f "$Q/.pi/extensions/beads-pipeline.ts" ] && ok "--with-pi: adapter installed" || bad "--with-pi: adapter installed"
chk "--with-pi: existing unrelated extension preserved" "$(cat "$Q/.pi/extensions/local.ts")" "my own extension"
chk "--with-pi: user Pi settings untouched" "$(cat "$Q/.pi/settings.json")" '{"extensions":["./my.ts"]}'
grep -q 'trust this project' "$Q/.install.log" && ok "--with-pi: installer reports trust gate" || bad "--with-pi: installer reports trust gate"
if (cd "$Q" && ./tools/pi-extension_test.sh) >"$Q/.suite.log" 2>&1; then
  if grep -q '^SKIP' "$Q/.suite.log"; then echo "  SKIP Pi event suite: $(head -1 "$Q/.suite.log")"
  else ok "Pi adapter event suite passes in the installed clone"; fi
else bad "Pi adapter event suite passes in the installed clone"; tail -30 "$Q/.suite.log" | sed 's/^/        /'; fi
"$SRC/install.sh" --with-pi "$Q" >"$Q/.rerun.log" 2>&1
grep -q 'nothing to do' "$Q/.rerun.log" && ok "--with-pi: second install is a no-op" || bad "--with-pi: second install is a no-op"
printf 'custom guard\n' > "$Q/.pi/extensions/beads-pipeline.ts"
"$SRC/install.sh" --with-pi "$Q" >"$Q/.custom.log" 2>&1
chk "--with-pi: modified adapter preserved" "$(cat "$Q/.pi/extensions/beads-pipeline.ts")" "custom guard"
cmp -s "$SRC/pipeline/.pi/extensions/beads-pipeline.ts" "$Q/.pi/extensions/beads-pipeline.ts.new" \
  && ok "--with-pi: replacement staged as .new" || bad "--with-pi: replacement staged as .new"
rm -rf "$Q"

printf '\n\033[1m### the CLAUDE.md symlink, and every way it breaks\033[0m\n'
# One file, two names. The guard has to tell the four states apart, and the one that was missed
# is `dangling`: [ -e ] follows the link and is FALSE for a broken one, so the guard used to exit
# 0 on exactly the state it exists to catch.
S=$(mktemp -d); git -C "$S" init -q
"$SRC/install.sh" "$S" >"$S/.log" 2>&1
linked_to_agents "$S" && ok "install creates CLAUDE.md as the link to AGENTS.md" || bad "install creates CLAUDE.md as the link to AGENTS.md"
# The four states (linked / regular file / wrong target / dangling) are asserted by the guard's
# OWN suite, tools/check-agent-docs-linked_test.sh, which the loop above runs inside this very
# install. What belongs HERE is only what is specific to installing: that the link gets created,
# and that the installer refuses to overwrite a regular file. Two places asserting one thing is
# how the two drift apart.
rm -f "$S/CLAUDE.md"; printf 'stale copy\n' > "$S/CLAUDE.md"
"$SRC/install.sh" "$S" >"$S/.log2" 2>&1
chk "installer keeps an existing regular CLAUDE.md" "$(cat "$S/CLAUDE.md")" "stale copy"
grep -q 'REGULAR FILE' "$S/.log2" && ok "installer says why it refused" || bad "installer says why it refused"
rm -rf "$S"

printf '\n\033[1m### no symlinks on the target filesystem: a pointer file that commits as a link\033[0m\n'
# Git for Windows without Developer Mode cannot make a symlink, and MSYS `ln -s` silently copies
# instead. The installer then writes git's own on-disk form of the link -- a file holding the
# target's name -- and stages it as mode 120000, so the commit carries a real symlink and a clone
# with symlinks gets one. Forced here with BAP_INSTALL_NO_SYMLINKS, under core.symlinks=false as
# git sets it on such a box, so a Linux box exercises the path too.
N=$(mktemp -d); git -C "$N" init -q
git -C "$N" config user.email t@example.com; git -C "$N" config user.name t
git -C "$N" config core.symlinks false
BAP_INSTALL_NO_SYMLINKS=1 "$SRC/install.sh" "$N" >"$N/.log" 2>&1
[ -L "$N/CLAUDE.md" ] && bad "no-symlink install: CLAUDE.md is a regular pointer file" || ok "no-symlink install: CLAUDE.md is a regular pointer file"
chk "no-symlink install: it holds exactly the target's name" "$(cat "$N/CLAUDE.md")" "AGENTS.md"
chk "no-symlink install: the index holds it as a symlink" "$(git -C "$N" ls-files --stage -- CLAUDE.md | cut -c1-6)" "120000"
grep -q 'POINTER FILE' "$N/.log" && ok "no-symlink install: the installer says what it did" || bad "no-symlink install: the installer says what it did"
(cd "$N" && ./tools/check-agent-docs-linked.sh) >"$N/.guard.log" 2>&1 && ok "no-symlink install: the guard accepts the pointer state" \
  || { bad "no-symlink install: the guard accepts the pointer state"; sed -n '1,3p' "$N/.guard.log" | sed 's/^/        /'; }
git -C "$N" add -A
git -C "$N" commit -qm "pointer form" >"$N/.commit.log" 2>&1 && ok "no-symlink install: the payload commits under the guards" \
  || { bad "no-symlink install: the payload commits under the guards"; sed -n '1,6p' "$N/.commit.log" | sed 's/^/        /'; }
chk "no-symlink install: the commit carries a symlink" "$(git -C "$N" ls-tree HEAD -- CLAUDE.md | cut -c1-6)" "120000"
git clone -q "$N" "$N.clone" 2>/dev/null
[ -L "$N.clone/CLAUDE.md" ] && [ "$(readlink "$N.clone/CLAUDE.md")" = AGENTS.md ] \
  && ok "no-symlink install: a clone on a box with symlinks gets the real link" || bad "no-symlink install: a clone on a box with symlinks gets the real link"
BAP_INSTALL_NO_SYMLINKS=1 "$SRC/install.sh" "$N" >"$N/.log2" 2>&1
grep -q 'nothing to do' "$N/.log2" && ok "no-symlink install: the re-run is a no-op" \
  || { bad "no-symlink install: the re-run is a no-op"; grep -E '^\s+[+!]' "$N/.log2" | sed 's/^/        /'; }
rm -rf "$N" "$N.clone"

printf '\n\033[1m### re-running changes nothing (idempotence)\033[0m\n'
"$SRC/install.sh" "$T" >"$T/.install2.log" 2>&1
grep -q 'nothing to do' "$T/.install2.log" && ok "second run is a no-op" \
  || { bad "second run is a no-op"; grep -E '^\s+\+' "$T/.install2.log" | sed 's/^/        /'; }

# ...and it stays one after core.hooksPath is rewritten to an ABSOLUTE path (other tools do;
# the old tracker's hook installer did). That is not drift to "repair": on the first fresh install
# it made every re-run report a change, warn that no guard fires, and exit 1.
git -C "$T" config core.hooksPath "$T/.beads-hooks"
"$SRC/install.sh" "$T" >"$T/.install3.log" 2>&1
grep -q 'nothing to do' "$T/.install3.log" && ok "still a no-op after hooksPath went absolute" \
  || { bad "still a no-op after hooksPath went absolute"; grep -E '^\s+[+!]' "$T/.install3.log" | sed 's/^/        /'; }
chk "the absolute hooksPath is left alone" "$(canon_dir "$(git -C "$T" config core.hooksPath)")" "$(canon_dir "$T/.beads-hooks")"
grep -q 'NONE of them fires' "$T/.install3.log" && bad "verify does not cry wolf on the absolute path" \
  || ok "verify does not cry wolf on the absolute path"
git -C "$T" config core.hooksPath .beads-hooks

# The old tracker's own harness hooks (its `bd init` registers `bd prime` at SessionStart) read a
# store this release does not have. The installer removes them, says so, and keeps every hook of
# the user's, including hooks sharing an event or a group with them.
if command -v jq >/dev/null 2>&1; then
jq '.hooks.SessionStart = [{"matcher":"","hooks":[{"type":"command","command":"bd prime --hook-json"}]}]'  \
  "$T/.claude/settings.json" > "$T/.settings.bdinit" && cp -f "$T/.settings.bdinit" "$T/.claude/settings.json"
"$SRC/install.sh" "$T" >"$T/.install4.log" 2>&1; rc4=$?
grep -q "removed a harness hook that runs bd — .claude/settings.json SessionStart: bd prime --hook-json" "$T/.install4.log" \
  && ok "the old tracker's SessionStart hook is removed, and said so" \
  || bad "the old tracker's SessionStart hook is removed, and said so"
chk "  …and nothing left anywhere in settings.json runs it" "$(jq '[.. | .command? // empty | select(test("^\\s*bd(\\s|$)"))] | length' "$T/.claude/settings.json")" 0
[ "$missing" -eq 0 ] && chk "...and the re-run exits 0" "$rc4" "0"
chk "our SessionStart hook is back" "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$T/.claude/settings.json" | grep -c 'bd-prime-hook.sh')" "1"
"$SRC/install.sh" "$T" >"$T/.install5.log" 2>&1
grep -q 'nothing to do' "$T/.install5.log" && ok "and the run after that is a no-op" || bad "and the run after that is a no-op"
jq '.hooks.PreToolUse += [{"matcher":"","hooks":[{"type":"command","command":"echo mine"}]}]' \
  "$T/.claude/settings.json" > "$T/.settings.user" && cp -f "$T/.settings.user" "$T/.claude/settings.json"
"$SRC/install.sh" "$T" >"$T/.install6.log" 2>&1
chk "user PreToolUse command survives the merge" "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command == "echo mine")] | length' "$T/.claude/settings.json")" "1"
# Mixed groups, prompt hooks, and commands merely mentioning bd prime are user-owned.
jq '.hooks.SessionStart = [{"matcher":"startup","hooks":[
      {"type":"command","command":"bd prime --hook-json"},
      {"type":"command","command":"echo keep-bd prime"},
      {"type":"prompt","prompt":"retain this prompt"}]}]' \
  "$T/.claude/settings.json" > "$T/.settings.mixedgroup"
cp -f "$T/.settings.mixedgroup" "$T/.claude/settings.json"
"$SRC/install.sh" "$T" >"$T/.mixedgroup.log" 2>&1
chk "mixed group retains its matcher and non-bd hooks" "$(jq '[.hooks.SessionStart[] | select(.matcher == "startup") | .hooks[]] | length' "$T/.claude/settings.json")" "2"
cp -f "$T/.claude/settings.json" "$T/.settings.before-rerun"
"$SRC/install.sh" "$T" >/dev/null 2>&1
cmp -s "$T/.settings.before-rerun" "$T/.claude/settings.json" && ok "merged user hooks are idempotent" || bad "merged user hooks are idempotent"
# A hook under an event we do NOT define (Notification here) is preserved by the merge.
jq '.hooks.Notification = [{"matcher":"","hooks":[{"type":"command","command":"notify-send done"}]}]
    | .hooks.SessionStart = [{"matcher":"","hooks":[{"type":"command","command":"bd prime --hook-json"}]}]' \
  "$T/.claude/settings.json" > "$T/.settings.mixed" && cp -f "$T/.settings.mixed" "$T/.claude/settings.json"
"$SRC/install.sh" "$T" >"$T/.install7.log" 2>&1; rc7=$?
chk "the untouched event's hook survives the merge" "$(jq -r '.hooks.Notification[0].hooks[0].command' "$T/.claude/settings.json")" "notify-send done"
[ "$missing" -eq 0 ] && chk "...and that re-run exits 0" "$rc7" "0"
# The pipeline's own 0.1 hook groups (the same commands, with the old missing-hook wording) are
# REPLACED by the current ones, not kept beside them: two groups would run every hook twice.
jq '.hooks |= with_entries(.value |= map(.hooks |= map(if (.command // "") | test("bd-(prime|prerun|stop)-hook") then .command |= sub("the pipeline.s session rules"; "bd session rules") else . end)))' \
  "$T/.claude/settings.json" > "$T/.settings.v01" && cp -f "$T/.settings.v01" "$T/.claude/settings.json"
chk "  (the fixture carries the 0.1 wording)" "$(grep -c 'bd session rules' "$T/.claude/settings.json" | tr -d ' ')" 4
"$SRC/install.sh" "$T" >/dev/null 2>&1
chk "0.1's pipeline groups are replaced, not doubled" \
    "$(jq '[.hooks[][] | .hooks[] | select((.command // "") | test("bd-(prime|prerun|stop)-hook"))] | length' "$T/.claude/settings.json")" 4
chk "  …with the current wording" "$(grep -c 'bd session rules' "$T/.claude/settings.json" | tr -d ' ')" 0
rm -f "$T"/.claude/settings.json.bak.*
else
  echo '  SKIP settings merge tests: jq absent (installer preserves existing settings as-is)'
fi

printf '\n\033[1m### it refuses to clobber your content, and drops nothing beside AGENTS.md\033[0m\n'
cp -f "$T/AGENTS.md" "$T/.agents.orig"
# The old tracker appended a managed block to AGENTS.md telling agents to use it. The file is the
# user's, so the block is NAMED (it now gives wrong instructions), never removed and never answered
# with an AGENTS.md.new -- a stray file the first outside reader took for a rewrite in progress.
{ cat "$T/.agents.orig"
  printf '\n<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:deadbeef -->\n'
  printf '## Beads Issue Tracker\n\nbd wrote this\n<!-- END BEADS INTEGRATION -->\n'; } > "$T/AGENTS.md"
cp -f "$T/AGENTS.md" "$T/.agents.withblock"
printf 'left by an earlier run\n' > "$T/AGENTS.md.new"
"$SRC/install.sh" "$T" >"$T/.agents1.log" 2>&1
grep -q "AGENTS.md still carries bd's managed block" "$T/.agents1.log" && ok "an old managed block in AGENTS.md is named" \
  || bad "an old managed block in AGENTS.md is named"
cmp -s "$T/.agents.withblock" "$T/AGENTS.md" && ok "  …and AGENTS.md is not edited" || bad "  …and AGENTS.md is not edited"
[ -e "$T/AGENTS.md.new" ] && bad "a stale AGENTS.md.new is removed" || ok "a stale AGENTS.md.new is removed"
# The user's own edits are the whole point of the file: kept, nothing written beside it, and the
# log says where our template is instead.
printf 'MY OWN DOC\n' > "$T/AGENTS.md"
"$SRC/install.sh" "$T" >"$T/.agents2.log" 2>&1
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
"$SRC/install.sh" "$T" >"$T/.eaten.log" 2>&1
grep -q 'GITIGNORED in this repo' "$T/.eaten.log" && grep -qE '^ *\.claude/memory-hot\.txt$' "$T/.eaten.log" \
  && ok "memory-hot.txt under a *.txt rule is reported, by path" || bad "memory-hot.txt under a *.txt rule is reported, by path"
rm -f "$T/.gitignore"
"$SRC/install.sh" "$T" >"$T/.eaten2.log" 2>&1
grep -q 'no installed file is gitignored' "$T/.eaten2.log" && ok "and the clean state is stated, not silent" \
  || bad "and the clean state is stated, not silent"

printf '\n\033[1m### linked worktrees install without changing the main checkout hooks\033[0m\n'
W=$(mktemp -d)
git -C "$W" init -q main
git -C "$W/main" config user.email t@example.com; git -C "$W/main" config user.name t
git -C "$W/main" commit --allow-empty -qm base
git -C "$W/main" config core.hooksPath main-hooks
git -C "$W/main" worktree add -q "$W/linked" -b linked
"$SRC/install.sh" "$W/linked" >"$W/install.log" 2>&1; wrc=$?
chk "worktree installer exit matches dependency status" "$wrc" "$((missing > 0))"
chk "linked worktree hooks are wired" "$(git -C "$W/linked" config core.hooksPath)" ".beads-hooks"
chk "main checkout hooks unchanged" "$(git -C "$W/main" config core.hooksPath)" "main-hooks"
printf 'see ![f](%s)\n' "$BADP" > "$W/linked/bad.md"; git -C "$W/linked" add bad.md
git -C "$W/linked" commit -qm bad >"$W/commit.log" 2>&1
chk "worktree commit runs the installed guard" "$?" "1"
grep -q 'forbidden agent-cache' "$W/commit.log" && ok "worktree refusal is attributable" || bad "worktree refusal is attributable"
# A .git file also represents a submodule; it must use its own config, not its parent's.
git -C "$W/main" -c protocol.file.allow=always submodule add -q "$W/linked" child
"$SRC/install.sh" "$W/main/child" >"$W/submodule.log" 2>&1
chk "submodule install exit matches dependency status" "$?" "$((missing > 0))"
chk "submodule hooks are wired" "$(git -C "$W/main/child" config core.hooksPath)" ".beads-hooks"
chk "submodule install preserves parent hooks" "$(git -C "$W/main" config core.hooksPath)" "main-hooks"
# Enabling worktreeConfig must migrate core.bare out of the shared config, preserving the
# main bare repository while the checkout remains non-bare.
git clone -q --bare "$W/main" "$W/bare.git"
git --git-dir="$W/bare.git" worktree add -q "$W/bare-linked" -b bare-linked
"$SRC/install.sh" "$W/bare-linked" >"$W/bare.log" 2>&1
chk "bare-parent worktree install exit matches dependency status" "$?" "$((missing > 0))"
chk "main bare repo stays bare" "$(git --git-dir="$W/bare.git" rev-parse --is-bare-repository)" "true"
chk "linked checkout stays non-bare" "$(git -C "$W/bare-linked" rev-parse --is-bare-repository)" "false"
rm -rf "$W"

printf '\n\033[1m### a pull runs cairn sync, from post-merge, once the clone is wired (workspace-7m8.23)\033[0m\n'
P=$(mktemp -d); git -C "$P" init -q origin; git -C "$P/origin" config user.email s@e; git -C "$P/origin" config user.name s
"$SRC/install.sh" "$P/origin" >/dev/null 2>&1
mkdir -p "$P/origin/.cairn"; printf '{"prefix": "s"}\n' > "$P/origin/.cairn/config.json"   # what git carries of a store
git -C "$P/origin" add -A >/dev/null 2>&1; git -C "$P/origin" commit -qm install --no-verify
git clone -q "$P/origin" "$P/b" 2>/dev/null
mkdir -p "$P/bin"; printf '#!/bin/sh\necho "$*" >> "%s/calls"\n' "$P" > "$P/bin/cairn"; chmod +x "$P/bin/cairn"
pull_once() { : > "$P/calls"; echo "$1" >> "$P/origin/f"; git -C "$P/origin" add f; git -C "$P/origin" commit -qm "$1" --no-verify
  PATH="$P/bin:$PATH" git -C "$P/b" pull -q >/dev/null 2>&1; grep -c '^sync$' "$P/calls"; }
# core.hooksPath is per-clone config, not carried by git: until the installer runs in the clone
# (or the session-start hook syncs) nothing catches the store up. Written down, not fixed.
chk "a fresh clone runs no hook until it is wired" "$(pull_once one)" "0"
git -C "$P/b" config core.hooksPath .beads-hooks
chk "wired: the pull runs cairn sync from post-merge" "$(pull_once two)" "1"
rm -rf "$P/b/.cairn"
chk "  …and not where there is no .cairn/" "$(pull_once three)" "0"
rm -rf "$P"

printf '\n\033[1m### a repo whose store is still bd'"'"'s is refused, in every mode, and nothing is written\033[0m\n'
# This release does not read bd. Over a live bd store with no writable cairn store the installer
# must stop before it writes a byte, and point at the README's migration section.
for d in embeddeddolt dolt; do
  R=$(mktemp -d); git -C "$R" init -q; mkdir -p "$R/.beads/$d"
  "$SRC/install.sh" "$R" >"$R/.git/refuse.log" 2>&1; rrc=$?
  chk "live .beads/$d/: installer exits 1"         "$rrc" 1
  grep -q 'REFUSED' "$R/.git/refuse.log" && grep -q 'Moving a repo off bd' "$R/.git/refuse.log" \
    && ok "  …says REFUSED and names the README section" || bad "  …says REFUSED and names the README section"
  chk "  …and wrote nothing"                       "$(ls -A "$R" | grep -vxE '\.git|\.beads' | wc -l | tr -d ' ')" 0
  chk "  …core.hooksPath untouched"                "$(git -C "$R" config core.hooksPath || echo unset)" unset
  for m in --check --dry-run; do
    "$SRC/install.sh" "$m" "$R" >/dev/null 2>&1; chk "  $m refuses too" "$?" 1
  done
  printf 'not a database\n' > "$R/.beads/../.cairn.db.tmp"; mkdir -p "$R/.cairn"; mv -f "$R/.cairn.db.tmp" "$R/.cairn/cairn.db"
  "$SRC/install.sh" "$R" >/dev/null 2>&1
  chk "  a .cairn/cairn.db that is not a writable store does not count" "$?" 1
  rm -rf "$R"
done
if command -v cairn >/dev/null 2>&1; then
  R=$(mktemp -d); git -C "$R" init -q; mkdir -p "$R/.beads/embeddeddolt"
  (cd "$R" && cairn init -p zz -q) >/dev/null 2>&1
  "$SRC/install.sh" "$R" >"$R/.git/after.log" 2>&1
  chk "with a writable cairn store beside it, the install runs" "$?" "$((missing > 0))"
  grep -q "bd's old store is still on disk" "$R/.git/after.log" && ok "  …and says the old store is still on disk" \
    || bad "  …and says the old store is still on disk"
  rm -rf "$R"
else
  echo "  SKIP the install over a migrated store: cairn not on PATH"
fi

printf '\n\033[1m### a repo that had the bd-era pipeline: bd is taken out in place, everything else kept\033[0m\n'
F=$(mktemp -d); F=$(cd "$F" && pwd -P); git -C "$F" init -q
git -C "$F" config user.email t@example.com; git -C "$F" config user.name t
mkdir -p "$F/.beads-hooks" "$F/.claude" "$F/.codex" "$F/.cursor" "$F/tools" "$F/.beads"
BB='# --- BEGIN BEADS INTEGRATION v1.3.0 ---'; BE='# --- END BEADS INTEGRATION v1.3.0 ---'
# A bd-era pre-commit of the pipeline's own shape: a store-cli stanza, a line of the user's, bd's block.
printf '#!/usr/bin/env sh\n# >>> store CLI >>>\nSTORE_CLI=bd\n[ -f .claude/store-cli ] && STORE_CLI=$(cat .claude/store-cli)\n# <<< store CLI <<<\necho user-pre-commit-line\n%s\nbd hooks run pre-commit "$@"\n%s\n' "$BB" "$BE" > "$F/.beads-hooks/pre-commit"
printf '#!/usr/bin/env sh\n%s\nbd hooks run pre-push "$@"\n%s\n' "$BB" "$BE" > "$F/.beads-hooks/pre-push"
printf '#!/usr/bin/env sh\n# bd wrote this hook\n%s\nbd hooks run post-merge "$@"\n%s\n' "$BB" "$BE" > "$F/.beads-hooks/post-merge"
printf '#!/usr/bin/env sh\necho user-pcm-line\n%s\nbd hooks run prepare-commit-msg "$@"\n%s\n' "$BB" "$BE" > "$F/.beads-hooks/prepare-commit-msg"
chmod +x "$F/.beads-hooks/"*
printf '{"hooks": {"SessionStart": [{"hooks": [{"command": "bd codex-hook SessionStart", "type": "command"}, {"command": "echo codex-keep", "type": "command"}], "matcher": "startup"}]}}\n' > "$F/.codex/hooks.json"
printf '{"hooks": {"sessionStart": [{"command": "[ \\"$(tr -d \\" \\" < .claude/store-cli)\\" = cairn ] || bd cursor-hook sessionStart"}, {"command": "echo cursor-keep"}]}, "version": 1}\n' > "$F/.cursor/hooks.json"
printf 'cairn\n' > "$F/.claude/store-cli"; printf '# old\n' > "$F/tools/dolt-guard.sh"
printf '{"_type":"issue","id":"x-1"}\n' > "$F/.beads/issues.jsonl"; git -C "$F" add .beads/issues.jsonl
FH=$(mktemp -d)
printf 'before=1\n# >>> bd dolt-guard >>>\n# Restarts the beads Dolt server after a reboot; nothing else does.\n[ -f "%s/tools/dolt-guard.sh" ] && . "%s/tools/dolt-guard.sh"\n# <<< bd dolt-guard <<<\nafter=1\n' "$F" "$F" > "$FH/.bashrc"
HOME="$FH" "$SRC/install.sh" "$F" >"$F/.git/strip.log" 2>&1
chk "no hook in .beads-hooks/ runs \`bd hooks run\` any more" "$(cat "$F"/.beads-hooks/* | grep -c 'bd hooks run' | tr -d ' ')" 0
chk "no hook in .beads-hooks/ carries a BEGIN BEADS block"   "$(cat "$F"/.beads-hooks/* | grep -c 'BEGIN BEADS' | tr -d ' ')" 0
chk "a hook that held only bd's block is gone"               "$([ -e "$F/.beads-hooks/pre-push" ] && echo there || echo gone)" gone
cmp -s "$SRC/pipeline/.beads-hooks/post-merge" "$F/.beads-hooks/post-merge" \
  && ok "a hook left with only comments is replaced by ours" || bad "a hook left with only comments is replaced by ours"
chk "a hook with a line of the user's keeps it"              "$(grep -c user-pcm-line "$F/.beads-hooks/prepare-commit-msg")" 1
chk "  …and stays executable"                                "$([ -x "$F/.beads-hooks/prepare-commit-msg" ] && echo x || echo no)" x
chk "the bd-era pre-commit keeps the user's line"            "$(grep -c user-pre-commit-line "$F/.beads-hooks/pre-commit")" 1
cmp -s "$SRC/pipeline/.beads-hooks/pre-commit" "$F/.beads-hooks/pre-commit.new" \
  && ok "  …ours is written beside it as .new" || bad "  …ours is written beside it as .new"
grep -q '.beads-hooks/pre-commit is the bd-era version' "$F/.git/strip.log" && ok "  …and it is named as bd-era" \
  || bad "  …and it is named as bd-era"
chk "every changed hook was backed up under the git dir" \
    "$(ls "$F"/.git/beads-agent-pipeline-backup/*/.beads-hooks/ 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" "post-merge pre-commit pre-push prepare-commit-msg "
chk "the codex hook running bd is removed, the other kept"   "$(grep -c 'bd codex-hook' "$F/.codex/hooks.json"):$(grep -c codex-keep "$F/.codex/hooks.json")" "0:1"
chk "the cursor hook running bd (store-cli-guarded) is removed, the other kept" "$(grep -c 'bd cursor-hook' "$F/.cursor/hooks.json"):$(grep -c cursor-keep "$F/.cursor/hooks.json")" "0:1"
chk "  …and both files are still JSON" "$(python3 -c 'import json,sys; [json.load(open(p)) for p in sys.argv[1:]]; print("ok")' "$F/.codex/hooks.json" "$F/.cursor/hooks.json" 2>&1 | tr -d '\r')" ok
chk "the ~/.bashrc block for THIS repo is removed, the rest kept" "$(grep -c 'dolt-guard' "$FH/.bashrc"):$(grep -c '^before=1$\|^after=1$' "$FH/.bashrc")" "0:2"
chk "  …with a backup beside it"                             "$(ls "$FH"/.bashrc.bak.* 2>/dev/null | wc -l | tr -d ' ')" 1
# While the bd-era pre-commit is the live copy, removing .claude/store-cli would turn bd back on:
# the git rm must not be printed, and the order (adopt the .new first) must be.
chk "no git rm of .claude/store-cli while a bd-era hook is kept" "$(grep -c 'git rm -q -- .claude/store-cli' "$F/.git/strip.log" | tr -d ' ')" 0
grep -q 'FIRST adopt the .new' "$F/.git/strip.log" && ok "  …it says to adopt the .new files first" || bad "  …it says to adopt the .new files first"
chk "  …and nothing is deleted"                              "$(ls "$F/.claude/store-cli" "$F/tools/dolt-guard.sh" 2>/dev/null | wc -l | tr -d ' ')" 2
grep -q "the old tracker's exports are still in .beads/ (.beads/issues.jsonl)" "$F/.git/strip.log" && ok "the old tracker's tracked export in .beads/ is named" \
  || bad "the old tracker's tracked export in .beads/ is named"
mv -f "$F/.beads-hooks/pre-commit.new" "$F/.beads-hooks/pre-commit"     # adopt ours
HOME="$FH" "$SRC/install.sh" "$F" >"$F/.git/strip2.log" 2>&1
grep -q 'git rm -q -- .claude/store-cli tools/dolt-guard.sh' "$F/.git/strip2.log" && ok "once the .new is adopted, the bd-era files are named with the git rm" \
  || bad "once the .new is adopted, the bd-era files are named with the git rm"
grep -q "nothing of bd's found\|bd-era files this release no longer ships" "$F/.git/strip2.log" && ok "a second run finds no bd block or harness hook to remove" \
  || bad "a second run finds no bd block or harness hook to remove"
chk "  …and changes no hook" "$(grep -c "managed block removed\|held only bd's block\|removed a harness hook" "$F/.git/strip2.log" | tr -d ' ')" 0
printf '# >>> bd dolt-guard >>>\n[ -f "/elsewhere/tools/dolt-guard.sh" ] && . "/elsewhere/tools/dolt-guard.sh"\n# <<< bd dolt-guard <<<\n' > "$FH/.bashrc"
HOME="$FH" "$SRC/install.sh" "$F" >"$F/.git/strip3.log" 2>&1
chk "another repo's ~/.bashrc block is left alone" "$(grep -c 'elsewhere' "$FH/.bashrc"):$(grep -c 'block for ANOTHER repo' "$F/.git/strip3.log")" "1:1"
"$SRC/install.sh" --no-shell "$F" >"$F/.git/noshell.log" 2>&1
grep -q 'note: --no-shell does nothing' "$F/.git/noshell.log" && ok "--no-shell is accepted, with a note" || bad "--no-shell is accepted, with a note"
rm -rf "$F" "$FH"

printf '\n\033[1m### the review cases: worktrees, python3, JSON it cannot read, unpaired markers, dry runs\033[0m\n'
# A linked worktree has no .beads/ of its own: its main checkout's live bd store must refuse it.
M=$(mktemp -d); M=$(cd "$M" && pwd -P); git -C "$M" init -q main; MM=$M/main
git -C "$MM" config user.email t@example.com; git -C "$MM" config user.name t
git -C "$MM" commit -q --allow-empty -m base; mkdir -p "$MM/.beads/embeddeddolt"
git -C "$MM" worktree add -q "$M/side" -b side 2>/dev/null
"$SRC/install.sh" "$M/side" >"$M/wt.log" 2>&1; wrc=$?
chk "a worktree of a checkout whose store is still bd's is refused" "$wrc" 1
grep -q "REFUSED.*the main checkout's" "$M/wt.log" && ok "  …naming the main checkout's store" || bad "  …naming the main checkout's store"
chk "  …and nothing is written in the worktree" "$(ls -A "$M/side" | grep -vx '\.git' | wc -l | tr -d ' ')" 0
rm -rf "$M"
# After the move, a worktree installed on its own gets its redirect BEFORE anything runs cairn sync
# there (the install's verify step runs the prime hook, which syncs).
if command -v cairn >/dev/null 2>&1; then
  M=$(mktemp -d); M=$(cd "$M" && pwd -P); git -C "$M" init -q main; MM=$M/main
  git -C "$MM" config user.email t@example.com; git -C "$MM" config user.name t
  (cd "$MM" && cairn init -p zz -q) >/dev/null 2>&1
  git -C "$MM" add .cairn/.gitignore .cairn/config.json && git -C "$MM" commit -qm store --no-verify
  git -C "$MM" worktree add -q "$M/side" -b side 2>/dev/null
  "$SRC/install.sh" "$M/side" >"$M/wt2.log" 2>&1
  chk "a worktree install after the move writes its redirect to the main store" "$(cat "$M/side/.cairn/redirect" 2>/dev/null)" "$MM/.cairn"
  chk "  …and no database of its own was built" "$([ -e "$M/side/.cairn/cairn.db" ] && echo stray || echo none)" none
  # A worktree that already built a store of its own (a plain worktree add whose post-checkout
  # cairn sync ran before any redirect) is refused, not kept as a second store.
  git -C "$MM" worktree add -q "$M/stray" -b stray 2>/dev/null
  (cd "$M/stray" && cairn init -p zz -q) >/dev/null 2>&1
  "$SRC/install.sh" "$M/stray" >"$M/wt3.log" 2>&1; wrc=$?
  chk "a worktree with a writable store of its own beside the main checkout's is refused" "$wrc" 1
  grep -q "has a cairn store of its own" "$M/wt3.log" && ok "  …saying it is a second store" || bad "  …saying it is a second store"
  chk "  …and no redirect is written over it" "$([ -f "$M/stray/.cairn/redirect" ] && echo written || echo none)" none
  # A database there that is NOT writable (a shadow) does not hide the main checkout's store.
  git -C "$MM" worktree add -q "$M/shadow" -b shadow 2>/dev/null
  mkdir -p "$M/shadow/.cairn"
  python3 -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE meta(key TEXT, value TEXT)"); c.execute("INSERT INTO meta VALUES (?, ?)", ("writable", "0")); c.commit()' "$M/shadow/.cairn/cairn.db"
  mkdir -p "$MM/.beads/embeddeddolt"           # the old Dolt store the move leaves until the manifest is read
  "$SRC/install.sh" "$M/shadow" >"$M/wt4.log" 2>&1; wrc=$?
  chk "a shadow database in a worktree does not hide the main checkout's store (installs)" "$wrc" 0
  chk "  …and the worktree gets its redirect" "$(cat "$M/shadow/.cairn/redirect" 2>/dev/null)" "$MM/.cairn"
  rm -rf "$M"
else
  echo "  SKIP the worktree install after the move: cairn not on PATH"
fi
# python3 is required: without it, any file named cairn.db would pass for a writable store.
R=$(mktemp -d); git -C "$R" init -q; mkdir -p "$R/.cairn"; printf 'x\n' > "$R/.cairn/cairn.db"
NP=$(mktemp -d)
for tool in git dirname sed head tail cat tr mktemp rm awk grep cmp date ls cp mkdir chmod find sort wc env basename uname; do
  b=$(command -v "$tool" 2>/dev/null) && printf '#!/bin/sh\nexec "%s" "$@"\n' "$b" > "$NP/$tool" && chmod +x "$NP/$tool"
done
PATH="$NP" "$(command -v bash)" "$SRC/install.sh" "$R" >"$NP/.log" 2>&1; prc=$?
chk "no python3: refused" "$prc" 1
grep -q 'REFUSED: python3 is required' "$NP/.log" && ok "  …and says why" || bad "  …and says why"
chk "  …and nothing is written" "$(ls -A "$R" | grep -vxE '\.git|\.cairn' | wc -l | tr -d ' ')" 0
rm -rf "$R" "$NP"
# Harness files: one that does not parse but names a bd command is a LOUD problem, untouched; the
# real guarded form 0.1's tools/store-cli-harness-hooks.sh wrote is recognised and removed.
J=$(mktemp -d); git -C "$J" init -q; mkdir -p "$J/.claude" "$J/.codex"
printf '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "bd prime --hook-json"}]}]},,}\n' > "$J/.claude/settings.json"
python3 - "$J/.codex/hooks.json" <<'PY'
import json, sys
# GUARD, verbatim from 0.1's tools/store-cli-harness-hooks.sh (main, lines 27-28)
GUARD = ('[ "$(tr -d \' \\t\\r\\n\' 2>/dev/null < "${CLAUDE_PROJECT_DIR:-$(git rev-parse '
         '--show-toplevel 2>/dev/null || pwd)}/.claude/store-cli")" = cairn ] || ')
json.dump({"hooks": {"SessionStart": [{"matcher": "", "hooks": [
    {"type": "command", "command": GUARD + "bd codex-hook SessionStart"},
    {"type": "command", "command": "echo codex-keep"}]}]}}, open(sys.argv[1], "w"), indent=2)
PY
before=$(cksum < "$J/.claude/settings.json")
"$SRC/install.sh" "$J" >"$J/.git/json.log" 2>&1; jrc=$?
chk "an unparseable settings.json naming bd: exit 1" "$jrc" 1
grep -q '.claude/settings.json is not valid JSON.*bd STILL RUNS from it' "$J/.git/json.log" && ok "  …loud: bd still runs from it, remove by hand" \
  || bad "  …loud: bd still runs from it, remove by hand"
chk "  …and the file is untouched" "$(cksum < "$J/.claude/settings.json")" "$before"
chk "the 0.1 guarded form of a bd hook is removed, the other kept" "$(grep -c 'codex-hook' "$J/.codex/hooks.json"):$(grep -c codex-keep "$J/.codex/hooks.json")" "0:1"
rm -rf "$J"
# Unpaired markers: a BEGIN with no END would make the range delete to the end of the file.
U=$(mktemp -d); U=$(cd "$U" && pwd -P); git -C "$U" init -q; mkdir -p "$U/.beads-hooks"; UH=$(mktemp -d)
printf '#!/bin/sh\necho mine\n# --- BEGIN BEADS INTEGRATION v1.3.0 ---\nbd hooks run pre-push "$@"\necho also-mine\n' > "$U/.beads-hooks/pre-push"
printf 'a=1\n# >>> bd dolt-guard >>>\n[ -f "%s/tools/dolt-guard.sh" ] && . "%s/tools/dolt-guard.sh"\nkeep=1\n' "$U" "$U" > "$UH/.bashrc"
bh=$(cksum < "$U/.beads-hooks/pre-push"); br=$(cksum < "$UH/.bashrc")
HOME="$UH" "$SRC/install.sh" "$U" >"$U/.git/unpaired.log" 2>&1
chk "a hook with BEGIN and no END is untouched" "$(cksum < "$U/.beads-hooks/pre-push")" "$bh"
grep -q '.beads-hooks/pre-push has bd.s BEGIN/END BEADS INTEGRATION markers out of pairs' "$U/.git/unpaired.log" && ok "  …and named" || bad "  …and named"
chk "a ~/.bashrc with an unclosed dolt-guard block is untouched" "$(cksum < "$UH/.bashrc")" "$br"
grep -q 'dolt-guard markers out of pairs' "$U/.git/unpaired.log" && ok "  …and named" || bad "  …and named"
rm -rf "$U" "$UH"
# --dry-run and --check on a bd-era tree change no file, the git dir and ~/.bashrc included.
D=$(mktemp -d); D=$(cd "$D" && pwd -P); git -C "$D" init -q; DH=$(mktemp -d)
mkdir -p "$D/.beads-hooks" "$D/.claude" "$D/.cursor" "$D/tools"
printf '#!/bin/sh\necho mine\n# --- BEGIN BEADS INTEGRATION v1.3.0 ---\nbd hooks run pre-commit "$@"\n# --- END BEADS INTEGRATION v1.3.0 ---\n' > "$D/.beads-hooks/pre-commit"
printf '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "bd prime --hook-json"}]}]}}\n' > "$D/.claude/settings.json"
printf '{"hooks": {"sessionStart": [{"command": "bd cursor-hook sessionStart"}]}, "version": 1}\n' > "$D/.cursor/hooks.json"
printf 'cairn\n' > "$D/.claude/store-cli"; printf '# old\n' > "$D/tools/dolt-guard.sh"
printf '# >>> bd dolt-guard >>>\n[ -f "%s/tools/dolt-guard.sh" ] && . "%s/tools/dolt-guard.sh"\n# <<< bd dolt-guard <<<\n' "$D" "$D" > "$DH/.bashrc"
tree_sum() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done) | cksum; }
t0=$(tree_sum "$D"); r0=$(cksum < "$DH/.bashrc")
for m in --dry-run --check; do
  HOME="$DH" "$SRC/install.sh" "$m" "$D" >/dev/null 2>&1
  chk "$m on a bd-era tree changes no file (tree, git dir)" "$(tree_sum "$D")" "$t0"
  chk "$m leaves ~/.bashrc as it was" "$(cksum < "$DH/.bashrc")" "$r0"
done
rm -rf "$D" "$DH"

printf '\n\033[1m### sibling worktrees of a store get the redirect that shares it\033[0m\n'
if command -v cairn >/dev/null 2>&1; then
  M=$(mktemp -d); M=$(cd "$M" && pwd -P); git -C "$M" init -q main; M=$M/main
  git -C "$M" config user.email t@example.com; git -C "$M" config user.name t
  (cd "$M" && cairn init -p zz -q) >/dev/null 2>&1
  git -C "$M" add .cairn/.gitignore .cairn/config.json && git -C "$M" commit -qm store --no-verify
  git -C "$M" worktree add -q "$M.side" -b side 2>/dev/null
  "$SRC/install.sh" "$M" >"$M/.git/wt.log" 2>&1
  chk "the sibling's .cairn/redirect names the main store" "$(cat "$M.side/.cairn/redirect" 2>/dev/null)" "$M/.cairn"
  chk "  …and the sibling got no database of its own"       "$([ -e "$M.side/.cairn/cairn.db" ] && echo stray || echo none)" none
  "$SRC/install.sh" "$M" >"$M/.git/wt2.log" 2>&1
  grep -q "worktree $M.side shares this store" "$M/.git/wt2.log" && ok "  …a re-run says it is shared and writes nothing" \
    || bad "  …a re-run says it is shared and writes nothing"
  rm -rf "$(dirname "$M")" "$M.side"
else
  echo "  SKIP the worktree redirect: cairn not on PATH"
fi

printf '\n\033[1m### --dry-run and --check touch nothing\033[0m\n'
D=$(mktemp -d); git -C "$D" init -q
"$SRC/install.sh" --dry-run "$D" >/dev/null 2>&1
chk "dry-run wrote no files" "$(ls -A "$D" | grep -v '^\.git$' | wc -l | tr -d ' ')" "0"
"$SRC/install.sh" --check "$D" >/dev/null 2>&1
chk "check wrote no files" "$(ls -A "$D" | grep -v '^\.git$' | wc -l | tr -d ' ')" "0"
rm -rf "$D"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
