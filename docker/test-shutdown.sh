#!/usr/bin/env bash
set -euo pipefail

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FIFO="$WORK/.pz-control"
mkfifo -m 0600 "$FIFO"
exec 3<>"$FIFO"

SAVE_WAIT=2
QUIT_WAIT=10

(
  while IFS= read -r line; do
    echo "  [fake-jvm] recv: $line"
    if [[ "$line" == "quit" ]]; then
      echo "  [fake-jvm] flushing world..."
      sleep 2
      echo "  [fake-jvm] clean exit"
      exit 0
    fi
  done < "$FIFO"
) &
PZ_PID=$!
echo "[test] fake jvm pid=$PZ_PID"

send_cmd() { printf '%s\n' "$*" >&3; }

shutdown_handler() {
  trap '' TERM INT
  echo "[test] signal received - graceful shutdown"
  kill -0 "$PZ_PID" 2>/dev/null || { echo "[test] already gone"; return; }
  send_cmd "servermsg \"Server shutting down - saving world\""
  sleep 1
  send_cmd "save"; sleep "$SAVE_WAIT"
  send_cmd "quit"
  local waited=0
  while kill -0 "$PZ_PID" 2>/dev/null && (( waited < QUIT_WAIT )); do
    sleep 1; waited=$(( waited + 1 ))
  done
  if kill -0 "$PZ_PID" 2>/dev/null; then
    echo "[test] FAIL: jvm survived ${QUIT_WAIT}s"; kill -KILL "$PZ_PID" 2>/dev/null || true
  else
    echo "[test] PASS: jvm exited cleanly after ${waited}s"
  fi
}
trap shutdown_handler TERM INT

( sleep 1; echo "[test] --- injecting 'players' via FIFO (pz-console path) ---"
  printf '%s\n' "players" > "$FIFO"
  sleep 1; echo "[test] --- sending SIGTERM ---"; kill -TERM $$ ) &

while kill -0 "$PZ_PID" 2>/dev/null; do
  wait "$PZ_PID" && EXIT_CODE=0 || EXIT_CODE=$?
done
exec 3>&-
echo "[test] wrapper exiting with ${EXIT_CODE:-0}"
