#!/bin/bash
# Silent end-to-end check of the voice permission hook (HM-1369) against the
# running Needs You app: fake PermissionRequest inputs go through the real CLI
# and socket, muted (no sound, no mic, nothing on the screen but a brief island
# state). Answers are synthesized to WAV files with tts-test (not played).
# Never touches ~/.claude/settings.json or do not disturb.
set -euo pipefail
cli="${NEEDS_YOU_CLI:-$HOME/.local/bin/needs-you}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

input() { # <command> -> hook input JSON
  python3 -c 'import json,sys; print(json.dumps({"session_id":"selftest","hook_event_name":"PermissionRequest","cwd":"/tmp/website","tool_name":"Bash","tool_input":{"command":sys.argv[1]},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push:*"}],"behavior":"allow","destination":"localSettings"}]}))' "$1"
}
check() { # <name> <expected substring or EMPTY> <output>
  if [[ "$2" == EMPTY && -z "$3" ]] || [[ "$2" != EMPTY && "$3" == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: got '$3'"; fail=1; fi
}

"$cli" status >/dev/null || { echo "Needs You is not running"; exit 1; }
for phrase in "Yes, go ahead." "No, don't." "Always." "Purple elephant."; do
  f="$tmp/$(echo "$phrase" | tr -cd 'a-zA-Z').wav"
  "$cli" tts-test "$phrase" --tts-out "$f" >/dev/null
done

t0=$(date +%s)
out=$(input "git status" | "$cli" permission-hook); check "safe command: normal prompt" EMPTY "$out"
out=$(input "git push --force origin main" | NEEDS_YOU_HOOK_TEST_INPUT="$tmp/Yesgoahead.wav" "$cli" permission-hook); check "yes: allow" '"behavior":"allow"' "$out"
out=$(input "rm -rf build" | NEEDS_YOU_HOOK_TEST_INPUT="$tmp/Nodont.wav" "$cli" permission-hook); check "no: deny" '"behavior":"deny"' "$out"
out=$(input "git push origin main" | NEEDS_YOU_HOOK_TEST_INPUT="$tmp/Always.wav" "$cli" permission-hook); check "always: allow with rule" '"updatedPermissions"' "$out"
out=$(input "git push origin main" | NEEDS_YOU_HOOK_TEST_INPUT="$tmp/Purpleelephant.wav" "$cli" permission-hook); check "unclear: normal prompt" EMPTY "$out"
out=$(input "git push origin main" | NEEDS_YOU_HOOK_TEST_SILENCE=1 "$cli" permission-hook); check "no answer: normal prompt" EMPTY "$out"
out=$(input "git push origin main" | CFFIXED_USER_HOME="$tmp" NEEDS_YOU_HOOK_TEST_SILENCE=1 "$cli" permission-hook); check "app not running: normal prompt" EMPTY "$out"
out=$(input "git push origin main" | NEEDS_YOU_HOOK_BUDGET=1 NEEDS_YOU_HOOK_TEST_SILENCE=1 NEEDS_YOU_PERMISSION_WAIT=5 "$cli" permission-hook); check "budget runs out: normal prompt" EMPTY "$out"
echo "took $(( $(date +%s) - t0 )) s"
exit $fail
