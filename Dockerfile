# Telegram 消息中继
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY relay/ ./relay/

# 运行时需挂载（见 docker-compose.yml）：
#   ./config.json -> /app/config.json (只读)   主配置
#   ./data        -> /app/data                 Telethon 会话 / 死信队列 / 日志
#                                             （持久化：重启容器无需重新登录）
# 敏感参数由 docker-compose.yml 的 env_file: .env 自动注入。
CMD ["python", "-m", "relay.main"]
