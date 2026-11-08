#!/usr/bin/env bash
# install.sh — install the beads agent pipeline into a git repo.
#
#     ./install.sh [TARGET_REPO]        # default: the current directory
#     ./install.sh --check [TARGET]     # preflight only, changes nothing
#     ./install.sh --dry-run [TARGET]   # print every action, change nothing
#     ./install.sh --with-concurrent [TARGET]  # also install the concurrent-sessions layer (see below)
#     ./install.sh --with-pi [TARGET]   # also install project-local Pi session hooks (requires trust)
#
# THE STORE IS CAIRN (https://github.com/scgoetsch/cairn), 0.7.0 or later, and nothing else. This
# release does not read bd. It REFUSES a target that still has a live bd store (.beads/ holding
# embeddeddolt/ or dolt/) and no writable cairn store: move the store first (README, "Moving a repo
# off bd"), then install. A green install is not a migrated store.
#
# THE CONCURRENT-SESSIONS LAYER IS OPT-IN because it is environment-dependent. It is only worth
# anything if more than one agent session may run against the repo at once; for a single-session
# user it is dead weight in a session payload that hosts already truncate. Without
# --with-concurrent, the concurrency doc is not installed and the matching section is stripped out
# of AGENTS.md, so nothing cites a file that is not there. Re-run with the flag to add it later.
# The flag was --with-peer until 2026-10-11; that spelling is still accepted, with a note, because
# "peer" collided with foreign-lab peer-review tooling that can sit beside this pipeline in the
# same agent session (one word, two meanings, one context window).
#
# IDEMPOTENT. Re-running is also how you repair a checkout whose config drifted: it reports
# what it changed and what was already right.
#
# IT NEVER OVERWRITES YOUR CONTENT. An existing tools/ or docs/ file that differs from ours is left
# in place and ours is written beside it as `.new`, with a line telling you; adopting it is a
# manual `mv` (there is no upgrade path yet). An existing .claude/settings.json is MERGED: the
# user hooks survive even on shared events. Identical pipeline groups are deduplicated and a
# backup is kept. An existing AGENTS.md is kept and nothing is written beside it -- it is meant to
# diverge.
#
# THE ONE EXCEPTION IS bd, IN A REPO THAT HAD IT. bd's managed blocks (`BEGIN/END BEADS
# INTEGRATION`) are removed IN PLACE from every hook in .beads-hooks/, and hooks that run bd are
# removed from .claude/settings.json, .claude/settings.local.json, .codex/hooks.json and
# .cursor/hooks.json; a backup of each file is kept beside it. A `.new` beside a hook that still
# runs bd would leave bd running on every commit. A hook file left with nothing but comments is
# replaced by ours. A pipeline file from the bd era that you edited is kept, ours lands as .new,
# and the installer says it still runs bd.
#
# NOTHING OUTSIDE THE REPO IS WRITTEN, except to take out what the bd-era installer put there: its
# `# >>> bd dolt-guard >>>` block in ~/.bashrc, when that block sources THIS repo's
# tools/dolt-guard.sh (backup kept). --no-shell is accepted and does nothing (the block is gone).

set -uo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PAYLOAD="$SRC/pipeline"

MODE=install; WITH_CONCURRENT=0; WITH_PI=0; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check)    MODE=check ;;
    --dry-run)  MODE=dryrun ;;
    --no-shell) echo "note: --no-shell does nothing since 0.2.0 (the installer writes no ~/.bashrc block); accepted so old commands still run" >&2 ;;
    --with-concurrent) WITH_CONCURRENT=1 ;;
    --with-peer) WITH_CONCURRENT=1; echo "note: --with-peer is now --with-concurrent (accepted; update your command)" >&2 ;;
    --with-pi)   WITH_PI=1 ;;
    -h|--help)  sed -n '2,13p' "$0"; exit 0 ;;
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

