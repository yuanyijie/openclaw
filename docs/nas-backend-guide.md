# Claw 沙箱 NAS 持久化 — 后端接入指南

## 1. 概述

Claw 沙箱通过 **平台原生 NAS 目录挂载** 持久化 OpenClaw 的配置、会话记录和工作区文件。

挂载目标路径固定为：

```
NAS 目录 → /home/user/capy/.openclaw
```

OpenClaw 所有数据（`openclaw.json`、会话、memory、workspace）直接落到 NAS 上。沙箱重建后，平台重新挂载同一 NAS 目录，数据自动恢复，无需额外同步。

后端的职责是：

1. 创建沙箱时通过 `write_file` API 写入 `claw-config.json`
2. 配置 NAS 挂载（由平台 API 完成，后端传参）

## 2. 接入步骤

### 2.1 创建沙箱并写入配置

沙箱创建成功后，立即通过 Sandbox API 的 `write_file` 接口写入配置文件：

```
路径: /tmp/claw-config.json
```

**最简配置（只注入 API Key）**

```json
{
  "moonshot_api_key": "sk-xxx"
}
```

**完整配置（含钩子脚本）**

```json
{
  "moonshot_api_key": "sk-xxx",
  "dashscope_api_key": "sk-xxx",
  "tavily_api_key": "tvly-xxx",

  "hooks": {
    "post_restore": "#!/bin/bash\nnode -e \"...sanitize openclaw.json...\"",
    "pre_start": "#!/bin/bash\nrm -rf /home/user/capy/.openclaw/extensions 2>/dev/null || true",
    "periodic": {
      "command": "#!/bin/bash\nnode -e \"...clean plugins...\"",
      "interval_seconds": 60
    }
  }
}
```

### 2.2 时序要求

```
create_sandbox()（含 NAS 挂载配置）
    │
    ├─ 沙箱启动（nas-init 开始轮询 /tmp/claw-config.json）
    │
    ├─ 后端调用 write_file("/tmp/claw-config.json", ...)  ← 必须在 60s 内完成
    │
    ├─ nas-init 读取配置 → 确保 openclaw.json 存在 → 执行钩子 → 注入 API key → exit 0
    │
    └─ openclaw 启动（读取 NAS 上已有的配置，或使用镜像默认配置）
```

**关键约束**：`write_file` 必须在沙箱启动后 **60 秒内** 完成，否则 nas-init 超时退出，OpenClaw 将使用镜像默认配置启动（API key 不会注入）。

## 3. 配置字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `moonshot_api_key` | string | 否 | Moonshot/Kimi API Key，注入到 `models.providers.moonshot.apiKey` |
| `dashscope_api_key` | string | 否 | DashScope API Key，用于 embedding（memory search） |
| `tavily_api_key` | string | 否 | Tavily API Key，用于 web search |
| `hooks.post_restore` | string | 否 | bash 脚本，API key 注入前执行，用于清理不兼容配置 |
| `hooks.pre_start` | string | 否 | bash 脚本，nas-init exit 0 前执行，用于最终清理 |
| `hooks.periodic.command` | string | 否 | bash 脚本，OpenClaw 运行期间按间隔循环执行 |
| `hooks.periodic.interval_seconds` | int | 否 | periodic 间隔秒数，默认 60 |

所有字段均为可选。空 JSON `{}` 也是合法的 config，nas-init 会直接退出。

## 4. 生命周期行为

### 首次创建

```
沙箱启动 + NAS 挂载（目录为空）
  → nas-init: 检测到 openclaw.json 不存在，从 /app/openclaw-defaults/ 拷贝默认配置
  → nas-init: 执行 hooks，注入 API key
  → openclaw 启动（读取 NAS 上的 openclaw.json，内容为镜像默认 + API key 注入后的结果）
  → 用户操作产生的数据直接写入 NAS 上的目录
```

### 重建/恢复（沙箱销毁后重新创建）

```
沙箱重建 + 挂载同一 NAS 目录
  → nas-init: 执行 hooks（如清理旧的脏配置），注入 API key
  → openclaw 启动（读取 NAS 上的 openclaw.json，历史配置和数据完整恢复）
```

### 沙箱销毁

```
沙箱直接终止
  → NAS 上的文件不受影响（原生挂载，无延迟同步）
  → 数据零丢失
```

## 5. 后端代码示例

### Python（伪代码）

