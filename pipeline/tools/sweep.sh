#!/usr/bin/env bash
# sweep.sh — corpus-wide grep for correction sweeps, guarded by a positive control.
#
# WHY THIS EXISTS
#   A recursive grep from a workspace root does NOT necessarily search your corpus.
#   If the root .gitignore lists nested project repos -- normal when they have their own
#   remotes -- then every modern grep front-end skips them by default:
#     * ripgrep (`rg`, and any agent harness tool that wraps it) honours .gitignore natively
#     * a `grep` shell function passing --ignore-files does the same
#   Measured in one such workspace on 2026-09-21: `rg` from the root reached 131 files. This
#   tool reached 8,993 across 7 git repos. A root sweep therefore covered ~1.5% of the corpus
#   and reported ZERO HITS -- indistinguishable from a clean sweep.
#
#   RE-MEASURE IN YOUR OWN TREE. The RATIO is the durable claim, never the counts: the same
#   workspace read 72 files at the root six weeks earlier, and the number moved because the
#   ROOT repo grew, not because the hazard changed. Anything that pins an absolute count here
#   ages out and then lies in whichever direction the tree happened to grow.
#
#   This matters most for a CORRECTION SWEEP: when a claim turns out to be wrong, you grep
#   the distinctive number and phrase across every sibling document to find where else it
#   lives. Run from the repo root, that step was silently a no-op.
#
# WHAT THIS DOES DIFFERENTLY
#   1. Enumerates every git repo under the root and scans each one separately,
#      so no .gitignore can hide a whole repo.
#   2. Scans tracked files AND untracked-but-not-ignored files. One repo in the tree this
#      came from had no commits at all (0 tracked files) and would otherwise have returned
#      a silent zero. An uncommitted tree is invisible to a git-grep-only sweep.
#   3. Runs a POSITIVE CONTROL per repo: it lifts a real line out of a real file in
#      that repo and greps for it through the identical code path. If that line is not
#      found, the repo was not actually searched, and the sweep exits non-zero and says
#      so. A zero-hit result is only trustworthy when every control passed.
#   4. Reports files skipped for size AND files skipped as binary, so neither
#      exclusion is ever silent.
#
# WHAT IT STILL DOES NOT REACH (state this when you report a sweep)
#   * Claims rendered into FIGURES (PNG/PDF pixels). No text search reaches those; they
#     need the separate figure-vs-generator check. Memory:
#     no text search reaches a claim that only exists as pixels.
#   * Files gitignored INSIDE a repo — excluded by default because that is where the
#     multi-TB data lives. Pass --include-ignored to cover them.
#   * Files over the size cap. The count is printed; raise it with --max-bytes.
#   * Files grep calls BINARY — including plain prose carrying one malformed byte,
#     which is how one README.md hid the phrase 'three repositories' from a sweep. The count is printed; read those files directly.
#   * The bd layer (memories, issue descriptions/notes) — those are separate
#     `bd memories` / `bd list` searches. A document sweep is not a corpus sweep.
#
# USAGE
#   tools/sweep.sh 'distinctive phrase'        # fixed string (default)
#   tools/sweep.sh -E 'regex|alternation'
#   tools/sweep.sh -i -F '12,054'
#   tools/sweep.sh --docs 'phrase'             # prose/code/config files only
#   tools/sweep.sh --include '*.md' 'phrase'   # repeatable glob filter
#   tools/sweep.sh --include-ignored 'phrase'   # also search gitignored files
#   tools/sweep.sh --max-bytes 20000000 'phrase'
#   tools/sweep.sh --depth 4 'phrase'           # bounded discovery: exit 2, cannot certify absence
#
#   Filters NARROW the sweep, so they are printed in the header and repeated in the
#   verdict line. Never add one without reading it back — a narrowed sweep that looks
#   clean is the same failure this tool exists to prevent. Default is UNFILTERED.
#
# EXIT CODES
#   0  every repo's positive control passed (hit count may be 0 — and can be believed)
#   2  incomplete discovery or failed positive control — cannot certify corpus coverage
#   3  usage error

set -uo pipefail

MODE=-F
CASE=()
MAX_BYTES=${SWEEP_MAX_BYTES:-5000000}
DEPTH=${SWEEP_DEPTH:-0}  # 0 = unlimited; a positive limit is explicitly incomplete
PATTERN=""
GLOBS=()
FILTER_DESC='none (all text files)'
EXCLUDE_STD=--exclude-standard
IGNORED_DESC='gitignored files EXCLUDED (default)'