# Is git running $TARGET/.beads-hooks? core.hooksPath may be the relative `.beads-hooks` we set
# or an absolute path (other tools rewrite it to one; the old tracker's hook installer did). Both run the same
# file, so compare the directory it resolves to, not the string. A string compare said "NOT
# wired" and rewrote the value on every re-run of the first fresh install we did.
# One directory, two spellings: git reports C:/... where the shell says /c/... and /tmp is a
# mount alias (Git Bash); macOS has /var beside /private/var. -ef answers by inode; across MSYS
# mounts the device differs, so there cygpath settles it.
same_dir() {  # same_dir A B -> 0 when both name one directory
  [ "$1" -ef "$2" ] && return 0
  command -v cygpath >/dev/null 2>&1 || return 1
  # -l: the long name. %TEMP% on a hosted runner is the 8.3 form (RUNNER~1), so the two spellings
  # of one directory differed there even in mixed form; Windows paths are case-insensitive too.
  local a b
  a=$(cygpath -ml "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  b=$(cygpath -ml "$2" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ -n "$a" ] && [ "$a" = "$b" ]
}
HOOKS_PATH_VALUE=""
hooks_wired() {
  local hp want got
  hp=$(git -C "$TARGET" config core.hooksPath 2>/dev/null || true); HOOKS_PATH_VALUE=$hp
  [ -n "$hp" ] || return 1
  # Absolute is `/...` or, on Windows, a drive letter: git reports the value as it received it
  # through MSYS argument conversion (C:/Users/...), which `/*` does not match, so the installer
  # took a wired absolute hooksPath for a relative one and re-set it on every run (Actions
  # windows job, 2026-10-06).
  case "$hp" in /*|[A-Za-z]:[/\\]*) ;; *) hp="$TARGET/$hp" ;; esac
  want=$(cd "$TARGET/.beads-hooks" 2>/dev/null && pwd -P) || return 1
  got=$(cd "$hp" 2>/dev/null && pwd -P) || return 1
  same_dir "$got" "$want"
}

# bd's managed region, as bd writes it: `# --- BEGIN/END BEADS INTEGRATION ... ---` in a git hook,
# `<!-- BEGIN/END BEADS INTEGRATION ... -->` in AGENTS.md. This release removes it from hooks
# and reports it in AGENTS.md; it never compares around it any more.
BD_BLOCK='/BEGIN BEADS INTEGRATION/,/END BEADS INTEGRATION/d'

# ---------------------------------------------------------------- preflight --
hdr "dependencies"
need() { # need <cmd> <why> <how>
  if command -v "$1" >/dev/null 2>&1; then say "$1 — $(command -v "$1")"; return 0; fi
  warn "$1 MISSING — $2"; say "    install: $3"; return 1
}
CAIRN_MIN=0.7.0
need git    "everything here is git-scoped"            "your package manager" || true
# cairn 0.7.0 is the first that keeps the four tracked files in .cairn/, which every tool here reads.
if need cairn "the issue tracker and memory store" \
     "git clone https://github.com/scgoetsch/cairn && ln -s \"\$PWD/cairn/bin/cairn\" ~/.local/bin/cairn"; then
  cv=$(cairn --version 2>/dev/null | head -1)
  set -- $(printf '%s\n' "$cv" | sed -n 's/^cairn \([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p')
  if [ $# -ne 3 ]; then
    warn "cairn --version said '${cv:-nothing}', not 'cairn X.Y.Z' — cannot tell whether it is $CAIRN_MIN or later"
  elif [ "$1" -eq 0 ] && [ "$2" -lt 7 ]; then
    warn "cairn is $1.$2.$3 — $CAIRN_MIN or later is required (it reads the tracked files in .cairn/)"
    say "    update: git -C <your cairn clone> pull"
  else
    say "    $cv (>= $CAIRN_MIN)"
  fi
  set --
fi
need python3 "the PreToolUse guard parses hook JSON"   "your package manager" || true
if [ "$WITH_PI" -eq 1 ]; then
  need pi "--with-pi only works when Pi runs and trusts the project extension" \
    "https://github.com/badlogic/pi-mono" || true
  if command -v pi >/dev/null 2>&1 && ! pi --version >/dev/null 2>&1; then
    warn "pi CLI found but cannot run (check its Node runtime); extension will not fire"
  fi
fi

# Optional, and genuinely optional: the pipeline degrades in a defined way without each.
opt() { if command -v "$1" >/dev/null 2>&1; then say "$1 — present"; else say "$1 — absent ($2)"; fi; }
opt jq          "session-start falls back to the full cairn prime dump"
opt rg          "only affects sweep_test.sh's demonstration of the bug"
opt iconv       "sweep.sh cannot flag bad-UTF-8 files as unsearchable"

# THE HARNESS IS A DEPENDENCY, AND IT IS NOT A BINARY TO PROBE FOR. The session hook scripts are
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
say "The .claude/settings.json SESSION HOOKS fire in Claude Code only."
if [ "$WITH_PI" -eq 1 ]; then
  say "Pi adapter requested: .pi/extensions/beads-pipeline.ts loads ONLY when Pi trusts this project."
  say "  It reuses the Claude hook scripts; --no-approve, --no-extensions, and untrusted projects"
  say "  disable it. AGENTS.md and git hooks alone do not prove session guards are running."
else
  say "Pi session hooks NOT installed (opt in with --with-pi, then grant Pi project trust)."
fi
say "  Under agy, a Grok REPL, Cursor or a plain shell there are no session hooks."
say "  Everything else installed here works anywhere: git guards in .beads-hooks/,"
say "  every tool in tools/, and AGENTS.md itself."
say "  Full matrix of what fires where: docs/ops/other-harnesses.md"

[ -d "$PAYLOAD" ] || { warn "payload missing: $PAYLOAD"; exit 1; }

hdr "target"
if [ ! -d "$TARGET" ]; then warn "no such directory: $TARGET"; exit 1; fi
TARGET=$(cd "$TARGET" && pwd -P)
say "$TARGET"
TOP=$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$TOP" ] || [ "$(cd "$TOP" && pwd -P)" != "$TARGET" ]; then
  warn "target must be a git working-tree root — normal repos, worktrees and submodules are supported."
  say "    fix: git -C \"$TARGET\" init (only if this is not already inside a repo)"
  exit 1
fi
GIT_DIR=$(cd "$TARGET" && cd "$(git rev-parse --git-dir)" && pwd -P) || exit 1
GIT_COMMON=$(cd "$TARGET" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || exit 1
if [ "$TARGET" = "$SRC" ]; then
  warn "refusing to install into the pipeline repo itself — pass a target directory."
  exit 1
fi

# ------------------------------------------------------------ the store --
# THIS RELEASE DOES NOT READ bd. Installed over a repo whose store is still bd's, its hooks would
# prime from an empty cairn (or none) while every issue and memory sat in Dolt, and a later
# `cairn init` there would start a second store beside the first. So: a live bd store (bd keeps
# its Dolt database in .beads/embeddeddolt/, or .beads/dolt/ in server mode) with no WRITABLE
# cairn store is refused, in every mode. A cairn shadow (`cairn shadow sync`) is not writable and
# does not count. A worktree's .cairn/redirect names the main checkout's store.
hdr "store"
cairn_db=""
if [ -f "$TARGET/.cairn/redirect" ]; then
  cairn_db="$(head -1 "$TARGET/.cairn/redirect" | tr -d '\r')/cairn.db"
elif [ -e "$TARGET/.cairn/cairn.db" ]; then
  cairn_db="$TARGET/.cairn/cairn.db"
fi
cairn_writable() {  # 0 when $cairn_db is a writable cairn store (meta writable=1)
  [ -n "$cairn_db" ] && [ -f "$cairn_db" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 0   # python3 is reported missing above; trust the file
  python3 -I - "$cairn_db" <<'PY' 2>/dev/null
import sqlite3, sys
try:
    c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
    row = c.execute("SELECT value FROM meta WHERE key = 'writable'").fetchone()
except Exception:
    sys.exit(1)
sys.exit(0 if row and row[0] == "1" else 1)
PY
}
bd_live=""
for d in embeddeddolt dolt; do [ -d "$TARGET/.beads/$d" ] && bd_live="$bd_live .beads/$d/"; done
if cairn_writable; then
  say "cairn store: $cairn_db"
  [ -n "$bd_live" ] && say "bd's old store is still on disk ($bd_live) — nothing here reads it; delete it once the migration manifest has been read"
elif [ -n "$bd_live" ]; then
  warn "REFUSED: this repo's store is still bd's ($bd_live) and there is no writable cairn store (.cairn/cairn.db)."
  say "    This release does not read bd: installing now would leave every issue and memory where no hook looks."
  say "    Move the store first, in order, stopping at the first failure: README.md, \"Moving a repo off bd\""
  say "    ($SRC/README.md). Then run this installer again. Nothing was changed."
  exit 1
elif [ -n "$cairn_db" ]; then
  say "cairn: $cairn_db is not a writable store (a shadow, or unreadable) — create one with cairn init (see Next, below)"
else
  say "no cairn store yet — create it yourself so the prefix is your choice (see Next, below)"
fi

if [ "$MODE" = check ]; then
  if hooks_wired; then say "core.hooksPath=$HOOKS_PATH_VALUE — git runs the shared .beads-hooks/"
  else say "core.hooksPath=${HOOKS_PATH_VALUE:-unset} — the shared pre-commit is NOT wired; install will set it"; fi
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
    # A bd-era copy of a pipeline file is not merely different: it reads .claude/store-cli and can
    # still run bd (the session hooks, the pre-commit's bd-memgraph stanza). Say that by name.
    case $rel in *.md|*_test.sh) ;; *)    # a doc or a suite that mentions them runs nothing
    if grep -qE '\.claude/store-cli|bd hooks run|bd-memgraph|dolt-guard\.sh' "$dst" 2>/dev/null; then
      warn "$rel is the bd-era version and can still run bd — adopt ours unless you know why not:  mv -f \"$dst.new\" \"$dst\""
    fi
    esac
    return 0
  fi
  run mkdir -p "$(dirname "$dst")"
  run cp -f "$src" "$dst"
  [ -n "$mode" ] && run chmod "$mode" "$dst"
  did "$rel"
}

# ---------------------------------------------------------- leaving bd --
# What a bd-era install (bd init, bd hooks install, bd setup <harness>, this installer before
# 0.2.0) left in the repo that would keep running bd. The `.new` rule does not apply here: a
# `.new` beside a hook that still runs bd leaves bd running, and a hook whose cairn stanza is
# replaced while bd's block below it stays turns bd back on. So bd's parts are removed IN PLACE;
# every file touched is first copied under the git dir (never committed, never run by git).
hdr "leaving bd (what a bd-era install left here)"
TS=$(date +%Y%m%dT%H%M%S)
BACKUP="$GIT_COMMON/beads-agent-pipeline-backup/$TS"
backup() {  # backup ABS_PATH -> a copy under $BACKUP at its repo-relative path
  local rel=${1#"$TARGET"/}
  mkdir -p "$BACKUP/$(dirname "$rel")" && cp -fp "$1" "$BACKUP/$rel"
}
bd_left=0
# 1. bd's managed block in every git hook. A hook with nothing left but comments was bd's alone:
#    ours replaces it where we ship one (post-merge, post-checkout, pre-commit), else it goes.
for h in "$TARGET"/.beads-hooks/*; do
  [ -f "$h" ] || continue
  case ${h##*/} in *.new|*.bak*|*.sample) continue ;; esac
  grep -q 'BEGIN BEADS INTEGRATION' "$h" || continue
  bd_left=1; rel=.beads-hooks/${h##*/}
  rest=$(sed "$BD_BLOCK" "$h")
  only_comments=0
  [ -z "$(printf '%s\n' "$rest" | grep -vE '^[[:space:]]*(#.*)?$')" ] && only_comments=1
  if [ "$MODE" = dryrun ]; then
    printf '  \033[36m[dry-run]\033[0m remove bd'"'"'s managed block from %s\n' "$rel"; continue
  fi
  backup "$h" || { warn "$rel: cannot back it up under $BACKUP — bd's block NOT removed"; continue; }
  if [ "$only_comments" -eq 1 ] && [ -f "$PAYLOAD/$rel" ]; then
    cat "$PAYLOAD/$rel" > "$h"
    did "$rel held only bd's block — replaced by ours (backup under $BACKUP)"
  elif [ "$only_comments" -eq 1 ]; then
    rm -f "$h"
    did "$rel held only bd's block — removed (backup under $BACKUP)"
  else
    printf '%s\n' "$rest" > "$h"     # > on the existing file keeps its mode
    did "$rel — bd's managed block removed in place (backup under $BACKUP)"
  fi
done
# 2. Harness hooks that run bd: `bd prime` (bd init / bd setup claude), `bd codex-hook`, `bd
#    cursor-hook`, also in the store-cli-guarded form tools/store-cli-harness-hooks.sh wrote. An
#    entry is bd's when its command's first word is bd; nothing else is touched.
harness_out=$(cd "$TARGET" && python3 -I - "$MODE" "$BACKUP" .claude/settings.json .claude/settings.local.json \
    .codex/hooks.json .cursor/hooks.json <<'PY' 2>&1
import json, os, re, shutil, sys
mode, backup = sys.argv[1], sys.argv[2]
BD = re.compile(r"^\s*bd(\s|$)")
GUARDED = re.compile(r"^\s*\[[^\]]*store-cli[^\]]*\]\s*\|\|\s*(.*)$", re.S)
def is_bd(cmd):
    if not isinstance(cmd, str): return False
    m = GUARDED.match(cmd)
    return bool(BD.match(m.group(1) if m else cmd))
for path in sys.argv[3:]:
    if not os.path.isfile(path): continue
    raw = open(path, encoding="utf-8").read()
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        print(f"WARN {path} is not JSON ({exc}); not read — check it for bd hooks yourself"); continue
    hooks = doc.get("hooks") if isinstance(doc, dict) else None
    if not isinstance(hooks, dict): continue
    removed = []
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list): continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict): kept_groups.append(group); continue
            if isinstance(group.get("hooks"), list):          # Claude, Codex: groups of entries
                entries = group["hooks"]
                keep = [e for e in entries if not (isinstance(e, dict) and is_bd(e.get("command")))]
                removed += [f"{event}: {e['command'].strip()}" for e in entries if e not in keep]
                if keep: group["hooks"] = keep; kept_groups.append(group)
                elif not entries: kept_groups.append(group)
            elif is_bd(group.get("command")):                 # Cursor: entries directly
                removed.append(f"{event}: {group['command'].strip()}")
            else:
                kept_groups.append(group)
        if kept_groups: hooks[event] = kept_groups
        else: del hooks[event]
    if not removed: continue
    if mode == "dryrun":
        for what in removed: print(f"DRY {path} {what}")
        continue
    try:
        os.makedirs(os.path.join(backup, os.path.dirname(path)), exist_ok=True)
        shutil.copy2(path, os.path.join(backup, path))
    except OSError as exc:
        print(f"WARN {path}: cannot back it up under {backup} ({exc}); its bd hooks were NOT removed"); continue
    for what in removed:
        print(f"DID {path} {what}")
    print(f"BACKUP {path}")
    text = json.dumps(doc, indent=2, ensure_ascii=False) + ("\n" if raw.endswith("\n") else "")
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f: f.write(text)
    os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)
