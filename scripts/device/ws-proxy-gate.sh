#!/bin/bash
# Run the WebSocket proxy gate on a board, from inside a bench probe app.
#
#   PROBE_TOKEN=<the probe's auth_token> scripts/device/ws-proxy-gate.sh <board-ip> <probe-port>
#
# The probe apps come from github.com/bbangert/ha-bench-addons. Use one that
# declares homeassistant_api (elixir_probe on 4000, probe_core_api on 4002).
# Expected on a fixed build: reserved, batched and malformed commands answer
# `unauthorized`; ordinary commands relay; `supervisor/api` is answered as the
# app, so `self_info_ws_vs_rest.data_equal` is true and anything the app's
# own token is refused over REST is refused here too.
set -euo pipefail
ip=${1:?board ip}; port=${2:?probe port}; : "${PROBE_TOKEN:?PROBE_TOKEN}"
here=$(cd "$(dirname "$0")" && pwd)
echo "== $(date -u +%FT%TZ) board=$ip probe-port=$port"
# jq must fail the pipeline when the eval is refused, or `set -e` never sees it.
curl -sS -m 300 -H "x-probe-token: $PROBE_TOKEN" --data-binary @"$here/ws-proxy-gate.exs" "http://$ip:$port/eval" |
  jq -r 'if .ok == true then .result else error("EVAL ERROR: " + (.error // "") + (.printed // "") + (if has("ok") then "" else " " + tostring end)) end'
