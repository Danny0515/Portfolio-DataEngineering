#!/usr/bin/env bash
# 將整個專案同步到 bastion(danny-ops)。
#
# exclude 清單刻意跟 .gitignore 分開維護：這裡排除的是「本機專屬或 bastion 自己產生、
# 不該被本機同步覆蓋/刪除的東西」(.git 歷史、Terraform provider cache、state);
# 不是「git 該不該追蹤」的規則(例如 data/ 要同步過去給 bastion 上傳 S3,但不需要進 git)。
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rsync -av --delete \
  --exclude='.git/' \
  --exclude='**/.terraform/' \
  --exclude='*.tfstate' \
  --exclude='*.tfstate.*' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.venv/' \
  --exclude='.DS_Store' \
  "${PROJECT_ROOT}/" danny-ops:~/Portfolio-DataEngineering/
