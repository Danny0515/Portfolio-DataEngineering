#!/bin/bash
# PostToolUse(Edit|Write) hook: detect an edit to a Terraform source file under
# infra/ and remind to re-run the explain-infra skill so the matching
# infra/environments/<env>/README.md plain-language translation stays in sync.
#
# ---------------------------------------------------------------------------
# Payload facts (same as check-infra-snapshot.sh -- do not re-guess)
# ---------------------------------------------------------------------------
#   - PostToolUse does not fire when the tool call fails, so reaching this
#     script already implies success; `interrupted` is the only failure mode
#     left worth excluding.
#   - Both Edit and Write put the target path in .tool_input.file_path, so one
#     condition covers both. A single matcher "Edit|Write" is registered in
#     .claude/settings.json.
#   - The existing "Edit" matcher (check-decision-log.sh) fires alongside this
#     one on every Edit. No conflict: that script filters to docs/specs/*.md
#     and emits `empty` otherwise.
#
# ---------------------------------------------------------------------------
# Known and accepted limitations
# ---------------------------------------------------------------------------
#   - .terraform/ is excluded so provider-vendored .tf files never trigger it.
#   - The env name is taken from the path only. A .tf outside
#     infra/environments/<env>/ still triggers a reminder, but with no env
#     name -- deliberate, since a stray .tf is worth surfacing either way.
#   - Hook *registration* in settings.json is snapshotted at session start, so
#     adding this entry needs a fresh session. Script *contents* are re-read on
#     every invocation, so editing this file takes effect immediately.
#   - exit 0 always, so a broken hook can never block work.
jq -c '
  select(.tool_response.interrupted != true)
  | (.tool_input.file_path // "") as $fp
  | select($fp | test("infra/.*\\.tf$"))
  | select($fp | test("/\\.terraform/") | not)
  | ([$fp | scan("environments/([a-zA-Z0-9_-]+)")] | if length > 0 then .[0][0] else null end) as $env
  | if $env then
      {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ("偵測到 Terraform 原始碼異動：" + $fp + "。請用 explain-infra skill 重新轉譯（/explain-infra " + $fp + "），就地更新 infra/environments/" + $env + "/README.md 中該檔的章節，讓白話說明跟 .tf 保持同步。這是純本機讀取，不需要 AWS 憑證。")}}
    else
      {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ("偵測到 Terraform 原始碼異動：" + $fp + "，但路徑不在 infra/environments/<env>/ 底下，無法判斷所屬環境。請確認這個 .tf 是否該歸入某個環境目錄，並用 explain-infra skill 更新對應的白話說明。")}}
    end
'
exit 0
