#!/usr/bin/env bash
# Dispatcher：`query_audit_log` skill 的統一入口。
#
# 第一個參數是「方法名稱」，對應 scripts/query_audit_log/<method>.sh 這支獨立
# script——一個方法一個檔案，彼此互不影響。新增方法只需要在 scripts/query_audit_log/
# 底下加一支新的 .sh，不需要改這支 dispatcher。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METHODS_DIR="${SCRIPT_DIR}/query_audit_log"

usage() {
  echo "用法: scripts/query_audit_log.sh <method> [args...]" >&2
  echo >&2
  echo "可用方法：" >&2
  for f in "${METHODS_DIR}"/*.sh; do
    echo "  - $(basename "${f}" .sh)" >&2
  done
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

METHOD="$1"
shift

TARGET="${METHODS_DIR}/${METHOD}.sh"

if [[ ! -f "${TARGET}" ]]; then
  echo "未知方法：${METHOD}" >&2
  echo >&2
  usage
  exit 1
fi

exec bash "${TARGET}" "$@"
