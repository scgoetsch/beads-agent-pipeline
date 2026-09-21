#!/usr/bin/env bash
# check-no-agent-cache-paths.sh — reject commits that embed absolute agent-cache paths.
#
# WHY THIS EXISTS, AND WHY IT IS A GIT HOOK
# Coding agents stage working artifacts in per-conversation cache directories: agy /
# antigravity under ~/.gemini/antigravity-cli/brain/<uuid>/, Claude Code under
# ~/.claude/projects/<uuid>/ and /tmp/claude-<uid>/. Those paths are user-local and
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
FORBIDDEN_PATTERNS=(
    '/(home|Users)/[^/[:space:]]+/\.gemini/antigravity-cli/brain/'
    '/(home|Users)/[^/[:space:]]+/\.claude/projects/'
    '/tmp/claude-[0-9]+/'
    'file:///(home|Users)/[^/[:space:]]+/\.(gemini|claude)/'
)
FORBIDDEN_RE=$(IFS='|'; echo "${FORBIDDEN_PATTERNS[*]}")

violations=0

# ---- documents and generated data: whole file -------------------------------------
# .json/.tsv/.csv are included because generated manifests are exactly where captured
# paths accumulate: a generator that catches an error verbatim writes the scratch path
# into the artifact, and the artifact gets committed.
mapfile -t doc_files < <(
    git diff --cached --name-only --diff-filter=ACMR -- \
        '*.md' '*.markdown' '*.rst' '*.txt' '*.ipynb' '*.html' \
        '*.json' '*.tsv' '*.csv' 2>/dev/null
)
for f in "${doc_files[@]}"; do
    [ -f "$f" ] || continue
    if matches=$(grep -nEI "$FORBIDDEN_RE" "$f" 2>/dev/null); then
        echo "ERROR: $f contains forbidden agent-cache path(s):" >&2
        echo "$matches" | sed 's/^/  /' >&2
        violations=1
    fi
done

# ---- code: added lines only -------------------------------------------------------
mapfile -t code_files < <(
    git diff --cached --name-only --diff-filter=ACMR -- \
        '*.py' '*.sh' '*.R' '*.pl' '*.rb' '*.js' '*.ts' '*.toml' '*.yaml' '*.yml' 2>/dev/null
)
for f in "${code_files[@]}"; do
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

Agent-cache absolute paths (brain/<uuid>/, projects/<uuid>/, /tmp/claude-<uid>/) are
user-local and ephemeral. They break for every other reader and on every other machine.

Fix: copy the artifact into the repo if it is not already there, and reference it with a
REPO-RELATIVE path. Write it that way from the start — do not paste a cache path and plan
to rewrite it later, which is the failure this guard exists for.

To bypass for one commit (rarely the right call): git commit --no-verify
MSG
    exit 1
fi
exit 0
