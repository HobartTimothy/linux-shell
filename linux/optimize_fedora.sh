#!/usr/bin/env bash
#
# Fedora 系统优化脚本
# 实际逻辑统一在同目录的 optimize_common.sh 中，这里只是 Fedora 入口包装。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "[*] 当前非 root 用户，将使用 sudo 重新执行..."
  exec sudo bash "$SCRIPT_DIR/optimize_common.sh" "$@"
else
  exec bash "$SCRIPT_DIR/optimize_common.sh" "$@"
fi


