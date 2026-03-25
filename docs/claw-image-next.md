# Claw 沙箱镜像 — 生命周期钩子方案

## 概述

镜像从 v1.8 起支持 **生命周期钩子（lifecycle hooks）**。`claw-config.json` 从纯数据文件升级为带钩子的配置协议，后端组装钩子脚本、沙箱执行钩子脚本。镜像只提供通用钩子框架，不含任何业务逻辑。

## 启动时序

```
claw-config.json 到达
        │
   nas-init.sh
        │
        ├─ NAS 恢复 / 首次初始化
        │
        ├─ run_hook "post_restore"     ← 清理不兼容配置
        │
        ├─ inject_api_keys             ← 注入 API keys
        │
        ├─ run_hook "pre_start"        ← 最终清理
        │
        └─ exit 0
              │
       ┌──────┴──────┐
       │              │
   openclaw       hook-runner
   (gateway)    (periodic hook)
```

## claw-config.json 协议

新增 `hooks` 字段，三个钩子阶段：

| 钩子 | 时机 | 用途 |
|------|------|------|
| `post_restore` | NAS 恢复后、API key 注入前 | 清理 NAS 带回的不兼容配置（tools.browser、plugins 等） |
| `pre_start` | API key 注入后、exit 0 前 | 最终清理（删 extensions 目录等） |
| `periodic` | OpenClaw 运行期间循环执行 | Config watchdog，防止自重启写回脏配置 |

### 示例

```json
{
  "nas_enabled": true,
  "nas_addr": "xxx.cn-hangzhou.nas.aliyuncs.com",
  "nas_remote_dir": "/test/users/4/claws/11",
  "moonshot_api_key": "sk-xxx",
  "dashscope_api_key": "sk-xxx",
  "tavily_api_key": "tvly-xxx",

  "hooks": {
    "post_restore": "#!/bin/bash\nnode -e \"...sanitize openclaw.json...\"",
    "pre_start": "#!/bin/bash\nrm -rf /home/user/.openclaw/extensions 2>/dev/null || true",
    "periodic": {
      "command": "#!/bin/bash\nnode -e \"...clean plugins...\"",
      "interval_seconds": 60
    }
  }
}
```

### 向后兼容

- `hooks` 字段完全可选。不传时行为与之前一致（只做 NAS 恢复 + API key 注入）。
- `periodic` 可以只有 `command`，`interval_seconds` 默认 60。

## 镜像侧变更清单

### 1. nas-init.sh

新增 `run_hook` 通用函数：

```bash
HOOKS_DIR="/tmp/claw-hooks"

run_hook() {
  local hook_name="$1"
  local script
  script=$(jq -r ".hooks.${hook_name} // empty" "$CONFIG_FILE" 2>/dev/null)
  [ -n "$script" ] || return 0

  log "Running hook: ${hook_name}"
  mkdir -p "$HOOKS_DIR"
  echo "$script" > "${HOOKS_DIR}/${hook_name}.sh"
  chmod +x "${HOOKS_DIR}/${hook_name}.sh"
  bash "${HOOKS_DIR}/${hook_name}.sh" 2>&1 | while IFS= read -r line; do
    log "[hook:${hook_name}] $line"
  done
  log "Hook ${hook_name} finished"
}
```

调用位置（所有 code path 统一）：

```bash
# NAS restore / first-time init done
run_hook "post_restore"
inject_api_keys "$CONFIG_FILE"
run_hook "pre_start"
chown -R user:user "$OPENCLAW_DIR" 2>/dev/null || true
exit 0
```

### 2. hook-runner.sh（新文件）

Process-compose 管理的长驻进程，负责执行 `periodic` 钩子：

- 读取 `hooks.periodic.command` 和 `hooks.periodic.interval_seconds`
- 无 periodic 钩子时 `sleep infinity`
- 每 N 秒执行一次，输出带 `[hook-runner]` 前缀的日志

### 3. process-compose.openclaw.yaml

新增 `hook-runner` 进程：

```yaml
hook-runner:
  command: "/usr/local/bin/hook-runner.sh"
  depends_on:
    nas-init:
      condition: process_completed_successfully
  availability:
    restart: "always"
    backoff_seconds: 10
    max_restarts: 3
```

### 4. Dockerfile.aio

新增一行 COPY：

```dockerfile
COPY docker/config/hook-runner.sh /usr/local/bin/hook-runner.sh
```

### 5. openclaw.json

保持当前状态（无 `tools.browser`）。浏览器集成通过 top-level `browser` 配置项连接 browsertool CDP proxy。

## 后端集成指南

### 状态机

```
provision_instance() → DB status = "provisioning"
                          │
                    poll /healthz
                          │
                  ┌───────┴───────┐
                  │               │
            status = "running"  status = "error"
```

### _write_claw_config 组装钩子

```python
def _build_hooks(self) -> dict:
    return {
        "post_restore": POST_RESTORE_HOOK,   # 清理 tools.browser, plugins
        "pre_start": PRE_START_HOOK,          # 删 extensions 目录
        "periodic": {
            "command": PERIODIC_HOOK,          # 定期清理 plugins
            "interval_seconds": 60,
        },
    }
```

钩子脚本定义为 Python 模块常量或从 `backend/claw/hooks/` 目录读取 `.sh` 文件。

### 简化 _post_provision

删除 `_cleanup_config` 和 `_cleanup_extensions`，只保留 healthz 等待 + 状态翻转。

### API 层

`provisioning` 状态时 chat/filesystem 等接口返回 **409 Conflict**，提示"实例正在启动中"。

## 前端适配

- `provisioning` 状态显示加载动画，每 3-5 秒轮询
- 禁用 chat 输入和文件操作
- 侧边栏增加黄色脉动点表示 provisioning
