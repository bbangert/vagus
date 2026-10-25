#!/usr/bin/env bash
: "${CLAUDE_CONFIG_DIR:?}"
RC_NAME=${RC_NAME:-vagus-$(hostname)}
RC_LOG=${RC_LOG:-/data/claude-loop.log}

log() {
  if [ "$(stat -c %s "$RC_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -n 200 "$RC_LOG" > "$RC_LOG.tmp" && mv "$RC_LOG.tmp" "$RC_LOG"
  fi
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$RC_LOG"
}

child=
forward() {
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
  exit 0
}
trap forward TERM HUP

# Plain remote-control in the same dir restores every session of a server that stopped
# within about four hours, otherwise starts a new multi-session server. --continue would
# restore only the first session and leave a server that cannot spawn more.
# RC_ARGS only adds flags to it.

# Server mode exits after ~10 min offline, so a crash loop has to outlast an outage
# without hammering; a run that stayed up long enough resets the delay.
delay=5
attempt=0
while :; do
  attempt=$((attempt + 1))
  cd /work || exit 1

  log "start attempt=$attempt args=${RC_ARGS:-}"
  started=$SECONDS

  # Unquoted RC_ARGS: word-splitting is the point. No output redirects: claude needs the pane TTY.
  # `<&0` because a non-interactive shell otherwise gives a backgrounded job /dev/null as stdin;
  # the job is backgrounded only so the TERM trap can fire during `wait`.
  # shellcheck disable=SC2086
  claude remote-control --name "$RC_NAME" ${RC_ARGS:-} <&0 &
  child=$!
  wait "$child"
  rc=$?
  child=""

  uptime=$((SECONDS - started))
  log "exit rc=$rc uptime=${uptime}s"

  if [ "$uptime" -ge 600 ]; then delay=5; fi
  sleep "$delay" & wait $!
  delay=$((delay * 2))
  [ "$delay" -gt 300 ] && delay=300
done
