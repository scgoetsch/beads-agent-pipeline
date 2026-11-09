#!/usr/bin/env bash
# Acceptance suite for .claude/bd-cue-hook.sh — related-work pointers for the issues a prompt names
# or a command claims.
#
# Runs the real cairn (0.8.0 or later: `cairn search`) on a throwaway store in a temp git repo, with
# the hook copied into its .claude/ so it resolves that root from its own location. Nothing here
# touches a real store. Without cairn, or with a cairn that has no search verb, the cases that need
# it are skipped and the hook must still exit 0 and print nothing.
set -uo pipefail
HOOK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/.claude/bd-cue-hook.sh
[ -f "$HOOK" ] || { echo "missing: $HOOK" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, want %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

mkdir -p "$T/ws/.claude" "$T/claims"
cp -f "$HOOK" "$T/ws/.claude/bd-cue-hook.sh"
export BD_SESSION_CLAIMS_DIR="$T/claims" BEADS_ACTOR="tester/claude/t"
prompt() { jq -cn --arg p "$1" --arg s "${2:-s1}" '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}' \
           | (cd "$T/ws" && bash .claude/bd-cue-hook.sh) 2>/dev/null; }
claimed() { jq -cn --arg c "$1" --arg o "$2" --arg s "${3:-s2}" \
              '{hook_event_name:"PostToolUse",session_id:$s,tool_input:{command:$c},tool_response:{stdout:$o}}' \
           | (cd "$T/ws" && bash .claude/bd-cue-hook.sh) 2>/dev/null; }

echo "### no cairn on PATH: silent, exit 0"
out=$(jq -cn '{hook_event_name:"UserPromptSubmit",session_id:"s0",prompt:"do proj-abc"}' \
      | (cd "$T/ws" && PATH=/usr/bin:/bin bash -c 'command -v cairn >/dev/null && exit 9; bash .claude/bd-cue-hook.sh'); echo "rc=$?")
case $out in *rc=9) echo "  SKIP  cairn is in /usr/bin or /bin" ;; *) chk "silent and exit 0" "$out" "rc=0" ;; esac

if ! command -v cairn >/dev/null 2>&1 || ! cairn search --help >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  the remaining cases need cairn 0.8.0 or later (cairn search) and jq"
  printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit
fi

( cd "$T/ws" && git init -q . && cairn init -p proj >/dev/null 2>&1 ) || { echo "cannot make a scratch store" >&2; exit 2; }
mk() { (cd "$T/ws" && cairn create "$1" -d "$2" --silent 2>/dev/null); }
A=$(mk "Nightly consolidation loop throws on most ticks" "the consolidation loop pre-flight gate fails")
B=$(mk "Consolidation fails again: invalid relationship types" "model emits invalid relationship types in consolidation")
C=$(mk "Landing page copy" "rewrite the hero text")
(cd "$T/ws" && cairn remember --key consolidation-loop-gotchas "The consolidation loop needs the reasoner up; check the probe first." >/dev/null 2>&1
               cairn remember --key landing-deploy "Deploy the landing page through the static host." >/dev/null 2>&1
               cairn remember --key hot-rule "Always relationship consolidation." >/dev/null 2>&1)
printf 'hot-rule\n' > "$T/ws/.claude/memory-hot.txt"
SUFFIX=${B#proj-}

echo "### a prompt naming an issue by its full id"
out=$(prompt "please do $B now")
chk "a cue for it"                            "$(grep -c "^Related to $B " <<<"$out")" 1
chk "the earlier issue with the same failure" "$(grep -c "issue  $A \[open\]" <<<"$out")" 1
chk "the memory, with the start of its body"  "$(grep -c 'memory consolidation-loop-gotchas — The consolidation loop needs' <<<"$out")" 1
chk "not the issue itself"                    "$(grep -c "issue  $B " <<<"$out")" 0
chk "not a hot-tier memory (already in context)" "$(grep -c 'memory hot-rule' <<<"$out")" 0
chk "at most 3 issue pointers"                "$([ "$(grep -c '^  issue ' <<<"$out")" -le 3 ] && echo ok)" ok

echo "### once per issue per session"
chk "same session, same issue: silent"        "$(prompt "$B again" | wc -l | tr -d ' ')" 0
chk "another session: cued again"             "$(prompt "$B again" s9 | grep -c "^Related to $B ")" 1

echo "### a bare suffix, as people type it"
if printf '%s' "$SUFFIX" | grep -q '[0-9]' && printf '%s' "$SUFFIX" | grep -q '[a-z]'; then
  chk "\"do $SUFFIX\" resolves to $B"         "$(prompt "do $SUFFIX" s3 | grep -c "^Related to $B ")" 1
else
  echo "  SKIP  this run's id ($B) has no digit-and-letter suffix"
fi
chk "plain words and numbers name nothing"    "$(prompt 'do 2 and 4 then push v0.2.1 and sha256' s4 | wc -l | tr -d ' ')" 0
chk "an id-shaped word that is no issue: nothing" "$(prompt 'see proj-zzzz9 and beads-agent-pipeline' s4 | wc -l | tr -d ' ')" 0

echo "### a claim (PostToolUse) cues as additionalContext"
out=$(claimed "cairn update $A --claim" "✓ Updated issue: $A")
chk "JSON for the host"                       "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>/dev/null)" PostToolUse
chk "names the claimed issue"                 "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" | grep -c "^Related to $A ")" 1
chk "ready --claim: the id from the output"   "$(claimed 'cairn ready --claim' "✓ Updated issue: $B" s5 | jq -r '.hookSpecificOutput.additionalContext' | grep -c "^Related to $B ")" 1
chk "a command that claims nothing: silent"   "$(claimed "cairn show $A" "" s6 | wc -l | tr -d ' ')" 0

echo "### off switch and a store without matches"
chk "BD_CUE=0: silent"                        "$(jq -cn --arg p "do $C" '{hook_event_name:"UserPromptSubmit",session_id:"s7",prompt:$p}' | (cd "$T/ws" && BD_CUE=0 bash .claude/bd-cue-hook.sh) | wc -l | tr -d ' ')" 0
out=$(prompt "do $C" s8)
chk "its own memory, not the other topic's"   "$(grep -c 'memory landing-deploy' <<<"$out")/$(grep -c 'consolidation-loop' <<<"$out")" "1/0"
chk "a header always has a pointer under it"  "$(h=$(grep -c '^Related' <<<"$out"); p=$(grep -c '^  ' <<<"$out"); { [ "$h" -eq 0 ] || [ "$p" -gt 0 ]; } && echo ok)" ok

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