PY
) || true
while IFS= read -r line; do
  case $line in
    "DID "*)    bd_left=1; did "removed a harness hook that runs bd — ${line#DID }" ;;
    "DRY "*)    bd_left=1; printf '  \033[36m[dry-run]\033[0m remove the harness hook that runs bd — %s\n' "${line#DRY }" ;;
    "BACKUP "*) say "    backup of ${line#BACKUP }: $BACKUP/${line#BACKUP }" ;;
    "WARN "*)   warn "${line#WARN }" ;;
    ?*)         warn "harness-hook cleanup: $line" ;;
  esac
done <<< "$harness_out"
# 3. The ~/.bashrc block the bd-era installer wrote. One project per ~/.bashrc: it is removed only
#    when it sources THIS repo's tools/dolt-guard.sh; another repo's block is that repo's.
RC="${HOME:-}/.bashrc"; GB='# >>> bd dolt-guard >>>'; GE='# <<< bd dolt-guard <<<'
esc() { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }
if [ -n "${HOME:-}" ] && [ -f "$RC" ] && grep -qxF "$GB" "$RC"; then
  rc_block=$(sed -n "/^$(esc "$GB")\$/,/^$(esc "$GE")\$/p" "$RC")
  if printf '%s\n' "$rc_block" | grep -qF "\"$TARGET/tools/dolt-guard.sh\""; then
    bd_left=1
    if [ "$MODE" = dryrun ]; then printf '  \033[36m[dry-run]\033[0m remove the bd dolt-guard block from %s\n' "$RC"
    else
      cp -f "$RC" "$RC.bak.$TS" \
        && sed "/^$(esc "$GB")\$/,/^$(esc "$GE")\$/d" "$RC" > "$RC.bap.$$" && cat "$RC.bap.$$" > "$RC" && rm -f "$RC.bap.$$" \
        && did "removed the bd dolt-guard block for this repo from $RC (backup: $RC.bak.$TS)" \
        || warn "could not remove the bd dolt-guard block from $RC — remove the lines between '$GB' and '$GE' yourself"
    fi
  else
    say "$RC has a bd dolt-guard block for ANOTHER repo — left alone (it is that repo's)"
  fi
