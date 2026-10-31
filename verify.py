"""项目自检脚本（仅标准库，无需安装 Telethon 即可运行）。

覆盖四个不依赖网络/Telethon 客户端的核心机制：
  0) 全部模块语法编译（已安装 Telethon 时额外做导入检查）；
  1) 配置优先级：进程环境变量 > .env > config.json；DEST_CHANNELS 逗号分隔解析；
  2) 过滤规则：/ 命令、🤖 回执、服务消息、空消息；
  3) 投递重试：间隔递增、有限次重试、耗尽返回失败；
  4) 死信队列：sqlite 与 file 两种后端的写入/读取/附件/删除，以及掩码摘要。

用法:  python verify.py
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

PROJECT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PROJECT_ROOT))

PASS = 0


def ok(name: str) -> None:
    global PASS
    PASS += 1
    print(f"  [通过] {name}")


def section(name: str) -> None:
    print(f"\n== {name} ==")


def check_compile_and_import() -> None:
    import compileall
    section("0) 模块编译检查")
    assert compileall.compile_dir(str(PROJECT_ROOT / "relay"), quiet=2), "存在语法错误"
    ok("relay/ 全部模块编译通过")
    try:
        import relay.main  # noqa: F401  需要 telethon
        import relay.listener  # noqa: F401
        import relay.forwarder  # noqa: F401
        import relay.login  # noqa: F401
        ok("已安装 Telethon，客户端模块导入通过")
    except ImportError:
        print("  [跳过] 未安装 Telethon，客户端模块仅做编译检查")


def check_config_priority(tmp: Path) -> None:
    from relay.config import ConfigError, load_config, load_dotenv, summary_text

    section("1) 配置加载优先级（环境变量 > .env > config.json）")
    os.chdir(tmp)
    (tmp / "config.json").write_text(json.dumps({
        "master_account_id": 111222333,
        "source_chat": "-1001234567890",
        "target_bot": "@relay_test_bot",
        "dest_channels": ["-1009998887771", "-1009998887772"],
        "relay": {"bot_token": ""},
        "delivery": {"max_retries": 3, "base_delay_seconds": 2,
                     "dlq_type": "file", "dlq_path": "data/dlq/dead_letters"},
        "storage": {"session_dir": "data/sessions", "tmp_media_dir": "data/tmp_media"},
        "logging": {"level": "INFO"},
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    (tmp / ".env").write_text(
        "API_ID=1234567\n"
        "API_HASH=deadbeefdeadbeefdeadbeefdeadbeef\n"
        "RELAY_BOT_TOKEN=123456789:AAFAKE\n", encoding="utf-8")

    saved_env = {k: os.environ.pop(k, None) for k in
                 ("API_ID", "API_HASH", "RELAY_BOT_TOKEN", "SOURCE_CHAT",
                  "DEST_CHANNELS", "MAX_RETRIES", "MASTER_ACCOUNT_ID",
                  "TARGET_BOT", "BASE_DELAY_SECONDS")}

    load_dotenv()  # 模拟本地裸跑：.env 注入敏感字段
    cfg = load_config()
    assert cfg.api_id == 1234567
    assert cfg.api_hash == "deadbeefdeadbeefdeadbeefdeadbeef"
    assert cfg.relay_bot_token == "123456789:AAFAKE", cfg.relay_bot_token
    assert cfg.dest_channels == ["-1009998887771", "-1009998887772"]
    assert cfg.max_retries == 3
    assert str(cfg.dlq_path).endswith("dead_letters"), cfg.dlq_path  # 后缀由 DLQ 后端补全
    ok("基线加载：敏感字段来自 .env，其余来自 config.json（路径按 config.json 所在目录解析）")

    # 环境变量覆盖同名 config.json 字段；DEST_CHANNELS 按逗号分隔解析
    os.environ["SOURCE_CHAT"] = "@env_override_chat"
    os.environ["DEST_CHANNELS"] = " @a , -100123 ,@b,"
    os.environ["MAX_RETRIES"] = "9"
    cfg2 = load_config()
    assert cfg2.source_chat == "@env_override_chat"
    assert cfg2.dest_channels == ["@a", "-100123", "@b"], cfg2.dest_channels
    assert cfg2.max_retries == 9
    ok("环境变量覆盖 config.json 同名字段；DEST_CHANNELS 逗号分隔 -> 数组")

    # 真实环境变量优先于 .env（load_dotenv 不覆盖已存在变量）
    os.environ["API_ID"] = "7654321"
    load_dotenv()
    assert load_config().api_id == 7654321
    ok("进程环境变量 > .env（.env 不覆盖已存在的环境变量）")

    # 缺失校验
    os.environ["RELAY_BOT_TOKEN"] = ""
    try:
        load_config()
        raise AssertionError("应当抛出 ConfigError")
    except ConfigError as exc:
        assert "relay_bot_token" in str(exc)
        ok(f"缺失校验生效 -> {exc}")
    os.environ["RELAY_BOT_TOKEN"] = "123456789:AAFAKE"

    # 摘要遮挡
    text = summary_text(cfg2)
    assert "AAFAKE" not in text and "123456789:****" in text
    assert "deadbeefdeadbeef" not in text and "dead****" in text
    assert "***" in text  # api_id 整体遮挡
    ok("配置摘要敏感字段已遮挡")

    for k, v in saved_env.items():
        if v is not None:
            os.environ[k] = v


def check_filters() -> None:
    from relay.filters import should_skip, unit_should_skip

    section("2) 过滤规则")
    def msg(text="", media=False, action=None):
        return SimpleNamespace(message=text, media=media, action=action)

    assert should_skip(msg("/start"))[0] and should_skip(msg("/add @x"))[1] == "command"
    ok("/ 开头的命令消息被跳过")
    assert should_skip(msg("🤖 已转发 1 条消息"))[1] == "bot_notice"
    ok("🤖 开头的系统回执被跳过")
    assert should_skip(msg(action=SimpleNamespace()))[1] == "service_message"
    ok("服务消息（入退群等）被跳过")
    assert should_skip(msg())[1] == "empty"
    ok("空消息被跳过")
    assert not should_skip(msg("hello world"))[0]
    assert not should_skip(msg(media=True))[0]
    assert not should_skip(msg("bot：/命令不是开头"))[0]  # 只有开头才算
    ok("普通消息/媒体消息正常放行（仅前缀匹配）")
    # 相册整组判定：caption 出现在任一条上均生效
    assert unit_should_skip([msg(media=True), msg("/cancel")])[0]
    assert not unit_should_skip([msg(media=True), msg("caption 文字")])[0]
    ok("媒体组整组判定（任一条命中则整组跳过）")


def check_delivery() -> None:
    from relay.delivery import RetryDelivery

    section("3) 投递重试（有限次、间隔递增）")

    async def run():
        delays = []
        real_sleep = asyncio.sleep

        async def fake_sleep(d):
            delays.append(d)
            await real_sleep(0)

        calls = {"n": 0}

        async def always_fail():
            calls["n"] += 1
            raise RuntimeError("boom")

        asyncio.sleep = fake_sleep
        try:
            t0 = time.monotonic()
            ok_flag, err = await RetryDelivery(3, 0.1).send("dest", always_fail)
            elapsed = time.monotonic() - t0
        finally:
            asyncio.sleep = real_sleep
        assert not ok_flag and "boom" in (err or "")
        assert calls["n"] == 4, calls  # 首次 + 3 次重试
        assert delays == [0.1, 0.2, 0.4], delays  # 间隔递增
        assert elapsed < 1.0  # fake_sleep 不真实等待
        ok("失败 4 次后停止（首次+3 重试），间隔 0.1s->0.2s->0.4s 递增")

        async def fail_then_succeed():
            calls["n"] += 1
            if calls["n"] < 3:
                raise RuntimeError("flaky")
        calls["n"] = 0
        ok_flag, err = await RetryDelivery(3, 0.01).send("dest", fail_then_succeed)
        assert ok_flag and err is None and calls["n"] == 3
        ok("重试中途成功则返回成功")

    asyncio.run(run())


def check_dlq(tmp: Path) -> None:
    from relay.dlq import FileDLQ, SQLiteDLQ

    section("4) 死信队列（sqlite / file 双后端）")
    record = {
        "created_at": time.time(),
        "source_chat": "-1001234567890",
        "message_ids": [10, 11, 12],
        "grouped_id": 55,
        "dest": "-1009998887771",
        "error": "RuntimeError('boom')",
        "text": "相册说明文字",
        "media_paths": [],
        "meta": {"chat_title": "测试频道", "sender_id": 42, "is_album": True},
    }
    media_src = tmp / "media_src" / "photo.jpg"
    media_src.parent.mkdir(parents=True, exist_ok=True)
    media_src.write_bytes(b"jpeg-bytes")

    for cls in (SQLiteDLQ, FileDLQ):
        q = cls(tmp / f"dlq_{cls.__name__}" / "dead_letters")
        rid = q.push(dict(record))
        got = q.get(rid)
        assert got["dest"] == record["dest"]
        assert got["message_ids"] == [10, 11, 12]
        assert got["meta"]["is_album"] is True
        assert got["media_paths"] == []
        assert q.list(10)[0]["id"] == rid
        # 附件复制进死信区并回写
        q.attach_media(rid, [media_src])
        got = q.get(rid)
        assert len(got["media_paths"]) == 1
        assert Path(got["media_paths"][0]).read_bytes() == b"jpeg-bytes"
        assert Path(got["media_paths"][0]).is_relative_to(q.media_dir)
        # 删除
        assert q.delete(rid) and q.get(rid) is None and not q.delete(rid)
        ok(f"{cls.__name__}: 写入/读取/媒体附件/删除 全链路")


def main() -> None:
    tmp = Path(tempfile.mkdtemp(prefix="tg_relay_verify_"))
    old_cwd = os.getcwd()
    try:
        check_compile_and_import()
        check_config_priority(tmp)
        check_filters()
        check_delivery()
        check_dlq(tmp)
        print(f"\n全部 {PASS} 项检查通过 ✔  （临时目录: {tmp}）")
    except AssertionError as exc:
        print(f"\n自检失败: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        os.chdir(old_cwd)
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
