#!/bin/bash
jq -c '
  select(.tool_response.success == true)
  | .tool_input.command as $cmd
  | select($cmd | test("terraform(\\s+-chdir=\\S+)?\\s+apply"))
  | ([$cmd | scan("environments/([a-zA-Z0-9_-]+)")] | if length > 0 then .[0][0] else null end) as $env
  | if $env then
      {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ("偵測到 terraform apply 成功執行於 infra/environments/" + $env + "。依既有慣例，請用 terraform output / terraform state list 的實際輸出，同步覆寫 ai/contexts/infra_" + ($env | gsub("-"; "_")) + ".md（不要手動編造內容）。")}}
    else
      {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: "偵測到 terraform apply 成功執行，但無法從指令本身判斷是哪個 infra/environments/<name> 目錄（可能先 cd 過去才執行）。請確認實際所在目錄，同步覆寫對應的 ai/contexts/infra_<name>.md（用 terraform output / terraform state list 實際輸出，不要手動編造）。"}}
    end
' 2>/dev/null
exit 0
