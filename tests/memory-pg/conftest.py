"""DB 測試共用 fixture。

需要 ~/.claude/memory-pg/.env 的 MEMORY_PG_TEST_DSN 且容器在跑；連不上就整組 skip 並明講。
每個測試前 TRUNCATE 所有表（schema 由 migrate 維持）。
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "scripts" / "memory-pg"))


@pytest.fixture(scope="session")
def test_dsn() -> str:
    from memory_pg import config

    try:
        cfg = config.load(use_test_db=True)
    except Exception as e:  # noqa: BLE001
        pytest.skip(f"無測試 DSN：{e}")
    return cfg.dsn


@pytest.fixture
def conn(test_dsn):
    import psycopg

    from memory_pg import migrate

    try:
        c = psycopg.connect(test_dsn, connect_timeout=3)
    except psycopg.OperationalError as e:
        pytest.skip(f"測試 DB 連不上：{str(e).splitlines()[0]}")
    migrate.apply(c)
    with c.cursor() as cur:
        cur.execute(
            "TRUNCATE memory_access_log, memory_revisions, memory_sources, memory_links, "
            "memory_projects, memories, projects, embedding_config RESTART IDENTITY CASCADE"
        )
    c.commit()
    yield c
    if not c.closed:          # 有測試會刻意 close 來驗證跨連線持久化
        c.rollback()
        c.close()


@pytest.fixture
def home(tmp_path: Path, monkeypatch, test_dsn: str) -> Path:
    """一個獨立的 CLAUDE_HOME，含空的 memory/ 與 projects/。
    CLAUDE_HOME 改掉後 .env 就找不到了，所以 DSN 改由環境變數帶入（config.load 以環境變數優先）。"""
    h = tmp_path / "claude-home"
    (h / "memory").mkdir(parents=True)
    (h / "projects").mkdir()
    monkeypatch.setenv("CLAUDE_HOME", str(h))
    monkeypatch.setenv("MEMORY_PG_TEST_DSN", test_dsn)
    monkeypatch.setenv("MEMORY_PG_DSN", test_dsn)
    return h


def write_memory(bank: Path, name: str, description: str, body: str = "\n正文。\n", **meta) -> Path:
    bank.mkdir(parents=True, exist_ok=True)
    lines = ["---", f"name: {name}", f"description: {description}", "metadata: "]
    for k, v in meta.items():
        lines.append(f"  {k}: {v}")
    text = "\n".join(lines) + "\n---" + body
    p = bank / f"{name}.md"
    p.write_text(text, encoding="utf-8", newline="")
    return p
