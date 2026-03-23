# Claw 沙箱 NAS 持久化 — 后端接入指南

## 1. 概述

Claw 沙箱通过 NAS（阿里云文件存储）持久化 OpenClaw 的配置、会话记录和工作区文件。后端的职责是：

1. 创建沙箱后，通过 `write_file` API 写入配置文件
2. 管理 NAS 目录结构（按用户/Claw 实例组织）

沙箱内部的 `nas-init` 和 `nas-sync` 进程会自动完成数据恢复和定时同步，后端**无需关心同步细节**。

## 2. 接入步骤

### 2.1 创建沙箱后写入配置

沙箱创建成功后，立即通过 Sandbox API 的 `write_file` 接口写入配置文件：

```
路径: /tmp/claw-config.json
```

#### 启用 NAS（含 API 密钥）

```json
{
  "nas_enabled": true,
  "nas_addr": "0b8654bd8f-oxi11.cn-hangzhou.nas.aliyuncs.com",
  "nas_remote_dir": "/prod/users/42/claws/1",
  "dashscope_api_key": "sk-xxx",
  "tavily_api_key": "tvly-xxx"
}
```

> `dashscope_api_key` 和 `tavily_api_key` 为可选字段，有值时 `nas-init` 会自动注入到 `openclaw.json`。

#### 不启用 NAS

```json
{
  "nas_enabled": false
}
```

### 2.2 时序要求

```
create_sandbox()
    │
    ├─ 沙箱启动（nas-init 开始轮询 /tmp/claw-config.json）
    │
    ├─ 后端调用 write_file("/tmp/claw-config.json", ...)  ← 必须在 60s 内完成
    │
    ├─ nas-init 读取配置 → 从 NAS 恢复数据 → exit 0
    │
    └─ openclaw 启动（读取已恢复的配置）
```

**关键约束**：`write_file` 必须在沙箱启动后 **60 秒内** 完成，否则 nas-init 超时退出，OpenClaw 将使用镜像默认配置（不持久化）。

## 3. 配置字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `nas_enabled` | boolean | 是 | 是否启用 NAS 持久化 |
| `nas_addr` | string | nas_enabled=true 时必填 | NAS 挂载点地址（阿里云 NAS 控制台获取） |
| `nas_remote_dir` | string | nas_enabled=true 时必填 | NAS 远端目录路径，格式见下方 |
| `dashscope_api_key` | string | 否 | DashScope API Key，用于 embedding（memory search） |
| `tavily_api_key` | string | 否 | Tavily API Key，用于 web search |

### `nas_remote_dir` 路径格式

```
/{env}/users/{user_id}/claws/{claw_id}
```

| 段 | 说明 | 示例 |
|-----|------|------|
| `{env}` | 环境标识，隔离测试/生产数据 | `test`, `prod` |
| `{user_id}` | 用户 ID | `42` |
| `{claw_id}` | Claw 实例 ID | `1`, `abc123` |

示例：
- 测试环境：`/test/users/42/claws/1`
- 生产环境：`/prod/users/42/claws/1`

## 4. NAS 目录结构

后端**不需要**预先创建目录，`nas-init` 会自动通过 `nfs-tool mkdirp` 递归创建。

```
NAS 根目录 (/)
├── test/
│   └── users/
│       └── {user_id}/
│           └── claws/
│               └── {claw_id}/
│                   └── repo.bundle    ← 自动生成的 git bundle 文件
└── prod/
    └── users/
        └── ...（同上）
```

每个 Claw 实例在 NAS 上只有**一个文件** `repo.bundle`，包含完整的 OpenClaw 数据和版本历史。

## 5. 生命周期行为

### 首次创建

```
write_file(nas_enabled=true)
  → nas-init: NAS 上无 bundle
  → 将镜像默认配置初始化为 git 仓库
  → 上传初始 bundle 到 NAS
  → openclaw 启动
```

### 重建/恢复（沙箱销毁后重新创建）

```
write_file(nas_enabled=true, 同一 nas_remote_dir)
  → nas-init: 从 NAS 下载 bundle
  → git clone 恢复完整数据
  → openclaw 启动（配置、会话自动恢复）
```

### 运行中

