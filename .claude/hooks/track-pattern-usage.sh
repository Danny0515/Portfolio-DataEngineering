#!/bin/bash
# PostToolUse(Read) hook: count how many distinct sessions have read each
# Pattern Card under docs/patterns/, and once a card reaches 3 sessions, remind
# the agent to ask the user whether to package it as a skill (rule documented in
# docs/patterns/overview.md).
#
# Accepted limitations:
#   - "Usage" is approximated by "a session read the card". A read is not proof
#     the pattern was applied, and one session counts once however often it reads.
#   - State lives in .claude/state/pattern-usage.json (gitignored, per machine).
#   - The reminder fires once per card (`asked` flag); declining is not tracked.
#   - Hook registration in settings.json is snapshotted at session start, so a
#     new entry needs a fresh session. Script contents are re-read on every run.
#   - exit 0 always, so a broken hook can never block work.

THRESHOLD=3

INPUT=$(cat)
FP=$(printf '%s' "$INPUT" | jq -r 'select(.tool_response.interrupted != true) | .tool_input.file_path // empty' 2>/dev/null)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

[[ "$FP" =~ docs/patterns/([^/]+\.md)$ ]] || exit 0
NAME="${BASH_REMATCH[1]}"
[ "$NAME" = "overview.md" ] && exit 0
[ -z "$SID" ] && exit 0

STATE="${CLAUDE_PROJECT_DIR:-$(pwd)}/.claude/state/pattern-usage.json"
mkdir -p "$(dirname "$STATE")" 2>/dev/null
[ -s "$STATE" ] || echo '{}' > "$STATE"

jq -e --arg n "$NAME" --arg s "$SID" '(.[$n].sessions // []) | index($s) != null' "$STATE" >/dev/null 2>&1 && exit 0

UPDATED=$(jq --arg n "$NAME" --arg s "$SID" --argjson t "$THRESHOLD" '
  .[$n] //= {sessions: [], asked: false}
  | .[$n].sessions += [$s]
  | if (.[$n].sessions | length) >= $t and (.[$n].asked | not) then .[$n].asked = true | .[$n].fire = true else . end
' "$STATE" 2>/dev/null) || exit 0

FIRE=$(printf '%s' "$UPDATED" | jq -r --arg n "$NAME" '.[$n].fire // false')
COUNT=$(printf '%s' "$UPDATED" | jq -r --arg n "$NAME" '.[$n].sessions | length')

printf '%s' "$UPDATED" | jq 'del(.[].fire)' > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"

if [ "$FIRE" = "true" ]; then
  jq -n --arg n "$NAME" --arg c "$COUNT" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ("Pattern Card " + $n + " 已在 " + $c + " 個不同 session 被讀取使用。依 docs/patterns/overview.md 的規則：使用者沒主動提出時，請在本輪回覆中詢問使用者是否要把這個 pattern 封裝成 skill（只問這一次）。")}}'
fi
exit 0
