#!/usr/bin/env bash
# install.sh — install the beads agent pipeline into a git repo.
#
#     ./install.sh [TARGET_REPO]        # default: the current directory
#     ./install.sh --check [TARGET]     # preflight only, changes nothing
#     ./install.sh --dry-run [TARGET]   # print every action, change nothing
#     ./install.sh --no-shell [TARGET]  # skip the one thing written outside the repo
#     ./install.sh --with-peer [TARGET] # also install the concurrent-session layer (see below)
#
# THE PEER LAYER IS OPT-IN because it is environment-dependent. It is only worth anything if more
# than one agent session may run against the repo at once; for a single-session user it is dead
# weight in a session payload that hosts already truncate. Without --with-peer, the concurrency
# doc is not installed and the matching section is stripped out of AGENTS.md, so nothing cites a
# file that is not there. Re-run with the flag to add it later.
#
# One piece of concurrency machinery ships either way: the flock in tools/dolt-guard.sh, which
# stops two shells racing to start the Dolt server. It costs a single-session user nothing.
#
# IDEMPOTENT. Re-running is also how you repair a checkout whose config drifted: it reports
# what it changed and what was already right.
#
# IT NEVER OVERWRITES YOUR CONTENT. An existing AGENTS.md, settings.json or tools/ file that
# differs from ours is left in place and the new version is written beside it as `.new`, with
# a line telling you. The one exception is a file this installer wrote earlier and you have
# not edited, which is updated in place.
#
# WHAT IT TOUCHES OUTSIDE THE REPO: exactly one marker-managed block in ~/.bashrc that sources
# tools/dolt-guard.sh. Without it, a reboot leaves the bd Dolt server dead and `bd` writes
# silently fail to land while reads still look fine. Skip it with --no-shell.

set -uo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PAYLOAD="$SRC/pipeline"

MODE=install; DO_SHELL=1; WITH_PEER=0; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check)    MODE=check ;;
    --dry-run)  MODE=dryrun ;;
    --no-shell) DO_SHELL=0 ;;
    --with-peer) WITH_PEER=1 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)          TARGET=$1 ;;
  esac
  shift
done
TARGET=${TARGET:-$PWD}

