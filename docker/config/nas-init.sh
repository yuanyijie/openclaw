#!/bin/bash
# nas-init.sh — Wait for claw-config.json, run lifecycle hooks, inject API keys
#
# One-shot process managed by process-compose.
# NAS persistence is handled natively by the platform (directory mount).
# This script only handles:
#   1. Lifecycle hooks (post_restore, pre_start) from claw-config.json
#   2. API key injection into openclaw.json

set -euo pipefail

CONFIG_FILE="/tmp/claw-config.json"
TIMEOUT=60
OPENCLAW_DIR="/home/user/capy/.openclaw"
HOOKS_DIR="/tmp/claw-hooks"
LOG_PREFIX="[nas-init]"

log() { echo "${LOG_PREFIX} $(date '+%H:%M:%S') $*"; }

# ============================================
# Helper: Run a lifecycle hook from claw-config.json
# ============================================
run_hook() {
  local hook_name="$1"
  local script
  script=$(jq -r ".hooks.${hook_name} // empty" "$CONFIG_FILE" 2>/dev/null)
  [ -n "$script" ] || return 0

  log "Running hook: ${hook_name}"
  mkdir -p "$HOOKS_DIR"
  echo "$script" > "${HOOKS_DIR}/${hook_name}.sh"
  chmod +x "${HOOKS_DIR}/${hook_name}.sh"
  local exit_code=0
  bash "${HOOKS_DIR}/${hook_name}.sh" 2>&1 | while IFS= read -r line; do
    log "[hook:${hook_name}] $line"
  done || exit_code=$?
  log "Hook ${hook_name} finished (exit=${exit_code})"
  return 0
}

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
    log "WARN: Timeout waiting for config, starting without it"
    exit 0
  fi
done

log "Config received after ${elapsed}s"

# ============================================
# 1.5 Ensure openclaw.json exists (NAS mount may shadow image defaults)
# ============================================
DEFAULTS_DIR="/app/openclaw-defaults"
if [ ! -f "${OPENCLAW_DIR}/openclaw.json" ] && [ -f "${DEFAULTS_DIR}/openclaw.json" ]; then
  log "openclaw.json missing in NAS dir, copying from image defaults"
  mkdir -p "$OPENCLAW_DIR"
  cp "$DEFAULTS_DIR/openclaw.json" "$OPENCLAW_DIR/openclaw.json"
  chown 1000:1000 "$OPENCLAW_DIR/openclaw.json"
fi

# ============================================
# 2. Ensure platform skills dir in extraDirs + sync allowBundled whitelist
#    (old NAS configs may lack these; never overwrite user-customized values)
# ============================================
PLATFORM_SKILLS_DIR="/mnt/platform/skills"
if [ -f "${OPENCLAW_DIR}/openclaw.json" ]; then
  python3 -c "
import json, sys
p, d, defaults_path = sys.argv[1], sys.argv[2], sys.argv[3]
changed = False

with open(p) as f: cfg = json.load(f)

# Ensure extraDirs contains platform skills dir
dirs = cfg.get('skills', {}).get('load', {}).get('extraDirs', [])
if d not in dirs:
    cfg.setdefault('skills', {}).setdefault('load', {}).setdefault('extraDirs', []).append(d)
    changed = True
    print('Injected ' + d + ' into skills.load.extraDirs')
else:
    print('Platform skills dir already configured')

# Sync allowBundled from image defaults only if not set by user
if 'allowBundled' not in cfg.get('skills', {}):
    try:
        with open(defaults_path) as f: defaults = json.load(f)
        allow = defaults.get('skills', {}).get('allowBundled')
        if allow:
            cfg.setdefault('skills', {})['allowBundled'] = allow
            changed = True
            print('Synced allowBundled whitelist from image defaults')
    except Exception as e:
        print('WARN: could not read defaults: ' + str(e))
else:
    print('allowBundled already set, skipping sync')

if changed:
    with open(p, 'w') as f: json.dump(cfg, f, indent=2)
" "${OPENCLAW_DIR}/openclaw.json" "$PLATFORM_SKILLS_DIR" "${DEFAULTS_DIR}/openclaw.json" \
  2>&1 | while IFS= read -r line; do log "$line"; done
fi

# ============================================
# 2.5 Refresh font cache if platform fonts dir has content
# ============================================
if [ -d "/mnt/platform/fonts" ] && [ "$(ls -A /mnt/platform/fonts 2>/dev/null)" ]; then
  log "Refreshing font cache for platform fonts"
  fc-cache -f /mnt/platform/fonts 2>/dev/null || true
fi

# ============================================
# 3. Run hooks + inject API keys
# ============================================
run_hook "post_restore"
inject_api_keys "$CONFIG_FILE"
run_hook "pre_start"

log "Done"
exit 0
