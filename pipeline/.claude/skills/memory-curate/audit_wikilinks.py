#!/usr/bin/env python3
"""Repair dangling [[wikilinks]] in the bd memory store.

REPOINT: only where a successor memory demonstrably carries the same claim.
DE-LINK: everywhere else -- `[[x]]` -> `x (memory pruned)`, preserving the
         historical name while removing the false navigation promise.
Issue refs ([[ab-1234]]) are a valid cross-namespace pointer and are left alone. The prefix
comes from the store itself (`bd config get issue_prefix`); this script refuses to run without it.
"""
import json, re, subprocess, sys

APPLY = '--apply' in sys.argv


def issue_prefix():
    """The bd issue prefix of THIS store, or exit. Links to issues are pointers into the issue
    namespace, not dangling memory links, so they are skipped rather than repaired -- and a wrong
    prefix here de-links every issue reference in the store on --apply. This used to be the
    constant 'WS', the prefix of the workspace it was written in; the first other store it was
    run against had a different one. Never guess it."""
    r = subprocess.run(['bd', 'config', 'get', 'issue_prefix'], capture_output=True, text=True)
    p = r.stdout.strip()
    if r.returncode != 0 or not p or 'not set' in p:
        sys.exit("audit_wikilinks: cannot read this store's issue prefix "
                 "(`bd config get issue_prefix` gave: %r). Refusing to guess -- a wrong prefix "
                 "would de-link every [[issue]] reference. Run this inside the bd project." % p)
    return p


ISSUE_PREFIX = issue_prefix()

# successor verified to carry the cited claim -> (target, evidence)
#
# THIS TABLE IS DELIBERATELY EMPTY. Fill it in for the repair you are actually doing, run
# without --apply to see the plan, then re-run with --apply. Each entry is a claim you have
# CHECKED: that the target memory really does carry what the dangling link promised. Never
# repoint on name similarity -- a link that points somewhere plausible but wrong is worse
# than one that is visibly broken, because nothing will ever flag it again.
#
# Example of the shape:
#   'old-key-that-no-longer-exists':
#       ('successor-key', 'states the same threshold, with the measurement that settled it'),
REPOINT = {}

d = json.loads(subprocess.run(['bd', 'memories', '--json'],
                              capture_output=True, text=True).stdout)
d.pop('schema_version', None)
keys = set(d)

edits = {}   # key -> (new_body, [notes])
for k, v in d.items():
    new, notes = v, []
    # link syntax written as inline code (`[[key]]`) is documentation, not a link
    scanned = re.sub(r'`[^`]*`', '', v)
    for link in sorted(set(re.findall(r'\[\[([^\]]+)\]\]', scanned))):
        if link in keys or link.startswith(ISSUE_PREFIX + '-'):
            continue
        if link in ('wikilink', 'wikilinks'):                     # prose, not a link
            new = new.replace(f'[[{link}]]', f'`{link}`')
            notes.append(f'prose  {link} -> backticks')
        elif link in REPOINT and REPOINT[link][0] != k:           # never self-link
            tgt = REPOINT[link][0]
            new = new.replace(f'[[{link}]]', f'[[{tgt}]]')
            notes.append(f'REPOINT {link} -> {tgt}')
        else:
            new = new.replace(f'[[{link}]]', f'{link} (memory pruned)')
            notes.append(f'delink {link}' + (' [self-ref]' if link in REPOINT else ''))
    if new != v:
        edits[k] = (new, notes)

print(f'{len(edits)} memories to edit\n')
for k, (_, notes) in sorted(edits.items()):
    print(f'{k}')
    for n in notes:
        print(f'    {n}')

if not APPLY:
    print('\n(dry run — pass --apply to write)')
    sys.exit(0)

for k, (body, _) in sorted(edits.items()):
    r = subprocess.run(['bd', 'remember', '--key', k, body],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f'FAILED {k}: {r.stderr[:200]}')
        sys.exit(1)
print(f'\napplied to {len(edits)} memories')
