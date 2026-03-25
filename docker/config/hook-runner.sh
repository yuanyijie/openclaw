#!/bin/bash
# hook-runner.sh — Execute periodic hooks from claw-config.json
#
# Managed by process-compose. Reads hooks.periodic from the config
# and runs the command at the specified interval. Sleeps forever if
# no periodic hook is configured.

set -euo pipefail

CONFIG_FILE="/tmp/claw-config.json"
HOOKS_DIR="/tmp/claw-hooks"
LOG_PREFIX="[hook-runner]"

log() { echo "${LOG_PREFIX} $(date '+%H:%M:%S') $*"; }

if [ ! -f "$CONFIG_FILE" ]; then
  log "No config file, sleeping forever"
  exec sleep infinity
fi

PERIODIC_CMD=$(jq -r '.hooks.periodic.command // empty' "$CONFIG_FILE" 2>/dev/null)
INTERVAL=$(jq -r '.hooks.periodic.interval_seconds // 60' "$CONFIG_FILE" 2>/dev/null)

if [ -z "$PERIODIC_CMD" ]; then
  log "No periodic hook configured, sleeping forever"
  exec sleep infinity
fi

mkdir -p "$HOOKS_DIR"
echo "$PERIODIC_CMD" > "${HOOKS_DIR}/periodic.sh"
chmod +x "${HOOKS_DIR}/periodic.sh"

log "Periodic hook every ${INTERVAL}s"
while true; do
  sleep "$INTERVAL"
  bash "${HOOKS_DIR}/periodic.sh" 2>&1 | while IFS= read -r line; do
    log "$line"
  done || true
done
