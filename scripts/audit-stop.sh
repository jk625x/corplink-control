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
    echo "[i] 连接服务正在运行。"
    ;;
  3)
    echo "[✓] 连接服务已从 system domain 卸载，且没有主服务进程。"
    ;;
  1)
    echo "[✗] launchd job 与主服务进程状态不一致。" >&2
    ;;
  *)
    echo "[✗] 状态检查失败，退出码：$status_code" >&2
    ;;
esac

background=$(printf '%s\n' "$status_output" | awk -F= '/^background_components=/{print substr($0, index($0, "=") + 1)}')
if [[ -n "$background" ]]; then
  echo "[i] 仍运行的独立飞连组件：$background"
  echo "    这些组件不属于连接服务开关的控制范围，详见 docs/STOPPING.md。"
fi

exit "$status_code"
