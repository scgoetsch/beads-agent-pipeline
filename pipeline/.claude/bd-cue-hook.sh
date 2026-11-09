#!/usr/bin/env bash
# Related-work cue: when a prompt names an issue, or a command claims one, print pointers to
# the earlier issues and the memories `cairn search` ranks highest for that issue's text.
#
# Why (cairn workspace-d3ct, measured on the home workspace store, 2026-11-09):
#   * the memories the session starts with (the hot tier) held a memory the issue needed for
#     19% of issues; `cairn search` over the issue's own text found it in its top 10 for 75%;
#   * the first real query surfaced an unlinked earlier issue with the same failure and a prior
#     root-cause investigation that nothing pointed to.
# Pointers, not bodies: no score threshold separated relevant from irrelevant hits (top-3
# precision 30%; the title alone as the query did worse than title and description), so a
# wrong hit must stay cheap -- one line, and the agent decides whether
# to `cairn show` / `cairn recall` it. Hot-tier memories are left out: their bodies are
# already in context.
#
# Events: UserPromptSubmit (the prompt names an issue: a full id, or a bare suffix such as
# "zd8s" that is an issue in this store) and PostToolUse on Bash (`cairn update <id> --claim`,
# `--status in_progress`, `cairn ready --claim`). Once per issue per session. Silent on any
# failure and on a cairn without `search` (before 0.8.0): this hook only ever adds context.
# BD_CUE=0 turns it off; BD_CUE_ISSUES / BD_CUE_MEMORIES set how many pointers (default 3).
# Root from this file's location, not a literal (see bd-prime-hook.sh). Open, but not silent.
WS=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)
if [ -z "$WS" ] || ! cd "$WS"; then
    echo "⚠ bd-cue-hook: cannot resolve the workspace from '${BASH_SOURCE[0]}' — no related-work pointers." >&2
    exit 0
fi
[ "${BD_CUE:-1}" = "0" ] && exit 0
command -v cairn >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
BD_CUE_INPUT=$(cat) || exit 0
export BD_CUE_INPUT
GITDIR=$(git rev-parse --absolute-git-dir 2>/dev/null) || GITDIR=""
export BD_CUE_STATE="${BD_SESSION_CLAIMS_DIR:-${GITDIR:+$GITDIR/bd-session-claims}}"
: "${BD_CUE_STATE:=${TMPDIR:-/tmp}/bd-session-claims-$(id -u)}"
exec python3 - <<'PY'
import json, os, re, subprocess, sys

def cairn(*args):
    try:
        p = subprocess.run(["cairn", *args], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout if p.returncode == 0 else None

try:
    data = json.loads(os.environ.get("BD_CUE_INPUT") or "{}")
except ValueError:
    sys.exit(0)
event = data.get("hook_event_name") or ""
session = re.sub(r"[^A-Za-z0-9._-]", "_", str(data.get("session_id") or ""))[:128]

FULL = re.compile(r"(?<![\w.-])([a-z][a-z0-9_]*(?:-[a-z0-9_]+)*-[0-9a-z]{2,10}(?:\.\d+)*)(?![\w-])")
BARE = re.compile(r"(?<![\w./-])([0-9a-z]{3,8}(?:\.\d+)*)(?![\w/-])")
cands = []
if event == "UserPromptSubmit":
    text = str(data.get("prompt") or "")[:4000]
    prefix = ""
    try:
        with open(".cairn/config.json", encoding="utf-8") as fh:
            prefix = json.load(fh).get("prefix") or ""
    except (OSError, ValueError):
        pass
    cands = [m.group(1) for m in FULL.finditer(text.lower())]
    if prefix:
        for m in BARE.finditer(text.lower()):
            s = m.group(1)
            base = s.split(".")[0]
            # a suffix has a digit and a letter ("zd8s", "5vi9"); a plain word or number does not
            if re.search(r"\d", base) and re.search(r"[a-z]", base):
                cands.append(f"{prefix}-{s}")
elif event == "PostToolUse":
    cmd = str((data.get("tool_input") or {}).get("command") or "")
    if not re.search(r"\bcairn\b", cmd) or not re.search(
            r"--claim\b|(?:--status|-s)[ \t=]+in_progress\b", cmd):
        sys.exit(0)
    resp = data.get("tool_response")
    out = json.dumps(resp) if not isinstance(resp, str) else resp
    cands = [m.group(1) for m in FULL.finditer(cmd)] + re.findall(r"Updated issue: ([\w.-]+)", out)
else:
    sys.exit(0)
cands = list(dict.fromkeys(cands))[:6]
if not cands:
    sys.exit(0)

state = os.path.join(os.environ.get("BD_CUE_STATE") or "", f"{session}.cued") if session else ""
seen = set()
if state:
    try:
        with open(state, encoding="utf-8") as fh:
            seen = set(fh.read().split())
    except OSError:
        pass
cands = [c for c in cands if c not in seen]
if not cands:
    sys.exit(0)
shown = cairn("show", "--json", *cands)
try:
    issues = json.loads(shown) if shown else []
except ValueError:
    issues = []
issues = [i for i in issues if isinstance(i, dict) and i.get("id")][:2]
if not issues:
    sys.exit(0)

hot = set()
try:
    with open(".claude/memory-hot.txt", encoding="utf-8") as fh:
        hot = {line.strip() for line in fh if line.strip() and not line.startswith("#")}
except OSError:
    pass
def count(name):
    try:
        return max(0, int(os.environ.get(name, "3")))
    except ValueError:
        return 3
n_issues, n_mem = count("BD_CUE_ISSUES"), count("BD_CUE_MEMORIES")

bodies = None
def preview(key):
    """The start of the body: memories open with their thesis; a search snippet is a fragment."""
    global bodies
    if bodies is None:
        out = cairn("memories", "--json")
        try:
            bodies = json.loads(out) if out else {}
        except ValueError:
            bodies = {}
    body = " ".join(str(bodies.get(key) or "").split())
    return body[:110] + ("…" if len(body) > 110 else "")

blocks, cued = [], []
for it in issues:
    query = " ".join(f"{it.get('title') or ''} {it.get('description') or ''}".split())[:2000]
    words = query.split()
    if not words:
        continue
    out = cairn("search", "--json", "-n", "20", "--", *words)
    if out is None:
        continue                    # no search verb (cairn before 0.8.0), or it failed
    try:
        rows = json.loads(out)
    except ValueError:
        continue
    rel_issues = [r for r in rows if r.get("kind") == "issue" and r.get("id") != it["id"]][:n_issues]
    rel_mems = [r for r in rows if r.get("kind") == "memory" and r.get("id") not in hot][:n_mem]
    cued.append(it["id"])
    if not rel_issues and not rel_mems:
        continue
    lines = [f"Related to {it['id']} (cairn search on its text; pointers, ranked, not all relevant —"
             f" read what fits with `cairn show` / `cairn recall`):"]
    for r in rel_issues:
        lines.append(f"  issue  {r['id']} [{r.get('status')}] {str(r.get('title') or '')[:110]}")
    for r in rel_mems:
        lines.append(f"  memory {r['id']} — {preview(r['id'])}")
    blocks.append("\n".join(lines))

if state and cued:
    try:
        os.makedirs(os.path.dirname(state), exist_ok=True)
        with open(state, "a", encoding="utf-8") as fh:
            fh.write("".join(c + "\n" for c in cued))
    except OSError:
        pass
if not blocks:
    sys.exit(0)
text = "\n".join(blocks)[:2500]
if event == "PostToolUse":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                             "additionalContext": text}}))
else:
    print(text)
PY