fi
# 4. Files the bd-era pipeline shipped that this one does not. Nothing here runs them any more;
#    they are named, not deleted, because they are tracked files of yours now.
stale=""
for rel in .claude/store-cli tools/store-cli.sh tools/dolt-guard.sh tools/dolt-guard_test.sh \
           tools/store-cli-git-hooks.sh tools/store-cli-git-hooks_test.sh \
           tools/store-cli-harness-hooks.sh tools/store-cli-harness-hooks_test.sh \
           tools/pre-commit-store-cli_test.sh; do
  [ -e "$TARGET/$rel" ] && stale="$stale $rel"
done
if [ -n "$stale" ]; then
  bd_left=1
  say "bd-era files this release no longer ships (nothing runs them; remove them):"
  say "    git rm -q --$stale"
fi
# 5. The old tracker's own exports in .beads/ (its issues.jsonl is usually tracked). cairn reads
#    its exports from .beads/ while .cairn/ holds none, and refuses a split once both do, so every
#    `cairn sync` and export refresh after the move would fail. Named; the fix is a git rm.
old_exports=""
for f in issues.jsonl memories.jsonl allocator.json events.jsonl; do
  { [ -f "$TARGET/.beads/$f" ] || [ -n "$(git -C "$TARGET" ls-files -- ".beads/$f" 2>/dev/null)" ]; } \
    && old_exports="$old_exports .beads/$f"
