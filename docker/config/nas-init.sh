#!/bin/bash
# nas-init.sh — NAS 持久化初始化
#
# 由 process-compose 启动，openclaw 进程 depends_on 本进程。
# 后端创建沙箱后通过 write_file API 写入 /tmp/claw-config.json 触发。

set -euo pipefail

CONFIG_FILE="/tmp/claw-config.json"
TIMEOUT=60
DEFAULT_OPENCLAW_DIR="/home/user/.openclaw"
LOG_PREFIX="[nas-init]"

log() { echo "${LOG_PREFIX} $*"; }

# ============================================
# 1. 等待后端写入配置文件
# ============================================
log "Waiting for config file: ${CONFIG_FILE} (timeout: ${TIMEOUT}s)"

elapsed=0
while [ ! -f "$CONFIG_FILE" ]; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ $elapsed -ge $TIMEOUT ]; then
    log "WARN: Timeout waiting for config file, starting without NAS"
    exit 0
  fi
done

log "Config file received after ${elapsed}s"

# ============================================
# 2. 读取配置
# ============================================
NAS_ENABLED=$(jq -r '.nas_enabled // false' "$CONFIG_FILE")

if [ "$NAS_ENABLED" != "true" ]; then
  log "NAS disabled, skipping mount"
  exit 0
fi

NAS_ADDR=$(jq -r '.nas_addr' "$CONFIG_FILE")
NAS_REMOTE_DIR=$(jq -r '.nas_remote_dir' "$CONFIG_FILE")
MOUNT_DIR=$(jq -r '.mount_dir // "/home/user/persistent"' "$CONFIG_FILE")

if [ -z "$NAS_ADDR" ] || [ "$NAS_ADDR" = "null" ]; then
  log "ERROR: nas_addr is empty, skipping mount"
  exit 0
fi

log "Config: addr=${NAS_ADDR}, remote=${NAS_REMOTE_DIR}, mount=${MOUNT_DIR}"

# ============================================
# 3. 创建 /dev/fuse（/dev 是 tmpfs，每次启动都需要）
# ============================================
if [ ! -e /dev/fuse ]; then
  mknod /dev/fuse c 10 229 2>/dev/null || true
  chmod 666 /dev/fuse 2>/dev/null || true
  log "/dev/fuse created"
fi

# ============================================
# 4. 确保 NAS 远端用户目录存在
#    先临时挂载 NAS 根目录，创建子目录，再卸载
# ============================================
TMP_MOUNT="/tmp/.nas_root_$$"
mkdir -p "$TMP_MOUNT"

log "Temporary mount to ensure remote directory exists"
if /usr/local/bin/fuse-nfs -n "nfs://${NAS_ADDR}/" -m "$TMP_MOUNT" 2>/dev/null; then
  mkdir -p "${TMP_MOUNT}${NAS_REMOTE_DIR}" 2>/dev/null || true
  fusermount -u "$TMP_MOUNT" 2>/dev/null || true
  log "Remote directory ensured: ${NAS_REMOTE_DIR}"
else
  log "WARN: Failed to temporary-mount NAS root, remote dir may not exist"
fi
rmdir "$TMP_MOUNT" 2>/dev/null || true

# ============================================
# 5. 挂载用户专属 NAS 子目录
# ============================================
mkdir -p "$MOUNT_DIR"

log "Mounting nfs://${NAS_ADDR}${NAS_REMOTE_DIR} -> ${MOUNT_DIR}"
if ! /usr/local/bin/fuse-nfs \
  -n "nfs://${NAS_ADDR}${NAS_REMOTE_DIR}" \
  -m "$MOUNT_DIR" \
  -a 2>/dev/null; then
  log "ERROR: fuse-nfs mount failed (non-fatal), continuing without NAS"
  exit 0
fi

log "NAS mounted successfully"

# ============================================
# 6. 初始化 OpenClaw 配置
#    首次：拷贝镜像默认配置到 NAS
#    非首次：NAS 上已有数据，直接使用
# ============================================
NAS_OPENCLAW_DIR="${MOUNT_DIR}/.openclaw"

if [ ! -f "${NAS_OPENCLAW_DIR}/openclaw.json" ]; then
  log "First time setup: copying default openclaw config to NAS"
  mkdir -p "$NAS_OPENCLAW_DIR"
  cp -r "${DEFAULT_OPENCLAW_DIR}/." "$NAS_OPENCLAW_DIR/" 2>/dev/null || true
  touch "${MOUNT_DIR}/.initialized"
else
  log "Existing config found on NAS, reusing"
fi

# ============================================
# 7. 建立 symlink：让 OpenClaw 读写 NAS 上的配置
# ============================================
if [ -d "$DEFAULT_OPENCLAW_DIR" ] && [ ! -L "$DEFAULT_OPENCLAW_DIR" ]; then
  rm -rf "$DEFAULT_OPENCLAW_DIR"
fi
ln -sf "$NAS_OPENCLAW_DIR" "$DEFAULT_OPENCLAW_DIR"
log "Symlink: ${DEFAULT_OPENCLAW_DIR} -> ${NAS_OPENCLAW_DIR}"

log "Done"
exit 0
