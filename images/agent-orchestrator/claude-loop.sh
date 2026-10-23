#!/usr/bin/env bash
: "${CLAUDE_CONFIG_DIR:?}"
RC_NAME=${RC_NAME:-vagus-$(hostname)}
RC_LOG=${RC_LOG:-/data/claude-loop.log}
marker=$CLAUDE_CONFIG_DIR/.vagus-rc-last-start
# --continue only reaches a session this recent (measured on the board, reboot included).
resume_window=14400
up_ok=60

log() {
  if [ "$(stat -c %s "$RC_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 200 "$RC_LOG" > "$RC_LOG.tmp" && mv "$RC_LOG.tmp" "$RC_LOG"
  fi
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$RC_LOG"
}

child=
keeper=
forward() {
  [ -n "$keeper" ] && kill "$keeper" 2>/dev/null
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
  exit 0
}
trap forward TERM HUP

# Refreshed while the server is up, so the window counts from when it was last alive,
# not from a start days ago.
# HUP too: the inherited `forward` would send claude a second TERM.
keep_marker() {
  trap 'kill "$s" 2>/dev/null; exit 0' TERM HUP
  sleep "$up_ok" & s=$!
  wait "$s"
  while kill -0 "$1" 2>/dev/null; do
    touch "$marker"
    sleep 600 & s=$!
    wait "$s"
  done
}

recent_marker() {
  [ -f "$marker" ] || return 1
  [ $(( $(date +%s) - $(stat -c %Y "$marker") )) -lt "$resume_window" ]
}

# Server mode exits after ~10 min offline, so a crash loop has to outlast an outage
# without hammering; a run that stayed up long enough resets the delay.
delay=5
attempt=0
next="continue"
while :; do
  attempt=$((attempt + 1))
  cd /work || exit 1

  # A --continue server holds one session and cannot take --spawn, so it is only tried
  # to pick a session back up; a fast failure or a finished session falls back to spawn.
  # Offline, both fail fast, so the two alternate: a stale session and an outage look
  # alike, and pinning to spawn would lose the session once the network returns.
  if [ -n "${RC_ARGS:-}" ]; then
    args=$RC_ARGS mode=override
  elif [ "$next" = continue ] && recent_marker; then
    args=--continue mode=continue
  else
    args=--spawn=same-dir mode=spawn
  fi
  log "start attempt=$attempt mode=$mode args=$args"
  started=$SECONDS

  # Unquoted args: word-splitting is the point. No output redirects: claude needs the pane TTY.
  # `<&0` because a non-interactive shell otherwise gives a backgrounded job /dev/null as stdin;
  # the job is backgrounded only so the TERM trap can fire during `wait`.
  # shellcheck disable=SC2086
  claude remote-control --name "$RC_NAME" $args <&0 &
  child=$!
  keep_marker "$child" &
  keeper=$!
  wait "$child"
  rc=$?
  kill "$keeper" 2>/dev/null
  wait "$keeper" 2>/dev/null
  child="" keeper=""

  uptime=$((SECONDS - started))
  log "exit rc=$rc uptime=${uptime}s"

  failed_fast=0
  [ "$uptime" -lt "$up_ok" ] && [ "$rc" != 0 ] && failed_fast=1
  # Resuming a session the user already ended would only reopen it.
  next="continue"
  [ "$mode" = continue ] && { [ "$rc" = 0 ] || [ "$failed_fast" = 1 ]; } && next="spawn"

  # If the session was only stale there is nothing to wait out: spawn at once.
  [ "$mode" = continue ] && [ "$failed_fast" = 1 ] && continue

  if [ "$uptime" -ge 600 ]; then delay=5; fi
  sleep "$delay" & wait $!
  delay=$((delay * 2))
  [ "$delay" -gt 300 ] && delay=300
done