done
if [ -n "$old_exports" ]; then
  bd_left=1
  warn "the old tracker's exports are still in .beads/ (${old_exports# }) — cairn refuses exports split between .beads/ and .cairn/"
  say "    remove them (git history keeps them):  git rm -q --cached --ignore-unmatch$old_exports && rm -f$old_exports"
fi
# 6. Sibling worktrees of this checkout share its store through an untracked .cairn/redirect
#    (cairn README, worktrees). One made before the move has none, and its post-checkout
#    `cairn sync` would build a store of its own there. Written only from the main checkout,
#    only where a worktree has neither a redirect nor a database.
if [ "$GIT_DIR" = "$GIT_COMMON" ] && cairn_writable && [ "$cairn_db" = "$TARGET/.cairn/cairn.db" ]; then
  while IFS= read -r wt; do
    wt=${wt#worktree }; [ -n "$wt" ] && [ -d "$wt" ] || continue
    [ "$(cd "$wt" && pwd -P)" = "$TARGET" ] && continue
    if [ -f "$wt/.cairn/redirect" ]; then say "worktree $wt shares this store (.cairn/redirect)"
    elif [ -e "$wt/.cairn/cairn.db" ]; then
      warn "worktree $wt has a cairn store of its own — it does not share this one; see tools/new-worktree.sh"
    elif [ "$MODE" = dryrun ]; then printf '  \033[36m[dry-run]\033[0m write %s/.cairn/redirect\n' "$wt"
    else
      mkdir -p "$wt/.cairn" && printf '%s\n' "$TARGET/.cairn" > "$wt/.cairn/redirect" \
        && did "worktree $wt now shares this store (.cairn/redirect -> $TARGET/.cairn)" \
        || warn "could not write $wt/.cairn/redirect"
    fi
  done < <(git -C "$TARGET" worktree list --porcelain 2>/dev/null | grep '^worktree ')
fi
[ "$bd_left" -eq 0 ] && say "nothing of bd's found"

hdr "session machinery (.claude/)"
for f in bd-prime-hook.sh bd-prerun-hook.sh bd-stop-hook.sh; do install_file ".claude/$f" 755; done
install_file ".claude/memory-hot.txt"

if [ "$WITH_PI" -eq 1 ]; then
  hdr "Pi adapter (.pi/extensions/; requires project trust)"
  install_file ".pi/extensions/beads-pipeline.ts"
  say "Pi must trust this project before its extension loads; see docs/ops/pi-adapter.md"
fi

# settings.json is the one file a user is LIKELY to already have, and clobbering it would take
# their unrelated hooks with it. Merge when we can, and say so plainly when we cannot.
SET="$TARGET/.claude/settings.json"
if [ ! -e "$SET" ]; then
  install_file ".claude/settings.json"
elif cmp -s "$PAYLOAD/.claude/settings.json" "$SET"; then
  say ".claude/settings.json (already current)"
elif command -v jq >/dev/null 2>&1; then
  # jq object multiplication REPLACES arrays, deleting unrelated hooks under the same event.
  # Merge groups instead. Never identify ownership by a substring in an arbitrary command: a group
  # is the pipeline's when it is EQUAL to one we ship now, or to one 0.1 shipped ($was: the same
  # commands, whose missing-hook message said "bd session rules"), and only those are replaced.
  # bd's own harness hooks were removed above ("leaving bd").
  merged=$(jq -s '
    .[1].hooks as $ours |
    ([$ours[][] | .hooks |= map(.command |= sub("the pipeline.s session rules"; "bd session rules"))]) as $was |
    .[0] |
    reduce ($ours | keys[]) as $event (. ;
      .hooks[$event] = ((.hooks[$event] // []) | map(select(. as $g | $was | index([$g]) | not))) |
      reduce $ours[$event][] as $group (. ;
        if (.hooks[$event] | index([$group])) == null then
          .hooks[$event] += [$group] else . end))
  ' "$SET" "$PAYLOAD/.claude/settings.json" 2>/dev/null) || merged=""
  if [ -n "$merged" ] && [ "$merged" != "null" ]; then
    if [ "$(printf '%s' "$merged" | jq -S .)" = "$(jq -S . "$SET" 2>/dev/null)" ]; then
      say ".claude/settings.json (hooks already present)"
    else
      run cp -f "$SET" "$SET.bak.$(date +%s)"
      if [ "$MODE" = dryrun ]; then printf '  \033[36m[dry-run]\033[0m merge hooks into %s\n' "$SET"
      else printf '%s\n' "$merged" > "$SET"; fi
      did ".claude/settings.json — merged our hooks in (backup kept)"
      say "    preserved user hooks, including hooks on the same events"
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
# Scripts among the skill files must stay executable: `install_file` with no mode leaves the
# payload's bits, and a 0644 audit_wikilinks.py fails as ./audit_wikilinks.py (2026-09-22).
while IFS= read -r rel; do
  case $rel in *.py|*.sh) install_file "$rel" 755 ;; *) install_file "$rel" ;; esac
done < <(cd "$PAYLOAD" && find .claude/skills -type f | sort)

hdr "site checks (.claude/site-checks/)"
# A site check that is not executable is silently skipped by the prime hook, so scripts here get 755.
while IFS= read -r rel; do
  case $rel in *.sh) install_file "$rel" 755 ;; *) install_file "$rel" ;; esac
