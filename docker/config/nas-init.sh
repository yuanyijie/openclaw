#!/bin/bash
# nas-init.sh — Restore .openclaw from NAS git bundle + inject API keys
#
# One-shot process managed by process-compose.
# Waits for /tmp/claw-config.json (written by backend via write_file API),
# then downloads and restores the git bundle from NAS.
# Finally injects API keys (dashscope, tavily) into openclaw.json.

set -euo pipefail

CONFIG_FILE="/tmp/claw-config.json"
TIMEOUT=60
OPENCLAW_DIR="/home/user/.openclaw"
BUNDLE_LOCAL="/tmp/repo.bundle"
LOG_PREFIX="[nas-init]"

log() { echo "${LOG_PREFIX} $(date '+%H:%M:%S') $*"; }

# ============================================
# Helper: Inject API keys from claw-config.json
# ============================================
inject_api_keys() {
  local config_file="$1"
  local openclaw_json="${OPENCLAW_DIR}/openclaw.json"

  [ -f "$config_file" ] || return 0

  local moonshot_key ds_key tavily_key
  moonshot_key=$(jq -r '.moonshot_api_key // empty' "$config_file")
  ds_key=$(jq -r '.dashscope_api_key // empty' "$config_file")
  tavily_key=$(jq -r '.tavily_api_key // empty' "$config_file")

  [ -n "$moonshot_key" ] || [ -n "$ds_key" ] || [ -n "$tavily_key" ] || return 0

  if [ ! -f "$openclaw_json" ]; then
    log "WARN: ${openclaw_json} not found, skipping key injection"
    return 0
  fi

  log "Injecting API keys into openclaw.json"
  python3 -c "
import json, sys
path = sys.argv[1]
moonshot_key = sys.argv[2]
ds_key = sys.argv[3]
tavily_key = sys.argv[4]

with open(path) as f:
    cfg = json.load(f)

if moonshot_key:
    providers = cfg.get('models', {}).get('providers', {})
    if 'moonshot' in providers:
        providers['moonshot']['apiKey'] = moonshot_key

if ds_key:
    agents = cfg.setdefault('agents', {})
    defaults = agents.setdefault('defaults', {})
    defaults['memorySearch'] = {
        'provider': 'openai',
        'model': 'text-embedding-v4',
        'remote': {
            'baseUrl': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
            'apiKey': ds_key,
        },
    }

if tavily_key:
    tools = cfg.setdefault('tools', {})
    web = tools.setdefault('web', {})
    search = web.setdefault('search', {})
    search['provider'] = 'tavily'
    search['tavily'] = {'apiKey': tavily_key}

with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
print('API keys injected')
" "$openclaw_json" "$moonshot_key" "$ds_key" "$tavily_key" 2>/dev/null \
    && chown 1000:1000 "$openclaw_json" 2>/dev/null \
    || log "WARN: Failed to inject API keys"
}

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
  log "NAS disabled, skipping NAS restore"
  inject_api_keys "$CONFIG_FILE"
  log "Done"
  exit 0
fi

NAS_ADDR=$(jq -r '.nas_addr' "$CONFIG_FILE")
NAS_REMOTE_DIR=$(jq -r '.nas_remote_dir' "$CONFIG_FILE")

if [ -z "$NAS_ADDR" ] || [ "$NAS_ADDR" = "null" ]; then
  log "ERROR: nas_addr is empty"
  inject_api_keys "$CONFIG_FILE"
  log "Done"
  exit 0
fi

BUNDLE_REMOTE="${NAS_REMOTE_DIR}/repo.bundle"

log "NAS: ${NAS_ADDR}, remote: ${NAS_REMOTE_DIR}"

# Allow git operations on user-owned directory when running as root
git config --global --add safe.directory "$OPENCLAW_DIR"

# ============================================
# 3. Ensure remote directory exists
# ============================================
log "Ensuring remote directory: ${NAS_REMOTE_DIR}"
nfs-tool "$NAS_ADDR" mkdirp "$NAS_REMOTE_DIR" 2>/dev/null || true

# ============================================
# 4. Try to restore from NAS bundle
# ============================================
NAS_RESTORED=false

if nfs-tool "$NAS_ADDR" read "$BUNDLE_REMOTE" "$BUNDLE_LOCAL" 2>/dev/null; then
  if ! git bundle verify "$BUNDLE_LOCAL" 2>/dev/null; then
    log "WARN: Bundle corrupted, falling back to first-time setup"
    rm -f "$BUNDLE_LOCAL"
  else
    log "Bundle downloaded, restoring..."

    if [ -d "$OPENCLAW_DIR" ] && [ ! -L "$OPENCLAW_DIR" ]; then
      mv "$OPENCLAW_DIR" "${OPENCLAW_DIR}.default"
    fi

    git clone -q "$BUNDLE_LOCAL" "$OPENCLAW_DIR" 2>/dev/null
    cd "$OPENCLAW_DIR" && git remote remove origin 2>/dev/null || true

    log "Restored from NAS ($(cd "$OPENCLAW_DIR" && git log --oneline | wc -l) commits)"
    rm -f "$BUNDLE_LOCAL"
    chown -R 1000:1000 "$OPENCLAW_DIR" 2>/dev/null || true
    NAS_RESTORED=true
  fi
fi

# ============================================
# 5. First time: init git repo from default config
# ============================================
if [ "$NAS_RESTORED" = "false" ]; then
  log "No bundle on NAS, first time setup"

  if [ -d "$OPENCLAW_DIR" ]; then
    cd "$OPENCLAW_DIR"

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
fi

# ============================================
# 6. Inject API keys (runs for ALL code paths)
# ============================================
inject_api_keys "$CONFIG_FILE"

log "Done"
exit 0
