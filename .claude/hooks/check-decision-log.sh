#!/bin/bash
jq -c '
  .tool_input as $ti
  | ($ti.file_path // "") as $fp
  | ($ti.old_string // "") as $old
  | ($ti.new_string // "") as $new
  | if ($fp | test("docs/specs/.*\\.md$"))
       and ($new | contains("✅ **決定"))
       and (($old | contains("✅ **決定")) | not)
    then {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ("此次編輯在 " + $fp + " 新增了決策標記（✅ **決定），請檢查 docs/decision-log.md 是否需要新增對應列（格式規範見該檔案開頭）。")}}
    else empty
    end
' 2>/dev/null
exit 0