changed=0; problems=0
say()  { printf '  %s\n' "$1"; }
did()  { printf '  \033[32m+\033[0m %s\n' "$1"; changed=$((changed+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; problems=$((problems+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
run()  { if [ "$MODE" = dryrun ]; then printf '  \033[36m[dry-run]\033[0m %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- preflight --
hdr "dependencies"
need() { # need <cmd> <why> <how>
  if command -v "$1" >/dev/null 2>&1; then say "$1 — $(command -v "$1")"; return 0; fi
  warn "$1 MISSING — $2"; say "    install: $3"; return 1
}
need git    "everything here is git-scoped"            "your package manager" || true
need bd     "the issue tracker and memory store"       "https://github.com/gastownhall/beads" || true
need dolt   "bd's storage engine"                      "https://github.com/dolthub/dolt" || true
need python3 "the PreToolUse guard parses hook JSON"   "your package manager" || true

# Optional, and genuinely optional: the pipeline degrades in a defined way without each.
opt() { if command -v "$1" >/dev/null 2>&1; then say "$1 — present"; else say "$1 — absent ($2)"; fi; }
opt jq          "session-start falls back to the full bd prime dump"
opt rg          "only affects sweep_test.sh's demonstration of the bug"
opt iconv       "sweep.sh cannot flag bad-UTF-8 files as unsearchable"
opt bd-memgraph "no memory-graph guard — the pre-commit stanza self-skips"
command -v bd-memgraph >/dev/null 2>&1 || {
  say "    add it:  git clone https://github.com/scgoetsch/bd-memgraph"
  say "             ln -sf \"\$PWD/bd-memgraph/bd-memgraph.py\" ~/.local/bin/bd-memgraph"; }

# THE HARNESS IS A DEPENDENCY, AND IT IS NOT A BINARY TO PROBE FOR. The three session hooks are
# run BY the harness; this installer is normally invoked from a plain shell, so the presence or
# absence of a `claude` CLI proves nothing about whether those hooks will fire. State it rather
# than detect it. An undetectable dependency left unstated is exactly how someone satisfies every
# listed requirement, installs cleanly, and still gets no session machinery -- silently, which is
# the failure mode this whole pipeline is built against.
hdr "agent harness"
if command -v claude >/dev/null 2>&1; then
  say "claude CLI — $(command -v claude)"
else
  say "claude CLI — not on PATH (not conclusive; what matters is the harness that runs the hooks)"
fi
say "The THREE SESSION HOOKS (.claude/settings.json) fire in Claude Code and NOWHERE ELSE."
say "  Under agy, a Grok REPL, Cursor or a plain shell they do nothing and nothing reports it."
say "  Everything else installed here works anywhere: the git-layer guards in .beads-hooks/,"
say "  every tool in tools/, the shell guard, and AGENTS.md itself."
say "  Full matrix of what fires where: docs/ops/other-harnesses.md"

[ -d "$PAYLOAD" ] || { warn "payload missing: $PAYLOAD"; exit 1; }

hdr "target"
if [ ! -d "$TARGET" ]; then warn "no such directory: $TARGET"; exit 1; fi
TARGET=$(cd "$TARGET" && pwd -P)
say "$TARGET"
if [ ! -d "$TARGET/.git" ]; then
  warn "not a git repository — the hooks, the guards and bd all assume one."
  say "    fix: git -C \"$TARGET\" init"
  [ "$MODE" = check ] || exit 1
fi
if [ "$TARGET" = "$SRC" ]; then
  warn "refusing to install into the pipeline repo itself — pass a target directory."
  exit 1
fi

if [ "$MODE" = check ]; then
  if [ -d "$TARGET/.git" ]; then
    hp=$(git -C "$TARGET" config core.hooksPath 2>/dev/null || true)
    if [ "$hp" = ".beads-hooks" ]; then say "core.hooksPath=.beads-hooks — the shared pre-commit is wired"
    else say "core.hooksPath=${hp:-unset} — the shared pre-commit is NOT wired; install will set it"; fi
  fi
  hdr "check only"
  say "no changes made. Re-run without --check to install."
  exit $(( problems > 0 ))
fi

# ------------------------------------------------------------------- files --
# Copy a payload file. Never clobbers content the user may have edited: identical is a no-op,
# different lands as `<file>.new` unless we are the only author it has ever had.
install_file() { # install_file <relpath> [mode]
  local rel=$1 mode=${2:-} src="$PAYLOAD/$1" dst="$TARGET/$1"
  [ -f "$src" ] || { warn "payload file missing: $rel"; return 1; }
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then say "$rel (already current)"; return 0; fi
    run cp -f "$src" "$dst.new"
    warn "$rel DIFFERS — yours kept, ours written to $rel.new"
    say "    compare: diff \"$dst\" \"$dst.new\""
    return 0
  fi
  run mkdir -p "$(dirname "$dst")"
  run cp -f "$src" "$dst"
  [ -n "$mode" ] && run chmod "$mode" "$dst"
  did "$rel"
}

hdr "session machinery (.claude/)"
for f in bd-prime-hook.sh bd-prerun-hook.sh bd-stop-hook.sh; do install_file ".claude/$f" 755; done
install_file ".claude/memory-hot.txt"

# settings.json is the one file a user is LIKELY to already have, and clobbering it would take
# their unrelated hooks with it. Merge when we can, and say so plainly when we cannot.
SET="$TARGET/.claude/settings.json"
if [ ! -e "$SET" ]; then
  install_file ".claude/settings.json"
elif cmp -s "$PAYLOAD/.claude/settings.json" "$SET"; then
  say ".claude/settings.json (already current)"
elif command -v jq >/dev/null 2>&1; then
  merged=$(jq -s '.[0] * .[1]' "$SET" "$PAYLOAD/.claude/settings.json" 2>/dev/null)
  if [ -n "$merged" ] && [ "$merged" != "null" ]; then
    if [ "$(printf '%s' "$merged" | jq -S .)" = "$(jq -S . "$SET" 2>/dev/null)" ]; then
      say ".claude/settings.json (hooks already present)"
    else
      run cp -f "$SET" "$SET.bak.$(date +%s)"
      if [ "$MODE" = dryrun ]; then printf '  \033[36m[dry-run]\033[0m merge hooks into %s\n' "$SET"
      else printf '%s\n' "$merged" > "$SET"; fi
      did ".claude/settings.json — merged our hooks in (backup kept)"
      warn "our 'hooks' block REPLACED any same-named block of yours. Check the backup if you had one."
    fi
  else
    run cp -f "$PAYLOAD/.claude/settings.json" "$SET.new"
    warn ".claude/settings.json — could not merge; ours written to settings.json.new"
  fi
else
  run cp -f "$PAYLOAD/.claude/settings.json" "$SET.new"
  warn ".claude/settings.json exists and jq is absent — ours written to settings.json.new"
  say "    merge the \"hooks\" block by hand, or install jq and re-run."
fi

hdr "skills (.claude/skills/)"
# The WHOLE tree, not a per-skill loop: the loop shipped the two skill directories and silently
# missed .claude/skills/README.md sitting beside them, while AGENTS.md cited it. Enumerate the
# directory, do not enumerate a list of names you have to remember to update.
while IFS= read -r rel; do install_file "$rel"; done < <(cd "$PAYLOAD" && find .claude/skills -type f | sort)

hdr "site checks (.claude/site-checks/)"
while IFS= read -r rel; do install_file "$rel"; done < <(cd "$PAYLOAD" && find .claude/site-checks -type f)

hdr "tools (tools/)"
while IFS= read -r rel; do install_file "$rel" 755; done < <(cd "$PAYLOAD" && find tools -type f | sort)

hdr "docs (docs/ops/)"
PEER_DOC="docs/ops/concurrent-sessions.md"
while IFS= read -r rel; do
  if [ "$rel" = "$PEER_DOC" ] && [ "$WITH_PEER" -eq 0 ]; then
    say "$PEER_DOC — skipped (peer layer is opt-in; re-run with --with-peer)"
    continue
  fi
  install_file "$rel"
done < <(cd "$PAYLOAD" && find docs -type f | sort)

hdr "repo guards (.beads-hooks/)"
install_file ".beads-hooks/pre-commit" 755

# ------------------------------------------------------------- agent docs --
hdr "agent docs (AGENTS.md + CLAUDE.md)"
# Render the template for this install: with --with-peer the concurrency section stays (markers
# removed); without it the whole block goes, so AGENTS.md never cites a doc we did not install.
AGENTS_RENDERED="${TMPDIR:-/tmp}/bap-agents.$$"
if [ "$WITH_PEER" -eq 1 ]; then
  sed '/<!-- peer:begin -->/d; /<!-- peer:end -->/d' "$PAYLOAD/AGENTS.md" > "$AGENTS_RENDERED"
else
  # squeeze the blank-line run the removal leaves behind, so the seam is invisible
  sed '/<!-- peer:begin -->/,/<!-- peer:end -->/d' "$PAYLOAD/AGENTS.md" \
    | awk 'BEGIN{b=0} /^$/{b++; if(b>1) next} !/^$/{b=0} {print}' > "$AGENTS_RENDERED"
fi
trap 'rm -f "$AGENTS_RENDERED"' EXIT
if [ -e "$TARGET/AGENTS.md" ]; then
  if cmp -s "$AGENTS_RENDERED" "$TARGET/AGENTS.md"; then say "AGENTS.md (already current)"
  else
    run cp -f "$AGENTS_RENDERED" "$TARGET/AGENTS.md.new"
    say "AGENTS.md exists — yours kept. Ours is at AGENTS.md.new; merge what you want."
  fi
else
  run cp -f "$AGENTS_RENDERED" "$TARGET/AGENTS.md"
  did "AGENTS.md (template — edit it, it is meant to be yours)"
fi

if [ -L "$TARGET/CLAUDE.md" ] && [ "$(readlink "$TARGET/CLAUDE.md")" = "AGENTS.md" ]; then
  say "CLAUDE.md -> AGENTS.md (already linked)"
elif [ -e "$TARGET/CLAUDE.md" ] && [ ! -L "$TARGET/CLAUDE.md" ]; then
  # Never silently discard a regular file: it may hold edits AGENTS.md does not.
  warn "CLAUDE.md is a REGULAR FILE, not a symlink. Not touching it."
  say "    reconcile:  diff \"$TARGET/CLAUDE.md\" \"$TARGET/AGENTS.md\""
  say "    then:       rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md"
elif [ ! -e "$TARGET/CLAUDE.md" ]; then
  # `ln -s && did` alone would SAY NOTHING when ln fails, which it does on filesystems without
  # symlink support (Windows without Developer Mode, some network and container mounts). The
  # component whose job is to create the link is the worst place to fail quietly.
  if [ "$MODE" = dryrun ]; then printf '  \033[36m[dry-run]\033[0m ln -s AGENTS.md CLAUDE.md\n'
  elif ln -s AGENTS.md "$TARGET/CLAUDE.md" 2>/dev/null; then did "CLAUDE.md -> AGENTS.md"
  else
    warn "could not create the CLAUDE.md symlink — this filesystem may not support symlinks."
    say "    on Windows, try:  git config --global core.symlinks true  (needs Developer Mode)"
    say "    otherwise see docs/ops/agent-docs-symlink.md for the fallback"
  fi
fi

# --------------------------------------------------------------- git hooks --
# Wired whether or not bd is present. Two of the pre-commit's stanzas (agent-cache paths,
# agent-docs symlink) need no bd and are the whole point on a box without one; the two that do
# need it self-skip. This used to sit inside the bd branch below, so a box without bd got the
# hook file copied and reported with a green +, and nothing said that wiring it had been skipped
# -- the git layer guarded nothing. Instance 12 in docs/ops/checks-narrower-than-what-they-check.md.
hdr "git hooks"
if [ -d "$TARGET/.git" ]; then
  cur=$(git -C "$TARGET" config core.hooksPath 2>/dev/null || true)
  if [ "$cur" = ".beads-hooks" ]; then say "core.hooksPath already .beads-hooks"
  else run git -C "$TARGET" config core.hooksPath .beads-hooks && did "set core.hooksPath=.beads-hooks (was ${cur:-unset})"; fi
  stale=$(ls "$TARGET/.git/hooks" 2>/dev/null | grep -vc '\.sample$' || true)
  [ "${stale:-0}" -gt 0 ] && warn "$stale stale hook(s) in .git/hooks — git ignores them now; delete them so nobody mistakes them for live."
fi

# ------------------------------------------------------------------- beads --
hdr "bd store"
if command -v bd >/dev/null 2>&1; then
  if [ -d "$TARGET/.beads" ]; then
    say ".beads/ present"
  else
    say "no .beads/ yet — initialise it yourself so the prefix is your choice:"
    say "    cd \"$TARGET\" && bd init --prefix <XX>"
  fi
  say "bd's own hooks: run  bd hooks install --shared  in the target (note --shared)"
else
  say "bd absent (reported under dependencies) — store setup skipped; the git hooks above are wired regardless"
fi

# -------------------------------------------------------------------- shell --
hdr "shell guard (~/.bashrc)"
GUARD_SRC="$TARGET/tools/dolt-guard.sh"
GB='# >>> bd dolt-guard >>>'; GE='# <<< bd dolt-guard <<<'; RC="$HOME/.bashrc"
if [ "$DO_SHELL" -eq 0 ]; then
  say "skipped (--no-shell). Without it, a reboot leaves the Dolt server dead and bd writes"
  say "  silently fail to land while reads still look fine. Source it yourself: . $GUARD_SRC"
elif [ -z "${HOME:-}" ]; then warn "HOME unset — skipping"
elif [ ! -f "$GUARD_SRC" ] && [ "$MODE" != dryrun ]; then warn "tools/dolt-guard.sh not installed — skipping"
else
  BLOCK="$GB
# Restarts the beads Dolt server after a reboot; nothing else does.
# Managed by beads-agent-pipeline's install.sh — edit tools/dolt-guard.sh, not here.
[ -f \"$GUARD_SRC\" ] && . \"$GUARD_SRC\"
$GE"
  if [ "$MODE" = dryrun ]; then printf '  \033[36m[dry-run]\033[0m add the dolt-guard block to %s\n' "$RC"
  else
    [ -f "$RC" ] || : > "$RC"
    esc() { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }
    cur_block=$(sed -n "/^$(esc "$GB")\$/,/^$(esc "$GE")\$/p" "$RC" 2>/dev/null)
    if [ "$cur_block" = "$BLOCK" ]; then say "dolt-guard already current in $RC"
    else
      cp "$RC" "$RC.bak.$(date +%s)" && say "backed up $RC"
      [ -n "$cur_block" ] && sed -i "/^$(esc "$GB")\$/,/^$(esc "$GE")\$/d" "$RC"
      printf '\n%s\n' "$BLOCK" >> "$RC"
      did "dolt-guard installed in $RC — open a new shell, or: . $GUARD_SRC"
    fi
  fi
fi

# ------------------------------------------------------------------ verify --
hdr "verify"
# Which guards are actually in the shared pre-commit. The hook file ships with four stanzas:
# bd's own marker-managed block, the memory-graph guard, the agent-cache path guard and the
# agent-docs guard. `bd hooks
# install --shared` rewrites only the region between ITS markers, so the other two should
# survive -- but a clone missing a stanza is otherwise SILENTLY unguarded, which is the exact
# failure this pipeline exists to prevent. Report presence per guard rather than assuming it.
HK="$TARGET/.beads-hooks/pre-commit"
if [ -f "$HK" ] && [ "$MODE" != dryrun ]; then
  for marker in "BEADS INTEGRATION:bd's own hooks" \
                "bd-memgraph check:memory-graph guard" \
                "agent-cache path guard:agent-cache path guard" \
                "agent-docs symlink guard:agent-docs guard"; do
    pat=${marker%%:*}; name=${marker#*:}
    if grep -q "$pat" "$HK" 2>/dev/null; then say "$name present in .beads-hooks/pre-commit"
    else warn "$name MISSING from .beads-hooks/pre-commit — re-run this installer"; fi
  done
  # Presence in the file is a textual claim. Whether git RUNS the file is core.hooksPath, and
  # that was the piece this installer used to skip without saying so. Assert the wiring too.
  hp=$(git -C "$TARGET" config core.hooksPath 2>/dev/null || true)
  if [ "$hp" = ".beads-hooks" ]; then say "core.hooksPath=.beads-hooks — git runs that file"
  else warn "core.hooksPath is '${hp:-unset}', not .beads-hooks — every stanza above is present and NONE of them fires"; fi
fi
if [ "$MODE" = dryrun ]; then
  say "dry run — nothing was changed, so nothing to verify."
else
  if [ -x "$TARGET/tools/check-agent-docs-linked.sh" ]; then
    if (cd "$TARGET" && tools/check-agent-docs-linked.sh >/dev/null 2>&1); then say "agent-docs symlink guard passes"
    else warn "agent-docs symlink guard FAILS — run tools/check-agent-docs-linked.sh in the target"; fi
  fi
  if [ -x "$TARGET/tools/hook_portability_test.sh" ]; then
    if (cd "$TARGET" && tools/hook_portability_test.sh >/dev/null 2>&1); then say "hook portability suite passes"
    else warn "hook portability suite FAILS — run tools/hook_portability_test.sh in the target"; fi
  fi
fi

hdr "result"
[ "$changed" -eq 0 ] && say "nothing to do — this checkout was already set up." || say "$changed change(s) applied."
if [ "$problems" -gt 0 ]; then say "$problems item(s) need your attention (marked ! above)."; fi
cat <<NEXT

Next:
  cd "$TARGET"
  bd init --prefix <XX>        # if you have no .beads/ yet
  bd hooks install --shared    # --shared matters: without it git ignores them
  tools/agent_docs_test.sh     # and the rest of the suite in AGENTS.md
Then open AGENTS.md and make it yours.
The concurrent-session layer is $( [ "$WITH_PEER" -eq 1 ] && echo INSTALLED || echo "NOT installed — add it with --with-peer if more than one session will run against this repo" ).
NEXT
exit $(( problems > 0 ))
