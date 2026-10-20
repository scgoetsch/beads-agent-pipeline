#!/usr/bin/env bash
# store-cli-harness-hooks.sh — make the agent-harness hooks that run bd directly stop under cairn.
#
# bd 1.3's `bd init` (and `bd setup <harness>`) writes hooks that call bd itself into the
# harnesses' config: a SessionStart `bd prime --hook-json` in .claude/settings.json, `bd codex-hook
# <event>` in .codex/hooks.json, `bd cursor-hook <event>` in .cursor/hooks.json. With
# .claude/store-cli = cairn bd's store is frozen, and each of those would put the frozen store into
# the session as if it were current. The prerun hook cannot stop them: it sees typed Bash calls,
# not hooks (workspace-7m8.22). This prefixes every hook command whose first word is `bd` with a
# test that skips it under cairn and does nothing otherwise, so the hook follows the switch both
# ways and a rollback needs no restore. The pipeline's own hooks (scripts) are left alone.
# Idempotent; .claude/settings.local.json is covered when it exists.
#
#   tools/store-cli-harness-hooks.sh           guard where missing; prints what it changed
#   tools/store-cli-harness-hooks.sh --check   exit 1 and name the unguarded hooks (changes nothing)
#
# Run it before writing `cairn` into .claude/store-cli, and again after any `bd init` or `bd setup`.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
check=0; [ "${1:-}" = --check ] && check=1
python3 - "$check" .claude/settings.json .claude/settings.local.json .codex/hooks.json .cursor/hooks.json <<'PY'
import json, os, re, sys

check = sys.argv[1] == "1"
# Codex and Cursor do not set CLAUDE_PROJECT_DIR; the git top level (or the cwd) is the repo.
# stderr is redirected before the input, so a missing switch file reads as "" (bd) in silence.
GUARD = ('[ "$(tr -d \' \\t\\r\\n\' 2>/dev/null < "${CLAUDE_PROJECT_DIR:-$(git rev-parse '
         '--show-toplevel 2>/dev/null || pwd)}/.claude/store-cli")" = cairn ] || ')
BD = re.compile(r"^\s*bd(\s|$)")
bad = 0
for path in sys.argv[2:]:
    if not os.path.isfile(path):
        continue
    raw = open(path, encoding="utf-8").read()
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        print(f"store-cli-harness-hooks: {path} is not JSON ({exc}); not touched", file=sys.stderr)
        bad = 1
        continue
    changed = []
    # Claude and Codex: {"hooks": {event: [{"matcher": .., "hooks": [{"command": ..}]}]}};
    # Cursor: {"hooks": {event: [{"command": ..}]}}.
    for event, groups in (doc.get("hooks") or {}).items():
        for group in groups if isinstance(groups, list) else []:
            entries = group.get("hooks") if isinstance(group.get("hooks"), list) else [group]
            for entry in entries:
                cmd = entry.get("command")
                if not isinstance(cmd, str) or not BD.match(cmd):
                    continue
                changed.append(f"{event}: {cmd.strip()}")
                entry["command"] = GUARD + cmd.strip()
    if not changed:
        continue
    for what in changed:
        if check:
            print(f"store-cli-harness-hooks: {path} {what} runs bd under cairn", file=sys.stderr)
        else:
            print(f"store-cli-harness-hooks: {path} {what} now stops under cairn")
    if check:
        bad = 1
        continue
    text = json.dumps(doc, indent=2, ensure_ascii=False) + ("\n" if raw.endswith("\n") else "")
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)
sys.exit(bad)
PY
