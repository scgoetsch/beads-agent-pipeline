# The recurring defect: a check whose scope is narrower than what it verifies

Every guard in this repo exists because of this one shape. A verification whose SCOPE is narrower
than the thing it verifies, failing **silently** rather than loudly. In each case a check *was*
present, which is why nobody looked.

**The test to apply:** *"if this failed right now, would this check EMIT anything?"* If not, widen
it. Prefer state-based signals (files on disk, byte counts, job state) over identity-based ones
(job ids, pids, first rows).

The instances below were collected in one working tree over a few months. They are in different
subsystems and were each found the expensive way.

---

### 1. The first row read as the whole

`status -j <id> | head -1` on a 21-task batch array reported the FIRST task's state as the array's.
A still-running job was recorded as complete; it then raced a second job writing the same paths.

**Fix:** aggregate, don't sample. `... | sort | uniq -c`.

### 2. An existence test guarding a checksum

`[ ! -s "$FILE" ]` in front of an md5 check. A **truncated** download is non-empty, so the guard
accepted it and skipped the re-fetch; the checksum then failed terminally instead of repairing.
The truncated file passed a `gzip -t` integrity test too.

**Fix:** verify against size or checksum, never mere existence — and make a failed checksum
trigger repair rather than abort. Ask what a guard actually rules out, and whether a check that can
only fail the job, never repair it, is worth having.

### 3. A monitor scoped to hardcoded ids

Went blind the moment the work was resubmitted under new ids, and reported a confident "queue
empty".

**Fix:** monitor on state that SURVIVES the operation you are performing — a name, a path, a
pattern — not an identity the operation replaces.

### 4. A cohort defined negatively

"Everything that isn't X" quietly grew a third category nobody had named, and it was reported as
part of the comparison group.

**Fix:** name cohorts explicitly and report anything belonging to none.

### 5. `pgrep -f` matching the monitor's own process

The pattern appears on the command line of the shell running it, so the check matches itself.
As a monitor it reads as "still running" forever; as a `pkill` it kills its own caller. The latter
is guarded in `.claude/bd-prerun-hook.sh`.

**Fix:** never match a pattern that appears in your own process. Use an age filter or a pidfile.

### 6. A flag that is accepted and silently ignored

A CLI took an option, printed no error, and did not apply it. Every downstream number was computed
without the setting the operator believed was on.

**Fix:** verify the flag's EFFECT on a case where its presence and absence must differ. An
accepted flag is not an applied flag.

### 7. A log-content monitor blind to a job that dies without logging

It watched for error strings. A process killed by the OOM killer writes nothing, so the monitor
reported healthy right up to the end.

**Fix:** monitor JOB STATE, not just log content, and emit something on every poll — including
"still running" — so silence is never ambiguous.

### 8. A correction sweep whose grep could not see the corpus

The sharpest instance, because **the check that failed silently was the correction protocol
itself** — the mechanism meant to stop retracted claims from reseeding. A bare recursive grep from
the root skipped every gitignored nested repo and reported ZERO HITS. Measured: 131 files reached
at the root against a corpus of 8,993 across 7 repos.

**Fix:** `tools/sweep.sh` — per-repo scan, tracked *and* untracked files, and a positive control
per repo so a zero that cannot be trusted exits non-zero. See
[why-a-bare-grep-misses-the-corpus.md](why-a-bare-grep-misses-the-corpus.md).

### 9. A monitor that cannot tell "finished" from "could not look"

Polling a queue for a job id has a trap at both ends. The naive form exits its wait loop when the
poll produces no output — and a network failure produces no output, so a blip reads exactly like a
finished job. The obvious hardening (retry on non-zero exit) fails the other way, because querying
a job that has aged out of the queue *also* exits non-zero, so a waiter retries a job that finished
hours ago.

**Fix:** poll for a POSITIVE state rather than an absence, from a source that still knows the job
after it leaves the queue. Empty result = could not look; a state = a real answer.

**The general shape: an absence is not evidence unless you can show you were able to observe.**
This is the same rule as the sweep tool's positive control, arrived at independently in a different
subsystem.

### 10. A guard that pinned an absolute threshold, and aged out

The suite for instance 8 asserted `rg saw < 100 files` at the root. When the root repo grew past
100 files, the assertion **silently inverted**: the test went red while the hazard it guards was
exactly as broken as before. It had pinned a count in defence of a document that says the ratio is
the durable claim — so the test contradicted the doc it existed to defend.

**Fix:** assert the RATIO, measure both sides with the SAME instrument, and **assert the
denominator first** — a corpus measure that silently returned ~0 would satisfy any ratio trivially,
which is this same defect one level down.

### 11. A textual assertion standing in for a behavioural one

A suite checked that a function *mentioned* the right command (`grep -c 'systemd-run'`) rather than
running it. It stayed green through the entire life of a bug that made the function abort before it
could report anything.

**Fix:** run the thing. Shim its dependencies and assert on OUTPUT — and check that the exit code
alone would not have told you, because often it is identical in both the broken and fixed cases.

---

## How to add one

When you find an instance, add it here, then check the other guards for the same shape — that is
how instances 8, 9 and 10 were found. A defect class you have named once is cheap to find again.