done < <(cd "$PAYLOAD" && find .claude/site-checks -type f)

# The curation gate's stamp is written ONCE and never shipped as payload: it records when THIS
# repo's store was last curated, so it must diverge per repo and must not come back as a .new.
# Count the memory rows of the tracked export, as the gate does; a store that does not exist yet
# is 0, which is correct -- the first ten memories then ask for the first audit.
hdr "memory curation stamp (.claude/memory-curation.txt)"
CURATION_STAMP="$TARGET/.claude/memory-curation.txt"
if [ -e "$CURATION_STAMP" ]; then
  say ".claude/memory-curation.txt — kept ($(head -1 "$CURATION_STAMP" | cut -f1,2 | tr '\t' ' '))"
else
  stamp_count=0
  if [ -f "$TARGET/.cairn/memories.jsonl" ]; then
    stamp_count=$(grep -c '^{"_type":"memory"' "$TARGET/.cairn/memories.jsonl"); stamp_count=${stamp_count:-0}
  fi
  if [ "$MODE" = dryrun ]; then
    run "write .claude/memory-curation.txt: $(date +%Y-%m-%d) <TAB> $stamp_count"
  else
    printf '%s\t%s\n' "$(date +%Y-%m-%d)" "$stamp_count" > "$CURATION_STAMP"
    did ".claude/memory-curation.txt written: $(date +%Y-%m-%d), $stamp_count memories (the gate counts from here)"
  fi
fi

hdr "tools (tools/)"
while IFS= read -r rel; do install_file "$rel" 755; done < <(cd "$PAYLOAD" && find tools -type f | sort)

hdr "docs (docs/ops/)"
CONCURRENT_DOC="docs/ops/concurrent-sessions.md"
while IFS= read -r rel; do
  if [ "$rel" = "$CONCURRENT_DOC" ] && [ "$WITH_CONCURRENT" -eq 0 ]; then
    say "$CONCURRENT_DOC — skipped (concurrent-sessions layer is opt-in; re-run with --with-concurrent)"
    continue
  fi
  install_file "$rel"
done < <(cd "$PAYLOAD" && find docs -type f | sort)

hdr "repo guards (.beads-hooks/)"
# pre-commit runs `cairn check`, the two path guards and the export freshness check;
# post-merge and post-checkout run `cairn sync`, which brings this clone's store up to the
# exports a pull or a checkout brought in. bd's blocks were taken out above ("leaving bd").
for h in pre-commit post-merge post-checkout; do install_file ".beads-hooks/$h" 755; done

# ------------------------------------------------------------- agent docs --
hdr "agent docs (AGENTS.md + CLAUDE.md)"
# Render the template for this install: with --with-concurrent the concurrency section stays (markers
# removed); without it the whole block goes, so AGENTS.md never cites a doc we did not install.
AGENTS_RENDERED=$(mktemp "${TMPDIR:-/tmp}/bap-agents.XXXXXX") || exit 1
if [ "$WITH_CONCURRENT" -eq 1 ]; then
  sed '/<!-- concurrent:begin -->/d; /<!-- concurrent:end -->/d' "$PAYLOAD/AGENTS.md" > "$AGENTS_RENDERED"
else
  # squeeze the blank-line run the removal leaves behind, so the seam is invisible
  sed '/<!-- concurrent:begin -->/,/<!-- concurrent:end -->/d' "$PAYLOAD/AGENTS.md" \
    | awk 'BEGIN{b=0} /^$/{b++; if(b>1) next} !/^$/{b=0} {print}' > "$AGENTS_RENDERED"
fi
trap 'rm -f "$AGENTS_RENDERED"' EXIT
# AGENTS.md is the one payload file that is MEANT to diverge from ours: the user edits it. So this never drops an AGENTS.md.new beside it -- that was
# re-offered on every re-run, read as "a truncated rewrite in progress" by the first outside
# reader, and was a trap for whoever edited the wrong file next. Say which state it is in and
# where our template lives; that is all the information the .new ever carried.
if [ -e "$TARGET/AGENTS.md" ]; then
  if cmp -s "$AGENTS_RENDERED" "$TARGET/AGENTS.md"; then say "AGENTS.md (already current)"
  else
    say "AGENTS.md is yours — kept. It differs from our template, which is the point."
    say "    our template: $PAYLOAD/AGENTS.md  (the concurrent-sessions section is stripped unless --with-concurrent)"
  fi
  # bd init appends a managed block telling agents to use bd. It is in YOUR file, so it is named,
  # not removed: an agent that reads it runs bd, which here creates a store nobody reads.
  if grep -q 'BEGIN BEADS INTEGRATION' "$TARGET/AGENTS.md" 2>/dev/null; then
    warn "AGENTS.md still carries bd's managed block (<!-- BEGIN BEADS INTEGRATION --> ... END): it tells agents to use bd — delete it"
  fi
  if [ -e "$TARGET/AGENTS.md.new" ]; then
    run rm -f "$TARGET/AGENTS.md.new"
    did "removed AGENTS.md.new — an earlier run left it; it was only ever a copy of our template"
  fi
else
  run cp -f "$AGENTS_RENDERED" "$TARGET/AGENTS.md"
  did "AGENTS.md (template — edit it, it is meant to be yours)"
fi

