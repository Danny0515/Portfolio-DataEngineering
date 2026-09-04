#!/bin/bash
# PostToolUse(Bash) hook: detect a successful `terraform apply` and remind to
# refresh the matching ai/contexts/infra_<env>.md snapshot.
#
# ---------------------------------------------------------------------------
# History: why this script looks the way it does (2026-09-03)
# ---------------------------------------------------------------------------
# This hook was registered in .claude/settings.json but appeared to "never
# fire" for days. It was in fact firing on every single Bash call; the jq
# filter just discarded every event and printed nothing. Root cause: the first
# line used to be `select(.tool_response.success == true)`, and the Bash tool's
# tool_response has no `success` field at all -- so the comparison was always
# `null == true`, i.e. false. The sibling hook check-decision-log.sh worked
# only because it never touches tool_response.
#
# The failure was invisible because `jq ... 2>/dev/null` plus a trailing
# `exit 0` made "crashed", "filtered everything out" and "not loaded" look
# identical from the outside. The 2>/dev/null has been removed for that reason
# (exit 0 is kept, so a broken hook can never block work).
#
# How it was diagnosed, if this ever needs repeating: temporarily add
# `_payload=$(cat)` at the top, append "$_payload" to a scratch log, and pipe
# it into jq. Then run any Bash command and inspect the log. Note that hook
# *script contents* are re-read on every invocation (edits take effect
# immediately), while the hook *registration* in settings.json is snapshotted
# at session start -- so instrumenting the script is always possible mid
# session, but adding a brand new hook entry may require a fresh session.
#
# ---------------------------------------------------------------------------
# Payload facts (verified against real PostToolUse payloads, do not re-guess)
# ---------------------------------------------------------------------------
#   - Bash tool_response == {stdout, stderr, interrupted, isImage,
#     noOutputExpected}. No `success`, no exit code.
#   - PostToolUse does not fire at all when the Bash command exits non-zero.
#     Reaching this script therefore already implies the command succeeded;
#     `interrupted` is the only remaining failure mode worth excluding.
#   - The payload carries `cwd`, used as a fallback when the environment name
#     is not visible in the command itself (e.g. the user cd'd there first).
#     The Bash tool's working directory persists across calls, so cwd stays
#     accurate for an earlier `cd infra/environments/<env>`.
#
# ---------------------------------------------------------------------------
# Known and accepted limitation: false positives
# ---------------------------------------------------------------------------
# Detection is a plain regex over the command *string*, so ANY Bash command
# that merely contains the words "terraform ... apply" triggers the reminder --
# grepping for it, echoing it, writing it into a doc, or even editing this very
# file from a shell. This is deliberate: the payload exposes no reliable signal
# that a real apply ran (stdout may be truncated, so matching "Apply complete!"
# is not dependable), and the cost of a false reminder is one extra sentence of
# context, while a missed reminder means infra_<env>.md silently goes stale.
# If a spurious reminder shows up, this paragraph is the explanation -- the
# hook is working as designed, not misfiring.
jq -c '
  select(.tool_response.interrupted != true)
  | .tool_input.command as $cmd
  | .cwd as $cwd
  | select($cmd | test("terraform(\\s+-\\S+)*\\s+apply"))
  | ([($cmd, $cwd) | scan("environments/([a-zA-Z0-9_-]+)")] | if length > 0 then .[0][0] else null end) as $env
  | if $env then
      {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ("偵測到 terraform apply 成功執行於 infra/environments/" + $env + "。依既有慣例，請用 terraform output / terraform state list 的實際輸出，同步覆寫 ai/contexts/infra_" + ($env | gsub("-"; "_")) + ".md（不要手動編造內容）。")}}
    else
      {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: "偵測到 terraform apply 成功執行，但無法從指令或工作目錄判斷是哪個 infra/environments/<name>。請確認實際所在目錄，同步覆寫對應的 ai/contexts/infra_<name>.md（用 terraform output / terraform state list 實際輸出，不要手動編造）。"}}
    end
'
exit 0
