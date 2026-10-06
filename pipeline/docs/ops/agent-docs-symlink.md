# One agent doc, two names: the CLAUDE.md → AGENTS.md symlink

`CLAUDE.md` is a **symlink** to `AGENTS.md`. They are not two files kept in sync; they are one
file with two names, so they cannot drift. Git stores the link itself (mode `120000`), so every
clone gets it without anyone running anything.

## Why a symlink and not two files

Because two files drift, silently, and you find out months later. In the workspace this came from,
`CLAUDE.md` and `AGENTS.md` were separate files that had **diverged by about 180 lines** before
anyone noticed — and the section missing from the copy one tool read was the correction-sweep
protocol, i.e. the rule for keeping claims consistent had itself gone inconsistent.

A "sync them in a hook" approach has the same defect one level up: the hook is another thing that
can be skipped, and `--no-verify` exists.

## Why that direction

`AGENTS.md` is the real file and `CLAUDE.md` points at it, not the other way round:

- `AGENTS.md` is the tool-neutral name, so the content is not owned by one vendor's convention.
- `CLAUDE.md` is one consumer of it. If you later add another agent's filename, you add another
  symlink to the same target rather than choosing a new source of truth.

Nothing breaks if you prefer the opposite direction, but `tools/check-agent-docs-linked.sh`
asserts this one specifically — it checks the link's *target*, not just that a link exists.

## What breaks it

1. **A writer that replaces the file instead of writing through it.** Write-to-temp-then-rename is
   the common editor and tooling pattern, and it turns the symlink into a regular file with no
   error. A `bd setup claude` run can do it too.
2. **A checkout without symlink support.** On Windows without Developer Mode (or with
   `core.symlinks=false`), and on some network and container mounts, git materialises the link as
   a small regular file whose entire content is the text `AGENTS.md`. Nothing warns you. That
   form is git's own, and the guard accepts it when git agrees it is a link — see below.

Both land in the same state — two independent documents — which is why the guard tests for *is a
symlink*, and `cat CLAUDE.md` tells you which case you are in: one line reading `AGENTS.md` means
the checkout case.

## The guard

`tools/check-agent-docs-linked.sh` runs from `.beads-hooks/pre-commit` (via `core.hooksPath`) and
on demand. On commit it receives `--cached` and checks the index's modes, symlink target and
`AGENTS.md` content; without that flag it checks the working tree. A clean working copy cannot
launder a bad staged link, and an unstaged edit does not reject a clean staged version. It asserts:

- `CLAUDE.md` is a symlink, not a regular file;
- it points at `AGENTS.md` specifically;
- and, if `AGENTS.md` contains a `BEGIN BEADS INTEGRATION` region, that your own protocol is not
  sitting **inside** it — because `bd setup` regenerates that region and would destroy whatever is
  there. That check is a size cap rather than a keyword list, on purpose: a keyword blocklist only
  catches wording somebody already thought of, and a section titled "Corrections protocol" using
  none of the listed words sailed straight through the earlier version.

It exits 0 when neither name is present — there is nothing to enforce until one exists. Note
that a **dangling** link does not count as absent: `[ -e ]` follows the link and is false for a
broken one, so testing only `[ -e CLAUDE.md ]` would pass the exact state the guard exists to
catch. That was a real bug, and it survived because this was once the only guard in `tools/`
without a `_test.sh` beside it.

Its suite is `tools/check-agent-docs-linked_test.sh`: all four link states, the pointer-file
state, both nothing-to-enforce cases, and the bd-managed-region check. It builds a throwaway root under
`mktemp`, so it never touches your working tree and is safe to run with work in progress.

## Recovering

The regular file may hold edits the symlink target lacks, so **reconcile before restoring**:

```bash
diff CLAUDE.md AGENTS.md          # fold anything worth keeping into AGENTS.md
rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md
```

The installer refuses to touch a `CLAUDE.md` that is a regular file, for the same reason — it
cannot know whether that file is a stale copy or the only place your edits live.

## If your filesystem has no symlinks

The installer handles it. Git Bash's `ln -s` **copies** the target by default and reports
success, which is the two-files drift with no error; the installer runs it with
`MSYS=winsymlinks:nativestrict`, so it makes a real symlink where Windows allows one (Developer
Mode, or an elevated shell) and otherwise takes the fallback: it writes git's own on-disk form of
the link — `CLAUDE.md` is a regular file whose entire content is `AGENTS.md` — and stages it as a
symlink (`git update-index --cacheinfo 120000,…`), so the **commit carries a real symlink** and
every clone on a box with symlinks gets one. The guard accepts that state when git agrees it is a
link: the index entry is mode 120000, or the checkout says `core.symlinks=false`. The content must
be the name and nothing else; a copy of `AGENTS.md` under that name is still caught.

To get real links on Windows instead:

```bash
git config --global core.symlinks true   # needs Developer Mode or an elevated shell
```

then re-clone or `git checkout -- CLAUDE.md`. Checking out an existing clone will not convert an
already-materialised regular file back into a link by itself.

Whatever you do, **do not keep two real files** — that is the drift this whole mechanism exists
to prevent. If you would rather have one name, keep `AGENTS.md` only, delete `CLAUDE.md`, and
point your agent at `AGENTS.md`: the guard exits 0 when `CLAUDE.md` is absent, so nothing nags you,
and there is exactly one document.
