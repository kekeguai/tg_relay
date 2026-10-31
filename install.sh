#!/usr/bin/env bash
#
# Telegram 消息中继 · 交互式安装脚本
#
# 行为：
#   1) 交互式询问核心参数（回车采用默认值；默认值取自已存在的 config.json / .env）；
#   2) 非敏感参数写入 config.json（主配置；dest_channels 由逗号串转为数组）；
#   3) 敏感参数（API_ID / API_HASH / RELAY_BOT_TOKEN）写入 .env（0600 权限）；
#      .env 已存在时先询问是否覆盖，绝不静默覆盖；
#   4) 写完后打印配置摘要，敏感字段用 *** 遮挡，供核对。
#
# 依赖：python3（用于生成/校验 JSON）。
# 运行环境：Linux / macOS / WSL / Git Bash。请在项目根目录执行: bash install.sh
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
    echo "错误: 未找到 python3，本脚本需要它生成 config.json" >&2
    exit 1
fi

echo "======================================"
echo "  Telegram 消息中继 · 安装向导"
echo "======================================"

# ---------- 已有 .env：先决定是否覆盖 ----------
OVERWRITE_ENV="no"
if [[ -f .env ]]; then
    echo
    echo "检测到已存在 .env（内含敏感参数）。"
    ans=""
    read -r -p "是否覆盖它？覆盖将丢失旧敏感参数 [y/N]: " ans || ans=""
    if [[ "${ans}" =~ ^[Yy]$ ]]; then
        OVERWRITE_ENV="yes"
    else
        echo ">> 保留现有 .env，敏感参数继续从旧文件读取。"
    fi
fi

# ---------- 默认值工具 ----------
env_default() {   # 从 .env 读取指定键作为默认值
    [[ -f .env ]] || return 0
    sed -n "s/^$1=//p" .env | head -n1
}

json_default() {  # 从 config.json 读取指定键（支持 relay.bot_token 点路径）作为默认值
    [[ -f config.json ]] || return 0
    python3 - "$1" <<'PY'
import json, sys
try:
    cur = json.load(open("config.json", encoding="utf-8"))
    for part in sys.argv[1].split("."):
        if not isinstance(cur, dict) or part not in cur:
            sys.exit(0)
        cur = cur[part]
    if isinstance(cur, list):
        print(",".join(str(x) for x in cur))
    elif cur is not None:
        print(cur)
except Exception:
    pass
PY
}

prompt() {  # prompt "说明" "默认值" -> 回显到 stderr，结果到 stdout
    local reply=""
    read -r -p "$1 [$2]: " reply || reply=""
    echo "${reply:-$2}"
}

# ---------- 交互式询问 ----------
# .env 需要重写时才询问敏感三项；保留旧 .env 时直接沿用旧值，不再打扰
if [[ "$OVERWRITE_ENV" == "yes" || ! -f .env ]]; then
    API_ID="$(prompt "api_id（my.telegram.org -> API development tools，纯数字）" "$(env_default API_ID)")"
    API_HASH="$(prompt "api_hash（同上页面获取）" "$(env_default API_HASH)")"
    BOT_TOKEN="$(prompt "relay.bot_token（@BotFather 颁发的机器人 Token）" "$(env_default RELAY_BOT_TOKEN)")"
else
    API_ID="$(env_default API_ID)"
    API_HASH="$(env_default API_HASH)"
    BOT_TOKEN="$(env_default RELAY_BOT_TOKEN)"
fi

MASTER_ACCOUNT_ID="$(prompt "master_account_id（userbot 主账号数字 ID，可向 @userinfobot 查询）" "$(json_default master_account_id)")"
SOURCE_CHAT="$(prompt "source_chat（源频道/群组的 ID 或 @用户名）" "$(json_default source_chat)")"
TARGET_BOT="$(prompt "target_bot（中继机器人用户名，应与 bot_token 对应，如 @my_relay_bot）" "$(json_default target_bot)")"
DEST_CHANNELS_RAW="$(prompt "dest_channels（目标频道，逗号分隔，可多个）" "$(json_default dest_channels)")"

echo
echo ">> 写入 config.json / .env ..."

export API_ID API_HASH BOT_TOKEN MASTER_ACCOUNT_ID SOURCE_CHAT TARGET_BOT DEST_CHANNELS_RAW
if [[ "$OVERWRITE_ENV" == "yes" || ! -f .env ]]; then
    export WRITE_ENV=1
else
    export WRITE_ENV=0
fi

python3 <<'PY'
import json, os, re, stat
from pathlib import Path

api_id = os.environ.get("API_ID", "").strip()
api_hash = os.environ.get("API_HASH", "").strip()
bot_token = os.environ.get("BOT_TOKEN", "").strip()
master_id = os.environ.get("MASTER_ACCOUNT_ID", "").strip()
source_chat = os.environ.get("SOURCE_CHAT", "").strip()
target_bot = os.environ.get("TARGET_BOT", "").strip()
dest_raw = os.environ.get("DEST_CHANNELS_RAW", "").strip()

