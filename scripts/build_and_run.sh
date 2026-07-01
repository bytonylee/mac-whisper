#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Mac Whisper"
EXEC_NAME="MacWhisper"
BUNDLE_ID="com.solo.macwhisper"
APP_BUNDLE="build/${APP_NAME}.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${EXEC_NAME}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

pkill -x "$EXEC_NAME" >/dev/null 2>&1 || true

make app

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXEC_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$EXEC_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