# One file, two names. Where the filesystem has no symlinks, git's own on-disk form of the link
# is a regular file holding the target's name, and the index carries the symlink (mode 120000).
pointer_staged() {  # pointer_staged DIR -> 0 when CLAUDE.md there is that form, staged as a link
  [ -f "$1/CLAUDE.md" ] && [ ! -L "$1/CLAUDE.md" ] && [ "$(cat "$1/CLAUDE.md")" = "AGENTS.md" ] || return 1
  case "$(git -C "$1" ls-files --stage -- CLAUDE.md 2>/dev/null)" in "120000 "*) return 0 ;; esac
  return 1
}
if [ -L "$TARGET/CLAUDE.md" ] && [ "$(readlink "$TARGET/CLAUDE.md")" = "AGENTS.md" ]; then
  say "CLAUDE.md -> AGENTS.md (already linked)"
elif pointer_staged "$TARGET"; then
  say "CLAUDE.md -> AGENTS.md (already linked: a pointer file staged as a symlink — no symlinks on this filesystem)"
elif [ -e "$TARGET/CLAUDE.md" ] && [ ! -L "$TARGET/CLAUDE.md" ]; then
  # Never silently discard a regular file: it may hold edits AGENTS.md does not.
  warn "CLAUDE.md is a REGULAR FILE, not a symlink. Not touching it."
  say "    reconcile:  diff \"$TARGET/CLAUDE.md\" \"$TARGET/AGENTS.md\""
  say "    then:       rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md"
elif [ ! -e "$TARGET/CLAUDE.md" ]; then
  # `ln -s && did` alone would SAY NOTHING when ln fails, which it does on filesystems without
  # symlink support (Windows without Developer Mode, some network and container mounts). The
  # component whose job is to create the link is the worst place to fail quietly.
  #
  # MSYS=winsymlinks:nativestrict: Git Bash's `ln -s` COPIES the target by default and reports
  # success, which turns one file with two names into two files with no error (first native
  # Windows run, 2026-10-06). With it set, ln makes a real symlink where Windows allows one
  # (Developer Mode, or an elevated shell) and fails otherwise -- and the failure takes the
  # fallback: write git's own on-disk form of the link on such a checkout, a file holding the
  # target's name, and stage it as a symlink (mode 120000) so it COMMITS as one and every clone
  # with symlinks gets the real link. The guard accepts that state when the index agrees.
  # BAP_INSTALL_NO_SYMLINKS=1 forces the fallback; the self-test uses it on a box that has
  # symlinks, so this path is exercised everywhere and not only where it is needed.
  if [ "$MODE" = dryrun ]; then printf '  \033[36m[dry-run]\033[0m ln -s AGENTS.md CLAUDE.md\n'
  elif [ -z "${BAP_INSTALL_NO_SYMLINKS:-}" ] \
       && MSYS=winsymlinks:nativestrict ln -s AGENTS.md "$TARGET/CLAUDE.md" 2>/dev/null \
       && [ -L "$TARGET/CLAUDE.md" ]; then
    did "CLAUDE.md -> AGENTS.md"
  else
    rm -f "$TARGET/CLAUDE.md"      # an ln that copied instead of linking leaves a file behind
    printf 'AGENTS.md' > "$TARGET/CLAUDE.md"
    if blob=$(printf 'AGENTS.md' | git -C "$TARGET" hash-object -w --stdin 2>/dev/null) \
       && git -C "$TARGET" update-index --add --cacheinfo "120000,$blob,CLAUDE.md" 2>/dev/null; then
      did "CLAUDE.md -> AGENTS.md as a POINTER FILE (no symlinks on this filesystem): the file holds the target's name and the index holds the symlink, mode 120000, so it commits as a link"
      say "    real links on Windows need:  git config --global core.symlinks true  (Developer Mode or an elevated shell)"
    else
      warn "could not create the CLAUDE.md symlink, and could not stage the pointer file as one — see docs/ops/agent-docs-symlink.md"
    fi
  fi
fi
# --------------------------------------------------------------- git hooks --
# Wired whether or not cairn is present. Two of the pre-commit's stanzas (agent-cache paths,
# agent-docs symlink) need no store and are the whole point on a box without one; the ones that do
# need it self-skip. This once sat inside the store branch of the installer, so a box without the
# tracker got the hook file copied and reported with a green +, and nothing said that wiring it had
# been skipped -- the git layer guarded nothing. Instance 12 in
# docs/ops/checks-narrower-than-what-they-check.md.
hdr "git hooks"
if hooks_wired; then say "core.hooksPath=$HOOKS_PATH_VALUE already runs .beads-hooks/"
else
  scope=--local
  if [ "$GIT_DIR" != "$GIT_COMMON" ]; then
    # core.hooksPath is otherwise shared with the main checkout and every sibling worktree.
    # Git requires these two main-worktree-only values to move when enabling this extension.
    if [ "$(git -C "$TARGET" config --bool extensions.worktreeConfig || true)" != true ]; then
      for key in core.bare core.worktree; do
        if value=$(git -C "$TARGET" config --local --get "$key"); then
          run git config --file "$GIT_COMMON/config.worktree" "$key" "$value" || exit 1
          run git -C "$TARGET" config --local --unset-all "$key" || exit 1
        fi
      done
      run git -C "$TARGET" config extensions.worktreeConfig true || exit 1
    fi
    scope=--worktree
  elif [ "$(git -C "$TARGET" config --bool extensions.worktreeConfig || true)" = true ]; then
    scope=--worktree
  fi
  run git -C "$TARGET" config "$scope" core.hooksPath .beads-hooks || exit 1
  did "set core.hooksPath=.beads-hooks ($scope; was ${HOOKS_PATH_VALUE:-unset})"
