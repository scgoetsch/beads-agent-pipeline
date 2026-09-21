# Why a bare recursive grep misses your corpus

**Every search tool in a modern agent workspace fails by returning zero, never by erroring.**
That is the whole problem. A search that was never performed and a search that found nothing look
identical, and only one of them licenses the conclusion "it isn't there".

## The mechanism

If your root `.gitignore` lists nested project repos — normal when they have their own remotes —
then every gitignore-aware front-end skips them by default:

- `rg` (ripgrep) honours `.gitignore` natively, and so does any agent harness tool that wraps it.
- A `grep` shell function passing `--ignore-files` does the same.

Measured in one such workspace on 2026-09-21: `rg` from the root reached **131 files**. The
corpus was **8,993 files across 7 git repos**. So a root sweep covered about 1.5% of it and
reported ZERO HITS.

**Re-measure in your own tree, and never pin an absolute count.** The *ratio* is the durable
claim. That same workspace read 72 files at the root six weeks earlier: the number moved because
the root repo grew, not because the hazard changed. The suite originally asserted "rg saw < 100
files", and on the day the root repo crossed 100 the assertion silently inverted — the test went
red while the thing it guards was exactly as broken as before. A check that fails on its own
growth teaches people to ignore it.

This bites hardest during a **correction sweep**: when a claim turns out to be wrong, you grep the
distinctive number and the distinctive phrase across every sibling document to find where else it
lives. Run from the repo root, that step is silently a no-op, and the wrong claim survives in the
documents you did not search.

## What `tools/sweep.sh` does differently

1. **Enumerates every git repo under the root** and scans each separately, so no `.gitignore` can
   hide a whole repo.
2. **Scans tracked AND untracked-but-not-ignored files.** A repo with no commits at all has zero
   tracked files and is invisible to a `git grep` sweep.
3. **Runs a positive control per repo.** It lifts real lines out of real files in that repo and
   greps for them through the identical code path. If none come back, the repo was not actually
   searched: the sweep exits non-zero and says so. *A zero-hit result is only trustworthy when
   every control passed.*
4. **Reports files skipped for size and files skipped as binary**, so neither exclusion is silent.

## Read the exit code and the BINARY column

- Exit **0** — every per-repo positive control passed, so a zero-hit result can be believed.
- Exit **2** — at least one repo was not searched, and the zero means nothing.
- The **BINARY** column counts files whose bytes stop grep printing matching lines. Plain prose
  carrying one malformed byte lands here: the file looks fine in an editor, and the sweep cannot
  show you hits inside it. Check those directly with `grep -aI -c PATTERN <file>`.

So **report which it was**. "Swept clean" is a claim you can only make after an exit-0 run, and you
should say what the sweep could not reach.

## What it still does not reach

- Claims rendered into **figures** (PNG/PDF pixels). No text search reaches those.
- Files gitignored *inside* a repo — excluded by default because that is usually where bulk data
  lives. Pass `--include-ignored`.
- Files over the size cap (printed; raise with `--max-bytes`).
- **The bd layer.** Memories and issue text are separate `bd memories` / `bd list` searches. A
  document sweep is not a corpus sweep.

This is one instance of a defect class that recurs across subsystems; the catalogue is
[checks-narrower-than-what-they-check.md](checks-narrower-than-what-they-check.md).

## Traps found while building the positive control

Both are worth knowing if you touch this tool:

- **`grep -q` cannot be used to ask whether a file is binary.** `-q` and `-m1` short-circuit on the
  first match, before grep has read far enough to classify the file — so a prose file with one bad
  byte is reported as text, which is exactly the case the BINARY column exists to report. Ask the
  bytes directly instead (NUL present, or invalid in the active locale).
- **Assert the denominator before you trust a ratio.** The suite measures "what fraction of the
  corpus can `rg` see from the root". A corpus measure that silently returned ~0 would satisfy any
  ratio trivially — a guard weaker than the check it gates, one level down. So the corpus size is
  asserted first, and both sides are measured with the *same instrument*, so the ratio isolates the
  gitignore effect rather than a difference between two tools. Where there is no multi-repo corpus
  to measure, the check is announced as SKIPPED and counted, never quietly passed.
- **A single-candidate control produces false alarms.** If the one file it lifts its control line
  from happens to be one grep will not print lines from, the control can never be re-found, and the
  sweep cries "NOT TRUSTWORTHY" about a repo it searched perfectly well. It tries several
  candidates and only fails the repo when all of them miss.

Acceptance suite: `tools/sweep_test.sh`. It builds its corpus at runtime — a root repo whose
`.gitignore` hides a nested repo holding the canary — so it proves the property on any machine and
cannot drift as your tree grows.
