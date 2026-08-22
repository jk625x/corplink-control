#!/bin/bash
set -u

APP_PATH="/Applications/Corplink Control.app"
HELPER_PATH="$APP_PATH/Contents/Resources/corplink-root-helper"

if [[ ! -x "$HELPER_PATH" ]]; then
  echo "[x] Installed diagnostic helper not found: $HELPER_PATH" >&2
  echo "    Install or upgrade Corplink Control first." >&2
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
    echo "[i] At least one Corplink component is running. See job.* above for details."
    ;;
  3)
    echo "[ok] No known Corplink job, process, or active System Extension was detected."
    ;;
  1)
    echo "[x] At least one resident launchd job disagrees with its expected process state." >&2
    ;;
  *)
    echo "[x] Status check failed with exit code $status_code." >&2
    ;;
esac

pending=$(printf '%s\n' "$status_output" | awk -F= '/^restore_pending=/{print substr($0, index($0, "=") + 1)}')
if [[ -n "$pending" ]]; then
  echo "[i] Recovery state is still pending for: $pending"
fi

exit "$status_code"
