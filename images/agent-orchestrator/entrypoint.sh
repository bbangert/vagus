#!/usr/bin/env bash
set -euo pipefail
: "${CLAUDE_CONFIG_DIR:?}"

# An API key in the env silently wins over the claude.ai login and blocks Remote Control.
for v in $(compgen -e | grep '^ANTHROPIC_' || true) CLAUDE_CODE_OAUTH_TOKEN; do
  unset "$v"
done

# The volume arrives root-owned. The config dir is taken back recursively because a
# `podman exec` run as root (not `--user agent`) leaves files the CLI can no longer rewrite;
# the rest of /data (task dirs) is left alone.
mkdir -p "$CLAUDE_CONFIG_DIR"/{projects,sessions,todos,shell-snapshots,statsig,debug,plugins}
chown agent:agent /data /work
chown -R agent:agent "$CLAUDE_CONFIG_DIR"

# These are the CLI's own state keys (written by CLI 2.1.289 after the onboarding,
# "Enable Remote Control?" and workspace-trust prompts); with them Remote Control starts
# with no terminal. `//=` never overwrites: the CLI adds remoteControlMachineId and more
# to the same file.
state="$CLAUDE_CONFIG_DIR/.claude.json"
[ -f "$state" ] || echo '{}' > "$state"
tmp=$(mktemp "$CLAUDE_CONFIG_DIR/.claude.json.XXXXXX")
jq '.hasCompletedOnboarding //= true
    | .remoteDialogSeen //= true
    | .projects["/work"].hasTrustDialogAccepted //= true' "$state" > "$tmp"
chown agent:agent "$tmp"
mv "$tmp" "$state"

# Same server the workers get, with the orchestrator as its provenance.
tmp=$(mktemp "$CLAUDE_CONFIG_DIR/.claude.json.XXXXXX")
jq --arg dsn "${VAGUS_MEMORY_DSN:-postgresql://agent@172.30.40.2/memory}" \
  '.mcpServers["vagus-memory"] //= {command: "vagus-memory",
     env: {VAGUS_MEMORY_DSN: $dsn, VAGUS_TASK: "orchestrator"}}' "$state" > "$tmp"
chown agent:agent "$tmp"
mv "$tmp" "$state"

as_agent() {
  setpriv --reuid=agent --regid=agent --init-groups \
    env HOME=/home/agent USER=agent TERM=xterm-256color "$@"
}

# 200x50: Claude's TUI misrenders at tmux's detached default width.
as_agent tmux new-session -d -s claude -x 200 -y 50 /usr/local/bin/claude-loop

# kill-server HUPs the pane; waiting lets claude end its session inside the 10 s stop
# budget instead of being SIGKILLed along with the container.
# shellcheck disable=SC2329 # invoked by the trap
stop() {
  as_agent tmux kill-server || true
  for _ in $(seq 16); do
    pgrep -u agent -f 'claude remote-control' >/dev/null || break
    sleep 0.5
  done
  exit 0
}
trap stop TERM INT

# `sleep & wait` so the trap fires immediately instead of after the sleep.
while as_agent tmux has-session -t claude 2>/dev/null; do
  sleep 2 & wait $!
done

# claude-loop never returns normally, so a dead session is a failure.
exit 1
