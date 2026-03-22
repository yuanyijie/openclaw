#!/bin/bash
# nas-init.sh — Restore .openclaw from NAS git bundle
#
# One-shot process managed by process-compose.
# Waits for /tmp/claw-config.json (written by backend via write_file API),
# then downloads and restores the git bundle from NAS.

set -euo pipefail

CONFIG_FILE="/tmp/claw-config.json"
TIMEOUT=60
OPENCLAW_DIR="/home/user/.openclaw"
BUNDLE_LOCAL="/tmp/repo.bundle"
LOG_PREFIX="[nas-init]"

log() { echo "${LOG_PREFIX} $(date '+%H:%M:%S') $*"; }

# ============================================
# 1. Wait for backend config
# ============================================
log "Waiting for config: ${CONFIG_FILE}"

elapsed=0
while [ ! -f "$CONFIG_FILE" ]; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ $elapsed -ge $TIMEOUT ]; then
    log "WARN: Timeout waiting for config, starting without NAS"
    exit 0
  fi
done

log "Config received after ${elapsed}s"

# ============================================
# 2. Parse config
# ============================================
NAS_ENABLED=$(jq -r '.nas_enabled // false' "$CONFIG_FILE")

if [ "$NAS_ENABLED" != "true" ]; then
  log "NAS disabled, skipping"
  exit 0
fi

NAS_ADDR=$(jq -r '.nas_addr' "$CONFIG_FILE")
NAS_REMOTE_DIR=$(jq -r '.nas_remote_dir' "$CONFIG_FILE")

if [ -z "$NAS_ADDR" ] || [ "$NAS_ADDR" = "null" ]; then
  log "ERROR: nas_addr is empty"
  exit 0
fi

BUNDLE_REMOTE="${NAS_REMOTE_DIR}/repo.bundle"

log "NAS: ${NAS_ADDR}, remote: ${NAS_REMOTE_DIR}"

# ============================================
# 3. Ensure remote directory exists
# ============================================
log "Ensuring remote directory: ${NAS_REMOTE_DIR}"
nfs-tool "$NAS_ADDR" mkdirp "$NAS_REMOTE_DIR" 2>/dev/null || true

# ============================================
# 4. Try to restore from NAS bundle
# ============================================
if nfs-tool "$NAS_ADDR" read "$BUNDLE_REMOTE" "$BUNDLE_LOCAL" 2>/dev/null; then
  # Verify bundle integrity
  if ! git bundle verify "$BUNDLE_LOCAL" 2>/dev/null; then
    log "WARN: Bundle corrupted, falling back to first-time setup"
    rm -f "$BUNDLE_LOCAL"
  else
    log "Bundle downloaded, restoring..."

    # Back up default config from image
    if [ -d "$OPENCLAW_DIR" ] && [ ! -L "$OPENCLAW_DIR" ]; then
      mv "$OPENCLAW_DIR" "${OPENCLAW_DIR}.default"
    fi

    git clone -q "$BUNDLE_LOCAL" "$OPENCLAW_DIR" 2>/dev/null
    cd "$OPENCLAW_DIR" && git remote remove origin 2>/dev/null || true

    log "Restored from NAS ($(cd "$OPENCLAW_DIR" && git log --oneline | wc -l) commits)"
    rm -f "$BUNDLE_LOCAL"
    chown -R 1000:1000 "$OPENCLAW_DIR" 2>/dev/null || true
    exit 0
  fi
fi

# ============================================
# 5. First time: init git repo from default config
# ============================================
log "No bundle on NAS, first time setup"

if [ -d "$OPENCLAW_DIR" ]; then
  cd "$OPENCLAW_DIR"

  # Create .gitignore for temp/cache files
  cat > .gitignore << 'GITIGNORE'
logs/
*.lock
*.tmp
*.pid
GITIGNORE

  git init -q
  git add -A
  git -c user.name=claw -c user.email=claw@local \
    commit -q -m "initial" 2>/dev/null || true
  log "Initialized git repo in ${OPENCLAW_DIR}"

  # Upload initial bundle (atomic: write tmp + rename)
  git bundle create "$BUNDLE_LOCAL" --all 2>/dev/null
  if nfs-tool "$NAS_ADDR" write "${BUNDLE_REMOTE}.tmp" "$BUNDLE_LOCAL" 2>/dev/null && \
     nfs-tool "$NAS_ADDR" rename "${BUNDLE_REMOTE}.tmp" "$BUNDLE_REMOTE" 2>/dev/null; then
    log "Initial bundle uploaded to NAS"
  else
    log "WARN: Failed to upload initial bundle"
  fi
  rm -f "$BUNDLE_LOCAL"
fi

chown -R 1000:1000 "$OPENCLAW_DIR" 2>/dev/null || true
log "Done"
exit 0
