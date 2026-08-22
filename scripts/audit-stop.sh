#!/bin/bash
set -u

APP_PATH="/Applications/飞连控制.app"
HELPER_PATH="$APP_PATH/Contents/Resources/corplink-root-helper"

if [[ ! -x "$HELPER_PATH" ]]; then
  echo "[✗] 找不到已安装的诊断 helper：$HELPER_PATH" >&2
  echo "    请先安装或升级飞连控制 App。" >&2
  exit 2
fi

set +e
status_output=$("$HELPER_PATH" status)
status_code=$?
set -e

echo "$status_output"
echo

case "$status_code" in
  0)
    echo "[i] 至少有飞连组件正在运行，逐项状态见上方 job.*。"
    ;;
  3)
    echo "[✓] 整套飞连已知任务、进程和活跃 System Extension 均未检测到。"
    ;;
  1)
    echo "[✗] 至少一个 launchd 常驻任务与对应进程状态不一致。" >&2
    ;;
  *)
    echo "[✗] 状态检查失败，退出码：$status_code" >&2
    ;;
esac

pending=$(printf '%s\n' "$status_output" | awk -F= '/^restore_pending=/{print substr($0, index($0, "=") + 1)}')
if [[ -n "$pending" ]]; then
  echo "[i] 停止前快照中仍待恢复：$pending"
fi

exit "$status_code"
