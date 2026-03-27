#!/bin/bash
# nas-sync.sh — Periodically sync .openclaw changes to NAS via git bundle
#
# Runs continuously under process-compose (as root, matching nas-init's
# NFS uid via root_squash → nobody). Every SYNC_INTERVAL seconds:
#   1. git add + commit (if changes exist)
#   2. git bundle create + verify
#   3. nfs-tool write (atomic: tmp + rename), with .prev backup
#   4. Periodic gc / squash to control bundle size

set -euo pipefail

CONFIG_FILE="/tmp/claw-config.json"
OPENCLAW_DIR="/home/user/.openclaw"
BUNDLE_LOCAL="/tmp/repo.bundle"
SYNC_INTERVAL=30
GC_THRESHOLD_MB=500
SQUASH_THRESHOLD_MB=1024
SQUASH_KEEP_COMMITS=100
GC_INTERVAL_SYNCS=60  # run gc check every ~30 min (60 * 30s)
LOG_PREFIX="[nas-sync]"

log() { echo "${LOG_PREFIX} $(date '+%H:%M:%S') $*"; }

# ============================================
# 1. Wait for config + validate
# ============================================
while [ ! -f "$CONFIG_FILE" ]; do sleep 2; done

NAS_ENABLED=$(jq -r '.nas_enabled // false' "$CONFIG_FILE")
if [ "$NAS_ENABLED" != "true" ]; then
  log "NAS disabled, exiting"
  exit 0
fi

NAS_ADDR=$(jq -r '.nas_addr' "$CONFIG_FILE")
NAS_REMOTE_DIR=$(jq -r '.nas_remote_dir' "$CONFIG_FILE")
BUNDLE_REMOTE="${NAS_REMOTE_DIR}/repo.bundle"

# Running as root on user-owned directory
git config --global --add safe.directory "$OPENCLAW_DIR"

# Wait for .openclaw to be a git repo (nas-init must finish first)
while [ ! -d "${OPENCLAW_DIR}/.git" ]; do
  log "Waiting for ${OPENCLAW_DIR}/.git ..."
  sleep 3
done

log "Sync loop started: interval=${SYNC_INTERVAL}s, remote=${BUNDLE_REMOTE}"

sync_count=0

# ============================================
# 2. Sync loop
# ============================================
while true; do
  sleep "$SYNC_INTERVAL"
  sync_count=$((sync_count + 1))

  cd "$OPENCLAW_DIR"

  # Check for changes (tracked, staged, and untracked)
  if git diff --quiet HEAD 2>/dev/null && \
     git diff --cached --quiet 2>/dev/null && \
     [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    continue
  fi

  # Commit changes
  git add -A 2>/dev/null
  git -c user.name=claw -c user.email=claw@local \
    commit -q -m "auto-sync $(date +%s)" 2>/dev/null || continue

  # Create bundle
  if ! git bundle create "$BUNDLE_LOCAL" --all 2>/dev/null; then
    log "WARN: bundle create failed"
    continue
  fi

  # Verify bundle before uploading
  if ! git bundle verify "$BUNDLE_LOCAL" 2>/dev/null; then
    log "WARN: bundle verify failed, skipping upload"
    rm -f "$BUNDLE_LOCAL"
    continue
  fi

  # Backup current bundle as .prev before overwriting
  nfs-tool "$NAS_ADDR" rename "$BUNDLE_REMOTE" "${BUNDLE_REMOTE}.prev" 2>/dev/null || true

  # Atomic upload: write to .tmp then rename
  if nfs-tool "$NAS_ADDR" write "${BUNDLE_REMOTE}.tmp" "$BUNDLE_LOCAL" 2>/dev/null && \
     nfs-tool "$NAS_ADDR" rename "${BUNDLE_REMOTE}.tmp" "$BUNDLE_REMOTE" 2>/dev/null; then
    bundle_size=$(stat -c%s "$BUNDLE_LOCAL" 2>/dev/null || echo "?")
    commit_count=$(git log --oneline 2>/dev/null | wc -l)
    log "Synced (${bundle_size} bytes, ${commit_count} commits)"
  else
    log "WARN: upload failed, will retry next cycle"
    nfs-tool "$NAS_ADDR" rm "${BUNDLE_REMOTE}.tmp" 2>/dev/null || true
    # Restore .prev if main bundle was lost during failed upload
    if ! nfs-tool "$NAS_ADDR" read "$BUNDLE_REMOTE" /dev/null 2>/dev/null; then
      nfs-tool "$NAS_ADDR" rename "${BUNDLE_REMOTE}.prev" "$BUNDLE_REMOTE" 2>/dev/null || true
    fi
  fi

  rm -f "$BUNDLE_LOCAL"

  # ============================================
  # 3. Periodic gc / squash (every GC_INTERVAL_SYNCS cycles)
  # ============================================
  if [ $((sync_count % GC_INTERVAL_SYNCS)) -eq 0 ]; then
    bundle_bytes=$(git bundle create "$BUNDLE_LOCAL" --all 2>/dev/null && stat -c%s "$BUNDLE_LOCAL" 2>/dev/null || echo 0)
    rm -f "$BUNDLE_LOCAL"
    bundle_mb=$((bundle_bytes / 1024 / 1024))

    if [ "$bundle_mb" -ge "$SQUASH_THRESHOLD_MB" ]; then
      # Squash: keep recent N commits, collapse the rest
      log "Bundle ${bundle_mb}MB >= ${SQUASH_THRESHOLD_MB}MB, squashing to ${SQUASH_KEEP_COMMITS} commits..."
      commit_count=$(git log --oneline | wc -l)
      if [ "$commit_count" -gt "$SQUASH_KEEP_COMMITS" ]; then
        squash_target=$(git log --oneline --skip="$SQUASH_KEEP_COMMITS" -1 --format="%H" 2>/dev/null || true)
        if [ -n "$squash_target" ]; then
          git reset --soft "$squash_target" 2>/dev/null
          git -c user.name=claw -c user.email=claw@local \
            commit -q -m "squashed history (kept ${SQUASH_KEEP_COMMITS} recent)" 2>/dev/null || true
          git gc --aggressive --prune=now 2>/dev/null
          log "Squash complete"
        fi
      fi
    elif [ "$bundle_mb" -ge "$GC_THRESHOLD_MB" ]; then
      log "Bundle ${bundle_mb}MB >= ${GC_THRESHOLD_MB}MB, running git gc..."
      git gc --prune=now 2>/dev/null
      log "GC complete"
    fi
  fi
done
