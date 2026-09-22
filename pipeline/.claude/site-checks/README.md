# Site checks

Any executable `*.sh` in this directory runs at session start, and **anything it prints becomes
an alarm at the top of the session payload**.

## The contract

**Print nothing when healthy.** A check that chatters every session trains its reader to skip the
block, and is then worthless on the day it has something to say. Exit status is ignored; output is
the signal.

Each check is bounded by `timeout 20` where the box has `timeout` (stock macOS does not; the checks
then run unbounded and the session payload says so). Its exit status is ignored, and **both streams
count as output**: a check that dies with "command not found" on stderr is reported, not skipped.

## What belongs here

Environment facts an agent would otherwise act on wrongly, and cannot discover on its own:

- a network mount that is down, so reads hit a stale local directory that looks plausible
- a backup or sync job whose last run failed
- a service the repo's tooling assumes is up

## Example

```bash
#!/usr/bin/env bash
# mount-check.sh — silent unless the data mount is missing.
mountpoint -q /data && exit 0
echo "!! /data IS NOT MOUNTED — reads there hit an empty local directory, not the dataset."
echo "   fix: sudo mount /data"
```

Make it executable (`chmod +x`) or it will not run.

## A warning, learned the hard way

Gate a check on evidence that the thing it watches is **supposed to exist here**. A check written
for one machine, shipped in a repo everyone clones, will fire on every other machine — where "it
isn't there" is the correct state, not a fault. Test for the marker that says this host owns the
resource (an installed unit file, a config, a mount entry), not merely for absence.