# Where written claims live: prose, code, config, notebooks. Deliberately excludes
# vendored asset blobs (.svg path data, minified .js) that produce numeric noise.
DOC_GLOBS=('*.md' '*.markdown' '*.txt' '*.rst' '*.org' '*.tex'
           '*.tsv' '*.csv' '*.json' '*.yaml' '*.yml' '*.toml' '*.cfg' '*.ini'
           '*.py' '*.R' '*.r' '*.sh' '*.bash' '*.pl' '*.jl' '*.ipynb'
           '*.sbatch' '*.smk' 'Snakefile' 'Makefile' '*.html')

# Print the USAGE..EXIT CODES block of this header. Derived from the file, so it
# cannot drift out of sync with the options above it.
usage() {
  awk '/^# USAGE/,/^# +3 +usage error/ { sub(/^# ?/,""); print }' "$0" >&2
  exit "${1:-3}"
}

while (($#)); do
  case "$1" in
    -F|-E) MODE=$1; shift ;;
    -i) CASE=(-i); shift ;;
    --docs) GLOBS+=("${DOC_GLOBS[@]}"); FILTER_DESC='--docs (prose/code/config)'; shift ;;
    --include) GLOBS+=("$2"); FILTER_DESC="--include ${GLOBS[*]}"; shift 2 ;;
    --include-ignored) EXCLUDE_STD=''; IGNORED_DESC='gitignored files INCLUDED'; shift ;;
    --max-bytes) MAX_BYTES=$2; shift 2 ;;
    --depth) DEPTH=$2; shift 2 ;;
    -h|--help) usage 0 ;;
    --) shift; PATTERN=${1:-}; shift; break ;;
    -*) printf 'sweep: unknown option %s\n' "$1" >&2; usage ;;
    *) if [[ -z $PATTERN ]]; then PATTERN=$1; shift; else
         printf 'sweep: unexpected extra argument %s\n' "$1" >&2; usage; fi ;;
  esac
done
[[ -n $PATTERN ]] || usage
case $MAX_BYTES in ''|*[!0-9]*) echo 'sweep: --max-bytes must be nonnegative' >&2; usage ;; esac
case $DEPTH in ''|*[!0-9]*) echo 'sweep: --depth must be nonnegative (0 = unlimited)' >&2; usage ;; esac

# Sweep root = toplevel of the repo containing this script.
ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "sweep: not inside a git repo" >&2; exit 3; }
cd "$ROOT" || exit 3

