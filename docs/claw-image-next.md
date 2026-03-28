# Claw 沙箱镜像 — 使用手册

## 概述

镜像基于 AliCloud AIO 沙箱（`sandbox-all-in-one:v0.9.29`）扩展 OpenClaw，提供：

- **生命周期钩子**：`claw-config.json` 携带钩子脚本，镜像顺序执行
- **API Key 注入**：运行时从 config 注入，不在镜像内硬编码
- **NAS 持久化**：由平台原生目录挂载实现，镜像无需任何同步逻辑

## 目录结构

```
OpenClaw 状态目录：/home/user/capy/.openclaw
                    （由 HOME=/home/user/capy 决定）

进程管理：process-compose
  ├── nas-init   （一次性，等 config + 跑钩子 + 注入 key）
  ├── hook-runner（长驻，periodic 钩子）
  └── openclaw   （长驻，gateway 进程）
```

## 启动时序

```
claw-config.json 到达（后端 write_file 写入）
        │
   nas-init.sh
        │
        ├─ run_hook "post_restore"     ← 清理不兼容配置
        │
        ├─ inject_api_keys             ← 注入 API keys 到 openclaw.json
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

后端通过 Sandbox `write_file` API 写入 `/tmp/claw-config.json`。

### 完整字段

```json
{
  "moonshot_api_key": "sk-xxx",
  "dashscope_api_key": "sk-xxx",
  "tavily_api_key": "tvly-xxx",

  "hooks": {
    "post_restore": "#!/bin/bash\n...",
    "pre_start": "#!/bin/bash\n...",
    "periodic": {
      "command": "#!/bin/bash\n...",
      "interval_seconds": 60
    }
  }
}
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `moonshot_api_key` | string | Kimi/Moonshot API Key，注入到 `models.providers.moonshot.apiKey` |
| `dashscope_api_key` | string | DashScope Key，用于 memory search embedding |
| `tavily_api_key` | string | Tavily Key，用于 web search |
| `hooks.post_restore` | string | bash 脚本，API key 注入前执行 |
| `hooks.pre_start` | string | bash 脚本，exit 0 前执行 |
| `hooks.periodic.command` | string | bash 脚本，运行期间循环执行 |
| `hooks.periodic.interval_seconds` | int | periodic 间隔，默认 60 |

所有字段均可选。不传 `hooks` 时只做 API key 注入；不传任何字段时 nas-init 直接退出，OpenClaw 使用镜像默认配置启动。

### 钩子阶段

| 钩子 | 时机 | 典型用途 |
|------|------|----------|
| `post_restore` | API key 注入前 | 清理 `openclaw.json` 里的脏字段（tools.browser、plugins 等） |
| `pre_start` | exit 0 前 | 删除冲突目录（extensions 等） |
| `periodic` | OpenClaw 运行期间循环 | Config watchdog，防止 OpenClaw 自重启写回脏配置 |

### 向后兼容

- `hooks` 字段完全可选。
- `periodic` 可以只有 `command`，`interval_seconds` 默认 60。
- 超时（60s 内无 config）时 nas-init 直接退出，不影响 OpenClaw 启动。

## NAS 持久化

NAS 由平台原生目录挂载实现，镜像内**无任何 NFS 操作代码**。

挂载目标目录即为 OpenClaw 状态目录：

```
NAS 挂载路径 → /home/user/capy/.openclaw
```

OpenClaw 所有数据（配置、会话、memory、workspace）自动落到 NAS 上，沙箱重建后数据自然恢复。

## 浏览器集成

OpenClaw 通过 CDP 连接沙箱内置 Chrome：

```
openclaw.json:
  browser.cdpUrl = "http://127.0.0.1:18800"
```

OpenClaw 请求 `http://127.0.0.1:18800/json/version` 获取 WebSocket 地址后连接 Chrome。Chrome 调试端口通过环境变量 `SXBT_BROWSER_CDP_PORT=18800` 配置（由 AIO 基础镜像的 browsertool 读取）。

## 镜像进程清单

| 进程 | 身份 | 说明 |
|------|------|------|
| `nas-init` | root | 一次性，等 config → 钩子 → 注入 key |
| `hook-runner` | root | 长驻，执行 periodic 钩子 |
| `openclaw` | user | 长驻，OpenClaw gateway（端口 18789） |

`openclaw` 以 `user`（uid=1000）运行，`nas-init` / `hook-runner` 以 root 运行（平台 NFS 权限要求）。

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `OPENCLAW_GATEWAY_PORT` | OpenClaw 监听端口 | `18789` |
| `OPENCLAW_BUNDLED_PLUGINS_DIR` | 内置插件目录 | `/app/openclaw/extensions` |
| `OPENCLAW_SKIP_CHANNELS` | 禁用 channel | `0` |
| `SXBT_BROWSER_CDP_PORT` | Chrome CDP 端口 | `18800` |

## 后端集成指南

### 创建实例

```python
async def provision_claw(user_id, claw_id):
    sandbox = await create_sandbox(template="openclaw-template")

    config = {
        "moonshot_api_key": get_user_moonshot_key(user_id),
        "hooks": _build_hooks(),
    }
    await sandbox.write_file("/tmp/claw-config.json", json.dumps(config))

    # 轮询 healthz，通过后标记 running
    await wait_for_healthz(sandbox)
```

### 状态机

```
create_sandbox() → DB status = "provisioning"
                       │
                 poll /healthz (port 5000)
                       │
               ┌───────┴───────┐
               │               │
        status = "running"  status = "error"
```

### 钩子示例

```python
POST_RESTORE_HOOK = """#!/bin/bash
node -e "
const fs=require('fs'),p='/home/user/capy/.openclaw/openclaw.json';
try{
  const c=JSON.parse(fs.readFileSync(p,'utf8'));
  let d=false;
  if(c.tools&&c.tools.browser){delete c.tools.browser;d=true}
  if(c.plugins&&c.plugins.entries){c.plugins.entries={};d=true}
  if(d){fs.writeFileSync(p,JSON.stringify(c,null,2));console.log('sanitized')}
}catch(e){console.log('skip:'+e.message)}
"
"""

PRE_START_HOOK = """#!/bin/bash
rm -rf /home/user/capy/.openclaw/extensions 2>/dev/null || true
"""
```

### API 层

`provisioning` 状态时 chat / filesystem 等接口返回 **409 Conflict**，响应体提示"实例正在启动中"。

## 前端适配

- `provisioning` 状态：显示加载动画，每 3-5 秒轮询 `GET /api/claw/instance`
- 侧边栏：黄色脉动点表示 provisioning，绿色表示 running
- chat 输入和文件操作在 provisioning 期间禁用

## 排障

### 查看进程日志

```bash
# 在沙箱内
process-compose process logs nas-init
process-compose process logs openclaw
```

### 常见日志

| 日志 | 含义 |
|------|------|
| `Config received after Xs` | 正常，nas-init 收到 config |
| `Timeout waiting for config` | 60s 未收到 config，OpenClaw 用默认配置启动 |
| `Running hook: post_restore` | 钩子执行中 |
| `API keys injected` | key 注入成功 |
| `Done` | nas-init 正常退出，OpenClaw 即将启动 |
