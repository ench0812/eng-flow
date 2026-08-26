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
def conn(test_dsn, monkeypatch, tmp_path):
    """DB 連線。**同時**把 DSN 與 CLAUDE_HOME 釘在測試側。

    `cli.main()` 走 `config.load(use_test_db=args.test_db)`，測試不帶 --test-db，所以擋住它連上
    正式記憶庫的只有環境變數。本套已有 CLI 層的 mutating 測試（會 write/edit 並由 _auto_export
    寫檔），要是有人寫 `def test_x(conn, tmp_path)` 忘了帶 `home`，那次執行就會改到使用者真正的
    記憶庫並覆寫真實 bank——破壞性操作的目標要在測試層釘死（安全鐵律 5）。

    釘在 `conn` 而不是 autouse：`test_differential_real_memories` 刻意要讀**真實** CLAUDE_HOME
    的記憶檔跟 awk 對差分，autouse 會把它變成永遠 skip（實測踩過一次）。它不用 conn，正好分得開。
    需要 bank 目錄的測試照樣帶 `home` fixture，它會再覆寫成自己的目錄，兩者不衝突。
    """
    import psycopg

    from memory_pg import migrate

    h = tmp_path / "conn-claude-home"
    (h / "memory").mkdir(parents=True, exist_ok=True)
    (h / "projects").mkdir(exist_ok=True)
    monkeypatch.setenv("CLAUDE_HOME", str(h))
    monkeypatch.setenv("MEMORY_PG_DSN", test_dsn)
    monkeypatch.setenv("MEMORY_PG_TEST_DSN", test_dsn)

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
    real_home = Path.home() / ".claude"
    try:
        yield c
    finally:
        # 連線一定要先關——teardown 裡先拋錯會讓連線洩漏，累積到 PG 連線數上限後
        # 整個測試套件會卡在下一次 connect（實測踩過）。
        if not c.closed:          # 有測試會刻意 close 來驗證跨連線持久化
            c.rollback()
            c.close()
        # 不變量：測試結束時 CLAUDE_HOME 不可以指回【真實的】記憶庫。
        # 實測 2026-08-26：`monkeypatch.undo()` 會撤銷該測試的所有 monkeypatch，包含
        # fixture 釘的 CLAUDE_HOME，於是測試後半寫進真實的 ~/.claude/memory-work——
        # 而且還「通過」，因為它在真實 home 裡找到了那個檔案。假通過比失敗更糟。
        # 這裡只驗「不是真實 home」，不驗「等於某個特定值」：home fixture 會在 conn 之後
        # 再覆寫一次，兩者都是合法的測試用目錄。
        actual = os.environ.get("CLAUDE_HOME")
        if actual and Path(actual).resolve() == real_home.resolve():
            raise AssertionError(
                "CLAUDE_HOME 在測試中被改回真實的 ~/.claude——這條路徑會寫到真實記憶庫。"
                "若用了 monkeypatch.undo()，改成只還原你自己設定的那一項")


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


def seed_banks(home):
    """建出 machine / work 兩個 bank 目錄。

    寫入面對這兩個 scope 會先檢查 bank presence（not_installed 一律拒寫），所以任何
    會 write machine/work 的測試都要先建目錄，否則得到的是 exit 2 而不是預期的行為。
    """
    for d in ("memory-machine", "memory-work"):
        (home / d).mkdir(parents=True, exist_ok=True)
