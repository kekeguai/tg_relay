<div align="center">

# TG Relay · Telegram 消息无痕中继

基于 **Telethon + Python 标准库** 的频道/群组消息中继工具：
userbot 监听源会话的新消息，由中继机器人以「全新消息」重新投递到目标频道 —— **不带“转发自”标签**。

![Python](https://img.shields.io/badge/Python-3.11%2B-3776AB?logo=python&logoColor=white)
![Telethon](https://img.shields.io/badge/Telethon-1.34%2B-2CA5E0)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![Dependencies](https://img.shields.io/badge/%E7%AC%AC%E4%B8%89%E6%96%B9%E4%BE%9D%E8%B5%96-%E4%BB%85%20Telethon-brightgreen)

</div>

---

## 📖 项目介绍

**TG Relay** 解决一个常见需求：把一个频道/群组的内容自动同步到另一个（或多个）频道，
但不要 Telegram 默认转发功能那个显眼的「Forwarded from」头。

它的工作方式是「**双客户端接力**」：

```
source_chat ──新消息──> [userbot 监听] ──过滤──> [相册聚合] ──> [重试投递] ──> relay bot ──> dest_channels
                 master_account          │                                      ▲        ├─ dest 1
                                         │ 跳过 /命令、🤖回执                    │        ├─ dest 2
                                         └──────── 重试耗尽 ──> 死信队列(SQLite/文件)      └─ ...
                                                  （媒体一并存档，可事后重放）
```

| 角色 | 凭据 | 职责 |
|---|---|---|
| **userbot（主账号）** | Telethon 会话文件 | 监听 `source_chat` 新消息；为受限频道下载媒体 |
| **中继机器人** | `RELAY_BOT_TOKEN` | 把内容作为**自己的新消息**发送到各 `dest_channels` |

全程不调用 `forward_messages`：文本直接重发（保留加粗/链接等格式），媒体先由主账号下载、
再由机器人重新上传——这也是**受限频道（受保护内容）**同样可中继的原因。

## ✨ 功能概览

| 功能 | 说明 |
|---|---|
| 📡 指定源监听 | 监听 `source_chat`（频道或群组）的新消息，ID 或 @用户名均可 |
| 🕶️ 无痕转发 | 重发内容而非转发，去除「转发自」标签；文本保留 Markdown 实体 |
| 🖼️ 相册聚合 | 媒体组（一次多图）整组收齐后**一条相册消息**发出，不拆散 |
| 🔒 受限频道支持 | 受保护内容的媒体经主账号下载后重新上传 |
| 🧹 智能过滤 | 自动跳过 `/` 开头的命令、`🤖` 开头的系统回执、服务消息与空消息 |
| 🔁 可靠投递 | 每个目标独立重试（默认 3 次，间隔 2s→4s→8s 递增），互不影响 |
| ⚰️ 死信队列 | 重试耗尽后落盘（SQLite 默认 / JSONL 文件可选），媒体一并存档，支持查看与重放 |
| 🔐 配置分层 | `config.json` 主配置 + `.env`/环境变量覆盖；敏感参数只进 `.env` |
| 🐳 Docker 部署 | `env_file` 自动注入环境；会话挂载宿主机，重启免重新登录 |
| 🩺 自带自检 | `verify.py` 无需 Telethon 即可验证配置优先级/过滤/重试/死信四大机制 |

## 🚀 一键安装

### 前置准备（3 分钟）

| 准备项 | 获取方式 |
|---|---|
| `api_id` / `api_hash` | [my.telegram.org](https://my.telegram.org) → API development tools |
| 中继机器人 Token | 向 [@BotFather](https://t.me/BotFather) 创建机器人获取 |
| 机器人管理员权限 | **把机器人加为每个目标频道的管理员**（需可发消息）|
| 主账号加入源会话 | 运行 userbot 的账号必须能看到 `source_chat` 的消息 |
| `master_account_id` | 向 [@userinfobot](https://t.me/userinfobot) 发消息查询数字 ID |

### 方式一：Docker（推荐）

```bash
git clone https://github.com/kekeguai/tg_relay.git
cd tg_relay

bash install.sh                                        # ① 交互式生成 config.json + .env
docker compose run --rm relay python -m relay.login    # ② 首次登录主账号（仅一次，会话持久化）
docker compose up -d                                   # ③ 启动
docker compose logs -f                                 #    查看日志
```

### 方式二：本地运行（Python 3.11+）

```bash
git clone https://github.com/kekeguai/tg_relay.git
cd tg_relay

pip install -r requirements.txt
bash install.sh                 # ① 交互式配置（Linux / macOS / WSL / Git Bash）
python3 -m relay.login          # ② 首次登录主账号（交互式：手机号 → 验证码）
python3 -m relay.main           # ③ 启动
```

> 安装脚本支持重复运行：回车沿用已有默认值；`.env` 已存在时**先询问是否覆盖**，
> 绝不静默覆盖；写完打印敏感字段遮挡（`***`）的配置摘要供核对。

### 安装后自检（可选但建议）

```bash
python3 verify.py    # 无需 Telethon：验证配置优先级 / 过滤规则 / 重试退避 / 死信读写
```

## ⚙️ 配置说明

### config.json（主配置，非敏感）

```jsonc
{
  "master_account_id": 123456789,               // userbot 主账号数字 ID
  "source_chat": "-1001234567890",              // 源频道/群组（ID 或 @用户名）
  "target_bot": "@my_relay_bot",                // 中继机器人用户名（应与 bot_token 对应）
  "dest_channels": ["-1009876543210", "@dest"], // 目标频道数组，可多个
  "relay": { "bot_token": "" },                 // 空占位：实际值由 .env 的 RELAY_BOT_TOKEN 覆盖
  "delivery": {
    "max_retries": 3,                           // 首次失败后的重试次数
    "base_delay_seconds": 2,                    // 退避基数：2s → 4s → 8s 递增
    "dlq_type": "sqlite",                       // 死信后端：sqlite | file
    "dlq_path": "data/dlq/dead_letters"
  },
  "storage": { "session_dir": "data/sessions", "tmp_media_dir": "data/tmp_media" },
  "logging": { "level": "INFO" }
}
```

### .env（敏感参数，勿提交版本库，权限 0600）

```ini
API_ID=1234567
API_HASH=0123456789abcdef0123456789abcdef
RELAY_BOT_TOKEN=123456789:AAHxxxxxxxxxxxxxxxx
```

### 加载优先级

```
进程环境变量（compose env_file 注入 / shell export）
        ▼  覆盖
项目根目录 .env（本地裸跑时自动加载，不覆盖已存在的环境变量）
        ▼  覆盖
config.json
```

环境变量与配置字段同名映射（`relay/config.py` 的 `ENV_MAP`）：

| 环境变量 | 对应字段 | 备注 |
|---|---|---|
| `API_ID` / `API_HASH` | api_id / api_hash | 仅应出现在 .env |
| `RELAY_BOT_TOKEN` | relay.bot_token | 仅应出现在 .env |
| `MASTER_ACCOUNT_ID` / `SOURCE_CHAT` / `TARGET_BOT` | 同名字段 | |
| `DEST_CHANNELS` | dest_channels | **逗号分隔** → 自动解析为数组 |
| `MAX_RETRIES` / `BASE_DELAY_SECONDS` | delivery.* | |

**验证覆盖是否生效**——启动摘要会打印“当前生效配置”，环境变量改过的字段直接可见：

```bash
MAX_RETRIES=9 python3 -m relay.main     # 摘要显示 9（config.json 是 3）即证明 env > config.json
DEST_CHANNELS=@test_channel python3 -m relay.config   # 不启动客户端，仅查看合并结果
```

## 📁 项目结构

```
tg_relay/
├── install.sh               # 交互式安装脚本（生成 config.json 与 .env，遮挡摘要）
├── verify.py                # 自检脚本（仅标准库，无需 Telethon）
├── requirements.txt         # 唯一第三方依赖：telethon
├── Dockerfile               # python:3.11-slim
├── docker-compose.yml       # env_file 注入；config.json 与 data/ 挂载持久化
├── config.example.json      # 主配置样例
├── .env.example             # 敏感参数样例
├── .gitignore               # 忽略 .env / config.json / data/
└── relay/                   # 源码包（模块职责单一）
    ├── main.py              # 入口：装配配置/客户端/监听/转发/投递/死信，启动身份校验
    ├── config.py            # 配置：config.json + 环境变量/.env 覆盖（含掩码摘要）
    ├── filters.py           # 过滤：跳过 / 命令与 🤖 回执（纯判定，无 IO）
    ├── listener.py          # 监听：userbot 监听 source_chat；NewMessage + Album 相册聚合
    ├── forwarder.py         # 转发：主账号下载媒体 → 机器人重新上传（无痕）
    ├── delivery.py          # 投递可靠性：有限次重试、间隔递增（指数退避）
    ├── dlq.py               # 死信队列：SQLite/JSONL 双后端 + list/replay/delete CLI
    ├── models.py            # 监听 → 转发之间传递的数据单元
    └── login.py             # 主账号交互式登录（--list 可查询各会话 ID）
```

## 🔍 功能验证指南

<details>
<summary><b>验证：环境变量覆盖 config.json（点击展开）</b></summary>

```bash
# 本地：临时覆盖一个无害字段
MAX_RETRIES=9 python3 -m relay.main          # 摘要中 max_retries=9 即生效
# PowerShell:  $env:MAX_RETRIES=9; python -m relay.main

# Docker：往 .env 加一行 MAX_RETRIES=9 → docker compose up -d → 看日志摘要
```
</details>

<details>
<summary><b>验证：相册聚合转发（点击展开）</b></summary>

1. 建私有小群作 `source_chat`，主账号拉入；目标频道把**机器人设为管理员**；
2. 启动中继后，在源群**一次性选中 2~4 张照片发送**（构成媒体组）；
3. 预期：目标频道收到**一条相册消息**（多图并排、单一说明、发送者为机器人、无“转发自”头）；
   日志出现 `收到相册: ... ids=11,12,13` 与 `已中继 -> ...`；
4. 顺带验证过滤：发 `/start`、`🤖测试回执` → 均应被跳过。
</details>

<details>
<summary><b>验证：死信队列（点击展开）</b></summary>

把 `dest_channels` 临时改成一个机器人无权限的频道 → 发消息 → 观察日志
`投递 ... 失败（第 x/3 次）`（间隔递增）→ 耗尽后 `死信 #N 已写入`：

```bash
python3 -m relay.dlq list          # 查看死信（含媒体条目）
python3 -m relay.dlq replay 1      # 给机器人授权后重放，成功后自动删除
python3 -m relay.dlq delete 1      # 手动删除
```
</details>

## ❓ 常见问题

<details>
<summary>报错「无法解析 source_chat」？</summary>

主账号未加入该频道/群组，或 ID/用户名写错。用 `python3 -m relay.login --list`
查看账号可见的所有会话及其 ID。
</details>

<details>
<summary>机器人发送报 403？</summary>

机器人不是该目标频道的管理员，或没有发消息权限。把机器人加为管理员并勾选发送权限。
</details>

<details>
<summary>容器重启后要求重新登录？</summary>

确认 `./data` 目录挂载正常且未被清空——会话文件在 `data/sessions/master.session`。
</details>

<details>
<summary>受限频道也能中继吗？</summary>

可以。只要主账号能正常查看该频道内容；媒体走「主账号下载 → 机器人重新上传」路径。
</details>

## ⚠️ 安全须知与已知限制

- `.env` 与 `data/` **严禁提交到版本库**（`.gitignore` 已覆盖）；`master.session` 等于账号登录凭证，
  泄露请立即在 Telegram 官方客户端「终止所有其他会话」；
- 单条超过 4096 字符的文本未做分片（会走重试 → 死信）；
- 贴纸等特殊媒体重新上传后类型可能变化（语音条已做 `voice_note` 保留，相册已聚合）；
- 投票等不可下载的媒体会以文字占位（`[无法中继的媒体类型: ...]`）连同说明文字转发。

---

<div align="center">

用 Telethon 构建 · 仅供个人学习与自用自动化

</div>