fi
stale=$(ls "$GIT_COMMON/hooks" 2>/dev/null | grep -vc '\.sample$' || true)
[ "${stale:-0}" -gt 0 ] && warn "$stale hook(s) in $GIT_COMMON/hooks — ignored in this worktree; review before deleting (siblings may use them)."

# ------------------------------------------------------------------ verify --
hdr "verify"
# Which guards are actually in the shared pre-commit. The hook file ships with four stanzas:
# the store check (`cairn check`), the agent-cache path guard, the agent-docs guard and the
# export freshness guard. A clone missing a stanza is otherwise SILENTLY unguarded, which is the
# exact failure this pipeline exists to prevent. Report presence per guard rather than assuming it.
HK="$TARGET/.beads-hooks/pre-commit"
if [ -f "$HK" ] && [ "$MODE" != dryrun ]; then
  for marker in ">>> store check >>>:store check (cairn check)" \
                "agent-cache path guard:agent-cache path guard" \
                "agent-docs symlink guard:agent-docs guard" \
                "export freshness guard:export freshness guard"; do
    pat=${marker%%:*}; name=${marker#*:}
    if grep -q "$pat" "$HK" 2>/dev/null; then say "$name present in .beads-hooks/pre-commit"
    else warn "$name MISSING from .beads-hooks/pre-commit — re-run this installer"; fi
  done
  # Nothing in a git hook may still call bd: that is the one thing "leaving bd" exists to stop.
  for h in "$TARGET"/.beads-hooks/*; do
    [ -f "$h" ] || continue
    case ${h##*/} in *.new|*.bak*|*.sample) continue ;; esac
    grep -qE 'bd hooks run|BEGIN BEADS INTEGRATION' "$h" \
      && warn ".beads-hooks/${h##*/} still runs bd — remove bd's block from it"
  done
  # Presence in the file is a textual claim. Whether git RUNS the file is core.hooksPath, and
  # that was the piece this installer used to skip without saying so. Assert the wiring too.
  if hooks_wired; then say "core.hooksPath=$HOOKS_PATH_VALUE — git runs that file"
  else warn "core.hooksPath is '${HOOKS_PATH_VALUE:-unset}', which is not .beads-hooks/ — every stanza above is present and NONE of them fires"; fi
fi
# Nothing installed here helps a clone if the target's .gitignore eats it. The workspace this came
# from ignores `*.txt`, which swallowed .claude/memory-hot.txt: every clone would have taken the
# SessionStart hook's full-dump fallback. Check every payload file that landed, not a chosen few.
if [ "$MODE" != dryrun ]; then
  eaten=$(cd "$PAYLOAD" && find . -type f | sed 's|^\./||' | while IFS= read -r rel; do
    [ -e "$TARGET/$rel" ] && git -C "$TARGET" ls-files --others --ignored --exclude-standard -- "$rel"; done)
  if [ -n "$eaten" ]; then
    warn "installed file(s) GITIGNORED in this repo — they will not reach any clone; add a \`!path\` re-include:"
    printf '%s\n' "$eaten" | sed 's/^/        /' >&2
  else say "no installed file is gitignored here"; fi
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
  # The one number the session hook lives or dies by: Claude Code shows at most 10,000 bytes of
  # one hook's output (a 2,000-byte preview above that). The hook trims itself to that budget and
  # says so on its first line; measure the real payload here rather than trusting either.
  if [ -x "$TARGET/.claude/bd-prime-hook.sh" ]; then
    pb=$(cd "$TARGET" && bash .claude/bd-prime-hook.sh 2>/dev/null | wc -c | tr -d ' ')
    pl=$(cd "$TARGET" && bash .claude/bd-prime-hook.sh 2>/dev/null | head -1)
    case $pb in ''|*[!0-9]*) pb=0 ;; esac
    if [ "$pb" -gt 10000 ]; then warn "session payload is $pb bytes — above the 10,000 Claude Code shows; the hook should have trimmed it (BD_PRIME_BUDGET?)"
    else say "session payload: $pb bytes (Claude Code shows at most 10,000 per hook)"; fi
    case $pl in *"PAYLOAD TRIMMED"*) say "    the hook trimmed it — see its first line; shorten .claude/memory-hot.txt" ;; esac
  fi
fi

hdr "result"
[ "$changed" -eq 0 ] && say "nothing to do — this checkout was already set up." || say "$changed change(s) applied."
if [ "$problems" -gt 0 ]; then say "$problems item(s) need your attention (marked ! above)."; fi
cat <<NEXT

Next:
  cd "$TARGET"
  cairn init -p <PREFIX>                 # if there is no cairn store yet; the prefix is yours to choose
  tools/refresh-beads-exports.sh         # writes the four tracked files into .cairn/
  git add .cairn/.gitignore .cairn/config.json .cairn/issues.jsonl .cairn/memories.jsonl \\
          .cairn/allocator.json .cairn/events.jsonl
  git commit -m "cairn store" -- .cairn/  # a store is not finished until another clone can cairn sync from it
  tools/agent_docs_test.sh               # and the rest of the suite in AGENTS.md
Then open AGENTS.md and make it yours.
The concurrent-sessions layer is $( [ "$WITH_CONCURRENT" -eq 1 ] && echo INSTALLED || echo "NOT installed — add it with --with-concurrent if more than one session will run against this repo" ).
Pi adapter is $( [ "$WITH_PI" -eq 1 ] && echo "COPIED — verify Pi project trust and run tools/pi-extension_test.sh" || echo "NOT installed — add it with --with-pi, then grant Pi project trust" ).
NEXT
exit $(( problems > 0 ))
