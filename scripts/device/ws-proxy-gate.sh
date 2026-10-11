#!/bin/bash
# Run the WebSocket proxy gate on a board, from inside a bench probe app.
#
#   PROBE_TOKEN=<the probe's auth_token> scripts/device/ws-proxy-gate.sh <board-ip> <probe-port> [--observe]
#
# Exits nonzero on any mismatch; `--observe` reports mismatches without failing (baseline of an unfixed build).
#
# The probe apps come from github.com/bbangert/ha-bench-addons. Use one that
# declares homeassistant_api (elixir_probe on 4000, probe_core_api on 4002).
# Expected on a fixed build: reserved, batched and malformed commands answer
# `unauthorized`; ordinary commands relay; `supervisor/api` is answered as the
# app, so `self_info_ws_vs_rest.data_equal` is true and anything the app's
# own token is refused over REST is refused here too.
set -euo pipefail
ip=${1:?board ip}; port=${2:?probe port}; : "${PROBE_TOKEN:?PROBE_TOKEN}"
observe=false; [ "${3:-}" = --observe ] && observe=true
here=$(cd "$(dirname "$0")" && pwd)
echo "== $(date -u +%FT%TZ) board=$ip probe-port=$port"
# The token travels on stdin (here-string, no argv); the body comes through a
# process substitution so stdin stays free for the header. jq must raise on a
# refused eval or `set -e` never sees it.
curl -sS -m 300 -H @- --data-binary @<(printf 'observe? = %s\n' "$observe"; cat "$here/ws-proxy-gate.exs") \
  "http://$ip:$port/eval" <<<"x-probe-token: $PROBE_TOKEN" |
  jq -r 'if .ok == true then .result else error("EVAL ERROR: " + (.error // "") + (.printed // "") + (if has("ok") then "" else " " + tostring end)) end'