```
nas-sync 每 30 秒检查一次：
  → 有变更：git commit + bundle + 原子上传到 NAS
  → 无变更：跳过
```

### 沙箱销毁

```
沙箱直接终止（无优雅停止）
  → NAS 上的 bundle 不受影响
  → 最多丢失最后 30 秒内的未同步变更
```

### NAS 禁用

```
write_file(nas_enabled=false)
  → nas-init 立即退出
  → nas-sync 立即退出
  → openclaw 使用镜像内置默认配置
  → 沙箱销毁后数据丢失
```

## 6. 后端代码示例

### Python (伪代码)

```python
import json

def create_claw_sandbox(user_id: int, claw_id: str, env: str = "prod"):
    # 1. 创建沙箱
    sandbox = agentrun.create_sandbox(
        template="claw-template",
        image="claw:1.9",
        env_vars={
            "MOONSHOT_API_KEY": get_user_api_key(user_id),
        }
    )

    # 2. 写入 NAS 配置（必须在 60s 内）
    nas_config = {
        "nas_enabled": True,
        "nas_addr": "0b8654bd8f-oxi11.cn-hangzhou.nas.aliyuncs.com",
        "nas_remote_dir": f"/{env}/users/{user_id}/claws/{claw_id}",
    }

    sandbox.write_file(
        path="/tmp/claw-config.json",
        content=json.dumps(nas_config),
    )

    return sandbox
```

### 不使用 NAS（临时沙箱）

```python
def create_temp_sandbox():
    sandbox = agentrun.create_sandbox(template="claw-template")

    sandbox.write_file(
        path="/tmp/claw-config.json",
        content=json.dumps({"nas_enabled": False}),
    )

    return sandbox
```

## 7. 环境变量

沙箱创建时可通过模板环境变量配置：

| 环境变量 | 说明 | 默认值 |
|---------|------|--------|
| `MOONSHOT_API_KEY` | Kimi/Moonshot API Key | 无 |
| `OPENCLAW_SKIP_CHANNELS` | 禁用 channel 功能 | `0`（启用） |

## 8. 监控与排障

### 检查 NAS 同步状态

在沙箱内查看进程日志：

```bash
# 查看 nas-init 日志（一次性，恢复是否成功）
process-compose process logs nas-init

# 查看 nas-sync 日志（持续运行，同步是否正常）
process-compose process logs nas-sync
```

### 正常日志示例

```
[nas-init] 07:47:22 Config received after 3s
[nas-init] 07:47:22 NAS: 0b8654bd8f-oxi11..., remote: /prod/users/42/claws/1
[nas-init] 07:47:23 Bundle downloaded, restoring...
[nas-init] 07:47:23 Restored from NAS (15 commits)
[nas-init] 07:47:23 Done

[nas-sync] 07:47:53 Synced (245760 bytes, 16 commits)
[nas-sync] 07:48:23 Synced (245891 bytes, 17 commits)
```

### 异常场景

| 日志 | 含义 | 影响 |
|------|------|------|
| `Timeout waiting for config` | 60s 内未收到 claw-config.json | OpenClaw 用默认配置启动，不持久化 |
| `NAS disabled, skipping` | nas_enabled=false | 正常，不使用 NAS |
| `No bundle on NAS, first time setup` | 该 Claw 实例首次创建 | 正常，自动初始化 |
| `Bundle corrupted` | NAS 上的 bundle 损坏 | 回退到首次初始化（历史数据丢失） |
| `upload failed, will retry` | NAS 写入失败 | 下个周期重试，不影响运行 |

### 手动验证 NAS 连通性

```bash
# 在沙箱内
nfs-tool <NAS地址> ls /
nfs-tool <NAS地址> ls /prod/users/42/claws/1
```

## 9. 注意事项

1. **write_file 时机**：必须在沙箱启动后 60 秒内写入，越早越好
2. **NAS 地址**：使用阿里云 NAS 的 VPC 内网挂载点地址
3. **路径唯一性**：同一个 `nas_remote_dir` 不要给多个同时运行的沙箱使用
4. **数据丢失窗口**：沙箱被销毁时最多丢失最后 30 秒的变更
5. **NAS 容量**：每个 Claw 实例占用空间取决于使用量，通常 1-100MB