# Optional name filter, compiled once into a find expression.
NAME_EXPR=''
if ((${#GLOBS[@]})); then
  for g in "${GLOBS[@]}"; do NAME_EXPR+=" -name $(printf '%q' "$g") -o"; done
  NAME_EXPR="\\( ${NAME_EXPR% -o} \\)"
fi

# --- repo discovery -----------------------------------------------------------
# Discover without an implicit depth cap, and propagate traversal errors. Controls over the
# repos we happened to discover cannot validate discovery itself. Prune root .git too, rather
# than walking its object store (the old -mindepth 2 prevented that prune).
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
DEPTH_ARGS=()
[ "$DEPTH" -eq 0 ] || DEPTH_ARGS=(-maxdepth "$DEPTH")
if ! find . "${DEPTH_ARGS[@]+"${DEPTH_ARGS[@]}"}" -name .git -prune -exec dirname {} \; > "$TMP/repos"; then
  echo '!! SWEEP NOT TRUSTWORTHY: repository discovery failed.' >&2; exit 2
fi
REPOS=()
while IFS= read -r r; do REPOS+=("$r"); done < <(
  printf '.\n'
  sort -u "$TMP/repos" | grep -v '^\.$'
)

# --- helpers ------------------------------------------------------------------

# `xargs -r` (run nothing on empty input) is GNU. BSD xargs skips an empty input on its own and
# the older ones reject -r outright, so every sweep on macOS died with "illegal option -- r"
# (2026-09-22 review). Probe once and pass the flag only where it is accepted; where it is
# not, the platform already has the behaviour the flag asks for.
XARGS_R=''
printf '' | xargs -r true >/dev/null 2>&1 && XARGS_R='-r'

# List every eligible file in a repo, NUL-separated, relative to that repo.
# Eligible = (tracked OR untracked-and-not-ignored) AND regular file AND under cap.
repo_files() {
  local repo=$1
  { git -C "$repo" ls-files -z 2>/dev/null
    git -C "$repo" ls-files --others ${EXCLUDE_STD:+$EXCLUDE_STD} -z 2>/dev/null
  } | (cd "$repo" && xargs -0 $XARGS_R sh -c \
        'find "$@" -maxdepth 0 -type f ! -size +'"${MAX_BYTES}"'c '"$NAME_EXPR"' -print0 2>/dev/null' _)
}

# Count eligible files that the scan will SKIP AS BINARY. scan() passes -I
# --binary-files=without-match, so a file grep considers binary contributes no hits and no
# error -- it just is not searched, and until 2026-08-30 it was not counted either.
#
# THIS IS NOT A THEORETICAL GAP. The handover archive's README.md on the lab store is plain
# prose with mangled UTF-8 em-dashes; grep classifies it as binary, so a sweep for "three
# repositories" over it returned a clean zero while the phrase was sitting on line 11.
# A `grep` shell FUNCTION is worse still -- on such a file it prints nothing at all, not
# even the "binary file matches" line /usr/bin/grep gives you.
#
# A file skipped this way is indistinguishable from a file that was searched and did not match,
# which is the exact confusion this whole script exists to remove. So count it and print it.
# Use `-m1 ''` rather than `-qI .`: the latter also rejects a file with no matching line, so an
# empty or blank-only text file would be miscounted as binary.
# Would the SEARCH refuse to print matching LINES from this file? Two causes, and grep's own
# behaviour is the spec: a NUL byte, or a byte sequence that is invalid in the active locale.
# Such a file yields "binary file matches" instead of the line, so a hit in it is invisible.
#
# EVERY OBVIOUS PROBE LIES HERE. `grep -qI .`, `grep -I -m1 ''` and friends all report "text"
# for a file with one bad byte, because -q/-m1 short-circuit on the first match before grep has
# read far enough to classify the file. Measured, not assumed. So ask the bytes directly.
is_unsearchable() {
  local f=$1 n_all n_nonul enc
  [ -s "$f" ] || return 1                       # empty is not binary, it is empty
  n_all=$(wc -c < "$f" 2>/dev/null) || return 1
  n_nonul=$(tr -d '\000' < "$f" 2>/dev/null | wc -c) || return 1
  [ "$n_all" -ne "$n_nonul" ] && return 0       # holds a NUL
  enc=${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}
  case $enc in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
      command -v iconv >/dev/null 2>&1 || return 1
      iconv -f UTF-8 -t UTF-8 < "$f" >/dev/null 2>&1 || return 0 ;;
  esac
  return 1
}

repo_binary() {
  local repo=$1 f n=0
  while IFS= read -r -d '' f; do
    is_unsearchable "$repo/$f" && ((n++))
  done < <(repo_files "$repo")
  printf '%d' "$n"
}


# Count files excluded purely because of the size cap (reported, never silent).
repo_oversize() {
  local repo=$1
  { git -C "$repo" ls-files -z 2>/dev/null
    git -C "$repo" ls-files --others ${EXCLUDE_STD:+$EXCLUDE_STD} -z 2>/dev/null
  } | (cd "$repo" && xargs -0 $XARGS_R sh -c \
        'find "$@" -maxdepth 0 -type f -size +'"${MAX_BYTES}"'c '"$NAME_EXPR"' -print 2>/dev/null' _) | wc -l
}

# The real grep BINARY. `grep` may be a shell function wrapping a
# ugrep-compatible front-end with --ignore-files, and `command grep` is a shell
# builtin construct that xargs cannot exec. Resolve the executable once.
GREP_BIN=$(type -P grep) || { echo "sweep: no grep on PATH" >&2; exit 3; }

# Run the real scan. Same code path used by the search and by the control.
scan() {
  local repo=$1 mode=$2 pat=$3
  repo_files "$repo" | (cd "$repo" && xargs -0 $XARGS_R \
    "$GREP_BIN" -nHI --binary-files=without-match "${CASE[@]+"${CASE[@]}"}" "$mode" -e "$pat" 2>/dev/null)
}

# Derive a positive control from the repo's own content: the longest line (20..200
# chars) among the first 200 lines of a readable text file.
#
# IT YIELDS SEVERAL CANDIDATES, NOT ONE, and skips anything carrying a non-printable byte.
# Both matter, and both came from a real false alarm: in a small repo the first eligible file
# happened to be a deliberately malformed one, grep classified it as binary during the SEARCH
# while the control had already lifted a line out of it, and the sweep reported NOT TRUSTWORTHY
# for a repo it had searched perfectly well. A control that can fail for reasons unrelated to
# coverage teaches its reader to ignore it -- the same disease as a monitor that cries wolf.
# So: exclude what the REPORTER would call binary, using its own predicate, and only fail the
# repo when EVERY candidate fails to come back.
control_candidates() {
  local repo=$1 f n=0 line
  while IFS= read -r -d '' f; do
    # EXACTLY the predicate repo_binary counts with -- not a lookalike. If the control used a
    # different binary test than the reporter, the two could disagree about the same file, which
    # is how this went wrong the first time. One predicate, used in both places.
    is_unsearchable "$repo/$f" && continue
    line=$(LC_ALL=C head -n 200 -- "$repo/$f" 2>/dev/null \
      | LC_ALL=C awk 'length($0)>=20 && length($0)<=200 { if (length($0)>length(best)) best=$0 } END { print best }')
    [[ -n $line ]] || continue
    printf '%s\t%s\0' "$f" "$line"
    n=$((n+1)); (( n >= 5 )) && return 0
  done < <(repo_files "$repo")
  (( n > 0 ))
}

# --- sweep --------------------------------------------------------------------
printf '=== SWEEP %s %q ===\n' "$MODE" "$PATTERN"
printf 'root=%s  repos=%d  size-cap=%s bytes\nfilter=%s\nscope=%s\n\n' \
  "$ROOT" "${#REPOS[@]}" "$MAX_BYTES" "$FILTER_DESC" "$IGNORED_DESC"

if [ "$DEPTH" -eq 0 ]; then echo 'discovery depth=unlimited'
else echo "discovery depth=$DEPTH — INCOMPLETE scope; deeper repos may not have been discovered"; fi
hits_file="$TMP/hits"
total_hits=0; total_files=0; total_skipped=0; total_binary=0; control_failures=0
declare -a ROWS=()

for repo in "${REPOS[@]}"; do
  disp=${repo#./}; [[ $disp == "." ]] && disp="<root>"

  nfiles=$(repo_files "$repo" | tr -dc '\0' | wc -c)
  nskip=$(repo_oversize "$repo")
  nbin=$(repo_binary "$repo")

  if (( nfiles == 0 )); then
    ROWS+=("$(printf '%-30s %7s %7s %7s  %s' "$disp" 0 "$nskip" "$nbin" 'NO ELIGIBLE FILES — nothing scanned')")
    ((control_failures++))
    total_skipped=$((total_skipped + nskip))
    continue
  fi

  # positive control, through the same scan(). Try each candidate; one hit proves the repo
  # was reached, and only an all-candidates miss is a real coverage failure.
  ctl_status='CONTROL FAILED'
  ctl_n=0
  while IFS= read -r -d '' ctl; do
    ctl_n=$((ctl_n+1))
    ctl_line=${ctl#*$'\t'}
    # Test the OUTPUT, not the pipeline status: xargs exits 123 whenever any of its
    # grep batches finds nothing, so under `pipefail` a status-based test reports
    # CONTROL FAILED on exactly the large repos this tool exists to cover.
    if [[ -n $(scan "$repo" -F "$ctl_line" | head -n 1) ]]; then
      ctl_status='ok'
      break
    fi
  done < <(control_candidates "$repo")
  (( ctl_n == 0 )) && ctl_status='CONTROL UNAVAILABLE (no readable text file)' 
  [[ $ctl_status == ok ]] || ((control_failures++))

  # the actual search
  n=0
  while IFS= read -r line; do
    printf '%s/%s\n' "$disp" "$line" >>"$hits_file"
    ((n++))
  done < <(scan "$repo" "$MODE" "$PATTERN")

  ROWS+=("$(printf '%-30s %7d %7d %7d  %s' "$disp" "$nfiles" "$nskip" "$nbin" "$ctl_status")")
  total_hits=$((total_hits + n))
  total_files=$((total_files + nfiles))
  total_skipped=$((total_skipped + nskip)); total_binary=$((total_binary + nbin))
done

if (( total_hits )); then
  echo "--- HITS ---"
  cat "$hits_file"
  echo
fi

printf '%-30s %7s %7s %7s  %s\n' "REPO" "FILES" "OVERCAP" "BINARY" "CONTROL"
printf '%s\n' "${ROWS[@]}"
printf '\n%d hit(s) across %d files in %d repos; %d file(s) skipped over the %s-byte cap.\n' \
  "$total_hits" "$total_files" "${#REPOS[@]}" "$total_skipped" "$MAX_BYTES"
if (( total_binary )); then
  printf '%d file(s) were NOT SEARCHED because grep classifies them as binary — a zero above\n' "$total_binary"
  printf 'says nothing about them. Plain prose with one mangled byte lands here.\n'
  printf 'Check with: grep -aI -c PATTERN <file>, or read it directly.\n'
fi
[[ $FILTER_DESC == 'none (all text files)' ]] \
  || printf 'NARROWED BY filter=%s — files outside it were NOT searched.\n' "$FILTER_DESC"

if [ "$DEPTH" -gt 0 ]; then
  echo '!! SWEEP NOT TRUSTWORTHY: bounded discovery cannot certify absence in deeper repos.' >&2
  exit 2
fi
if (( control_failures )); then
  cat >&2 <<EOF

!! SWEEP NOT TRUSTWORTHY: $control_failures repo(s) failed their positive control.
!! A zero-hit result above does NOT mean the claim is absent — it means those repos
!! were not searched. Fix the coverage before reporting the sweep as clean.
EOF
  exit 2
fi

printf 'CONTROL: all %d repos verified reachable — a zero here can be trusted.\n' "${#REPOS[@]}"
exit 0
