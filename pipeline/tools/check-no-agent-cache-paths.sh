#!/usr/bin/env bash
# check-no-agent-cache-paths.sh — reject commits that embed absolute agent-cache paths.
#
# WHY THIS EXISTS, AND WHY IT IS A GIT HOOK
# Coding agents stage working artifacts in per-conversation cache directories: agy /
# antigravity under ~/.gemini/antigravity-cli/brain/<uuid>/, Claude Code under
# ~/.claude/projects/<uuid>/ and $TMPDIR/claude-<uid>/ (/tmp on Linux, /var/folders/... on
# macOS). Those paths are user-local and
# ephemeral — they resolve for nobody else, on no other machine, and not for the same
# person next week. A figure linked from one is a broken image for every other reader.
#
# The root-cause pattern generalises: ANY agent with a per-conversation scratch directory
# will leak absolute paths into committed files unless something stops it. Relying on the
# agent to rewrite paths before committing has already been tried, and failed.
#
# So this is enforced at the GIT layer, deliberately. Session hooks are harness-specific —
# .claude/settings.json does nothing in agy, a Grok REPL or Codex — but every agent, and
# every human, goes through `git commit`. A guard here covers all of them at once.
# See docs/ops/other-harnesses.md.
#
# WHAT IT SCANS
#   documents + generated data : WHOLE FILE (strict)
#   code                       : ADDED LINES ONLY (a ratchet, not a flag day) — a repo
#                                adopting this mid-life usually has pre-existing hits, and
#                                blocking unrelated work on them guarantees --no-verify
#                                becomes habit. New ones cannot land.
#
# Acceptance test: tools/check-no-agent-cache-paths_test.sh. A guard that has never been
# seen to fail is not evidence of anything: the ancestor of this hook silently passed a bad
# commit because `grep -E '^\+' | grep -v '^\+\+\+'` lacked -E on the second grep, making it
# a malformed BRE that excluded EVERY line. That is why the added-line filter below is awk.
#
# Bypass once (rarely right): git commit --no-verify

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0

# Extend as new agent CLIs appear. Any user, and macOS as well as Linux — the original was
# pinned to one literal home directory, which is fine in one workspace and useless in a repo
# other people clone.
# Every home-directory form we know: /home/<u> (Linux), /var/home/<u> (Fedora Silverblue and
# other ostree systems, where /home is a symlink and a resolved path carries the long form),
# /Users/<u> (macOS), /root (Docker, cloud VMs, WSL as root). The 2026-09-22 review found the
# first two holes below in patterns this file already claimed to cover.
HOME_RE='(home/[^/[:space:]]+|var/home/[^/[:space:]]+|Users/[^/[:space:]]+|root)'
FORBIDDEN_PATTERNS=(
    "/$HOME_RE/\\.gemini/antigravity-cli/brain/"
    "/$HOME_RE/\\.claude/projects/"
    # Claude Code's scratch dir is $TMPDIR/claude-<uid>/: /tmp on Linux; on macOS the per-user
    # /var/folders/xx/yyyy/T/, which also appears resolved as /private/var/folders/...
    '/tmp/claude-[0-9]+/'
    '/(private/)?var/folders/[^/[:space:]]+/[^/[:space:]]+/T/claude-[0-9]+/'
    "file:///$HOME_RE/\\.(gemini|claude)/"
)
FORBIDDEN_RE=$(IFS='|'; echo "${FORBIDDEN_PATTERNS[*]}")

violations=0

# ---- documents and generated data: whole file -------------------------------------
# .json/.tsv/.csv are included because generated manifests are exactly where captured
# paths accumulate: a generator that catches an error verbatim writes the scratch path
# into the artifact, and the artifact gets committed.
# `while read`, not `mapfile`: mapfile is bash 4, and macOS ships bash 3.2. There the array
# stayed unset and the guard either aborted every commit (set -u) or, without it, passed
# everything -- the silent shape. Neither is a guard.
doc_files=()
while IFS= read -r f; do doc_files+=("$f"); done < <(
    git diff --cached --name-only --diff-filter=ACMR -- \
        '*.md' '*.markdown' '*.rst' '*.txt' '*.ipynb' '*.html' '*.tex' '*.typ' '*.adoc' \
        '*.Rmd' '*.qmd' '*.json' '*.tsv' '*.csv' 2>/dev/null
)
for f in ${doc_files[@]+"${doc_files[@]}"}; do
    [ -f "$f" ] || continue
    if matches=$(grep -nEI "$FORBIDDEN_RE" "$f" 2>/dev/null); then
        echo "ERROR: $f contains forbidden agent-cache path(s):" >&2
        echo "$matches" | sed 's/^/  /' >&2
        violations=1
    fi
done

# ---- code: added lines only -------------------------------------------------------
code_files=()
while IFS= read -r f; do code_files+=("$f"); done < <(
    # The ratchet is exactly as wide as this list: a language missing here commits a cache path
    # clean, the silent pass this guard exists to prevent. It stopped at scripting languages
    # until the 2026-09-22 review. Add, never remove.
    git diff --cached --name-only --diff-filter=ACMR -- \
        '*.py' '*.sh' '*.bash' '*.zsh' '*.R' '*.pl' '*.rb' '*.js' '*.mjs' '*.cjs' '*.jsx' \
        '*.ts' '*.tsx' '*.rs' '*.go' '*.c' '*.h' '*.cc' '*.cpp' '*.cxx' '*.hpp' '*.java' '*.kt' \
        '*.kts' '*.scala' '*.swift' '*.cs' '*.php' '*.lua' '*.zig' '*.jl' '*.ex' '*.exs' '*.erl' \
        '*.hs' '*.sql' '*.toml' '*.yaml' '*.yml' '*.ini' '*.cfg' '*.conf' 2>/dev/null
)
for f in ${code_files[@]+"${code_files[@]}"}; do
    [ -f "$f" ] || continue
    # awk, not `grep -E '^\+' | grep -v '^\+\+\+'` — see the header. The second grep needs
    # -E or the pattern is a malformed BRE and -v silently drops every line.
    if matches=$(git diff --cached -U0 -- "$f" \
                    | awk '/^\+\+\+/ {next} /^\+/ {print}' \
                    | grep -nE "$FORBIDDEN_RE" 2>/dev/null); then
        echo "ERROR: $f ADDS forbidden agent-cache path(s):" >&2
        echo "$matches" | sed 's/^/  /' >&2
        violations=1
    fi
done

if [ "$violations" -ne 0 ]; then
    cat >&2 <<'MSG'

Agent-cache absolute paths (brain/<uuid>/, projects/<uuid>/, $TMPDIR/claude-<uid>/) are
user-local and ephemeral. They break for every other reader and on every other machine.

Fix: copy the artifact into the repo if it is not already there, and reference it with a
REPO-RELATIVE path. Write it that way from the start — do not paste a cache path and plan
to rewrite it later, which is the failure this guard exists for.

To bypass for one commit (rarely the right call): git commit --no-verify
MSG
    exit 1
fi
exit 0