if not master_id or not re.fullmatch(r"-?\d+", master_id):
    raise SystemExit("错误: master_account_id 必须是数字（TG 账号 ID），例如 123456789")
if not source_chat:
    raise SystemExit("错误: source_chat 不能为空")
if not target_bot:
    raise SystemExit("错误: target_bot 不能为空")

dest = [x.strip() for x in dest_raw.split(",") if x.strip()]
if not dest:
    raise SystemExit("错误: dest_channels 不能为空")

config = {
    "master_account_id": int(master_id),
    "source_chat": source_chat,
    "target_bot": target_bot if target_bot.startswith("@") else "@" + target_bot,
    "dest_channels": dest,                 # 逗号分隔输入 -> 数组持久化
    "relay": {
        "bot_token": ""                    # 敏感：仅占位，实际值由 .env 的 RELAY_BOT_TOKEN 覆盖
    },
    "delivery": {
        "max_retries": 3,
        "base_delay_seconds": 2,
        "dlq_type": "sqlite",
        "dlq_path": "data/dlq/dead_letters"
    },
    "storage": {
        "session_dir": "data/sessions",
        "tmp_media_dir": "data/tmp_media"
    },
    "logging": {
        "level": "INFO"
    }
}
Path("config.json").write_text(
    json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(">> config.json 已写入")

if os.environ.get("WRITE_ENV") == "1":
    if not re.fullmatch(r"\d+", api_id):
        raise SystemExit("错误: api_id 必须是纯数字（config.json 已生成，.env 可稍后用文本编辑器补写）")
    if not api_hash:
        raise SystemExit("错误: api_hash 不能为空（config.json 已生成，.env 可稍后用文本编辑器补写）")
    if not bot_token:
        raise SystemExit("错误: relay.bot_token 不能为空（config.json 已生成，.env 可稍后用文本编辑器补写）")
    env_text = (
        "# Telegram 消息中继 - 敏感参数（勿提交到版本库）\n"
        f"API_ID={api_id}\n"
        f"API_HASH={api_hash}\n"
        f"RELAY_BOT_TOKEN={bot_token}\n"
    )
    env_path = Path(".env")
    env_path.write_text(env_text, encoding="utf-8")
    try:
        env_path.chmod(stat.S_IRUSR | stat.S_IWUSR)   # 0600，仅属主可读写
    except OSError:
        pass  # Windows 等文件系统不支持时忽略
    print(">> .env 已写入（权限 0600）")
else:
    print(">> .env 未改动（保留原文件）")
PY

# ---------- 配置摘要（敏感字段遮挡，读取落盘后的真实文件） ----------
echo
python3 <<'PY'
import json
from pathlib import Path

def mask(v, keep=4):
    v = v or ""
    return (v[:keep] + "****") if len(v) > keep else "****"

def mask_token(tok):
    if not tok:
        return "****"
    bid, sep, _ = tok.partition(":")
    return (bid + ":****") if sep else "****"

cfg = json.loads(Path("config.json").read_text(encoding="utf-8"))
env = {}
env_path = Path(".env")
if env_path.is_file():
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip()

delivery = cfg.get("delivery") or {}
storage = cfg.get("storage") or {}
print("============== 配置摘要（敏感字段已遮挡） ==============")
print("config.json（主配置）:")
print(f"  master_account_id : {cfg.get('master_account_id')}")
print(f"  source_chat       : {cfg.get('source_chat')}")
print(f"  target_bot        : {cfg.get('target_bot')}")
print(f"  dest_channels     : {', '.join(cfg.get('dest_channels') or [])}")
print(f"  relay.bot_token   : (空占位，实际值来自 .env)")
print(f"  delivery          : 重试 {delivery.get('max_retries')} 次 / 死信 {delivery.get('dlq_type')} @ {delivery.get('dlq_path')}")
print(f"  storage           : 会话 {storage.get('session_dir')} / 临时媒体 {storage.get('tmp_media_dir')}")
print(".env（敏感参数）:")
print(f"  API_ID            : {'***' if env.get('API_ID') else '(缺失，请补写 .env)'}")
print(f"  API_HASH          : {mask(env.get('API_HASH'))}")
print(f"  RELAY_BOT_TOKEN   : {mask_token(env.get('RELAY_BOT_TOKEN'))}")
print("========================================================")
PY

echo
echo "下一步："
echo "  1) 登录主账号生成会话（只需一次）:"
echo "       本地:   python3 -m relay.login        （--list 可查询各会话 ID）"
echo "       Docker: docker compose run --rm relay python -m relay.login"
echo "  2) 启动:   docker compose up -d          （或本地 python3 -m relay.main）"
echo "  3) 自检:   python3 verify.py             （无需 Telethon，验证配置优先级/过滤/重试/死信）"
echo "  4) 死信:   python3 -m relay.dlq list / replay <id>"