```python
import json

async def provision_claw(user_id: int, claw_id: int, env: str = "prod"):
    # 1. 创建沙箱（平台 API 处理 NAS 挂载）
    sandbox = await create_sandbox(
        template="openclaw-template",
        nas_mount={
            "nas_addr": "0b8654bd8f-oxi11.cn-hangzhou.nas.aliyuncs.com",
            "nas_dir": f"/{env}/users/{user_id}/claws/{claw_id}",
            "mount_path": "/home/user/capy/.openclaw",
        }
    )

    # 2. 写入运行时配置（必须在 60s 内）
    config = {
        "moonshot_api_key": get_user_moonshot_key(user_id),
        "dashscope_api_key": settings.dashscope_api_key,
        "tavily_api_key": settings.tavily_api_key,
        "hooks": _build_hooks(),
    }
    await sandbox.write_file(
        path="/tmp/claw-config.json",
        content=json.dumps(config),
    )

    # 3. 等待 OpenClaw 就绪
    await wait_for_healthz(sandbox_id=sandbox.id, timeout=90)
    await db.update_claw_status(claw_id, "running")


def _build_hooks() -> dict:
    return {
        "post_restore": POST_RESTORE_HOOK,
        "pre_start": PRE_START_HOOK,
        "periodic": {
            "command": PERIODIC_HOOK,
            "interval_seconds": 60,
        },
    }


POST_RESTORE_HOOK = r"""#!/bin/bash
node -e "
const fs=require('fs'),p='/home/user/capy/.openclaw/openclaw.json';
try{
  const c=JSON.parse(fs.readFileSync(p,'utf8'));
  let d=false;
  if(c.tools&&c.tools.browser){delete c.tools.browser;d=true}
  if(c.plugins&&c.plugins.entries){c.plugins.entries={};d=true}
  if(c.plugins&&c.plugins.installs){c.plugins.installs={};d=true}
  if(d){fs.writeFileSync(p,JSON.stringify(c,null,2));console.log('sanitized')}
  else{console.log('ok')}
}catch(e){console.log('skip:'+e.message)}
"
"""

PRE_START_HOOK = r"""#!/bin/bash
rm -rf /home/user/capy/.openclaw/extensions 2>/dev/null || true
"""

PERIODIC_HOOK = r"""#!/bin/bash
node -e "
const fs=require('fs'),p='/home/user/capy/.openclaw/openclaw.json';
try{
  const c=JSON.parse(fs.readFileSync(p,'utf8'));
  let d=false;
  if(c.plugins&&c.plugins.entries&&Object.keys(c.plugins.entries).length){
    c.plugins.entries={};d=true
  }
  if(d){fs.writeFileSync(p,JSON.stringify(c,null,2));console.log('cleaned plugins')}
}catch(e){}
"
"""
```

### 不使用 NAS（临时沙箱）

```python
async def provision_temp_claw():
    sandbox = await create_sandbox(template="openclaw-template")

    # 不挂 NAS，只注入 API key
    config = {"moonshot_api_key": settings.default_moonshot_key}
    await sandbox.write_file(
        path="/tmp/claw-config.json",
        content=json.dumps(config),
    )
    return sandbox
```

## 6. 监控与排障

### 查看进程日志

```bash
# 在沙箱内
process-compose process logs nas-init
process-compose process logs openclaw
```

### 正常日志示例

```
[nas-init] 07:47:22 Config received after 3s
[nas-init] 07:47:22 openclaw.json missing in NAS dir, copying from image defaults
[nas-init] 07:47:22 Running hook: post_restore
[nas-init] 07:47:22 [hook:post_restore] sanitized
[nas-init] 07:47:22 Hook post_restore finished (exit=0)
[nas-init] 07:47:22 Injecting API keys into openclaw.json
[nas-init] 07:47:22 Running hook: pre_start
[nas-init] 07:47:22 Hook pre_start finished (exit=0)
[nas-init] 07:47:22 Done
```

### 异常场景

| 日志 | 含义 | 处理 |
|------|------|------|
| `Timeout waiting for config` | 60s 内未收到 config | 检查 write_file 是否及时调用 |
| `openclaw.json missing in NAS dir, copying from image defaults` | NAS 挂载后目录为空，首次启动 | 正常，已自动从镜像默认配置拷贝 |
| `WARN: openclaw.json not found` | 默认配置备份也不存在 | 异常，检查镜像是否包含 `/app/openclaw-defaults/` |
| `WARN: Failed to inject API keys` | `openclaw.json` 格式异常 | 检查钩子是否破坏了 JSON |

## 7. 注意事项

1. **write_file 时机**：必须在沙箱启动后 60 秒内写入，越早越好
2. **NAS 挂载路径**：固定挂载到 `/home/user/capy/.openclaw`，后端不可修改
3. **路径唯一性**：同一个 NAS 目录不要给多个同时运行的沙箱挂载
4. **数据零丢失**：原生挂载无同步延迟，沙箱销毁时数据已在 NAS 上
5. **钩子幂等性**：钩子脚本可能在每次沙箱重建时执行，需保证幂等
