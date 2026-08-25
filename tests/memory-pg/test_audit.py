from __future__ import annotations

from pathlib import Path

from conftest import write_memory  # noqa: E402

from memory_pg import audit, config, importer  # noqa: E402


def _cfg():
    return config.load(use_test_db=True)


def test_overdue_and_orphan(conn, home: Path):
    g = home / "memory"
    write_memory(g, "past-due", "已過期", review_by="2020-01-01")
    write_memory(g, "linked", "被連", pin="true")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    rep = audit.run(conn, _cfg())
    codes = {(f.level, f.code) for f in rep.findings}
    assert ("WARN", "overdue") in codes
    assert ("SUGGEST", "orphan") in codes   # past-due 無 inbound、非 pin
    assert rep.has_warn


def test_claude_md_dangling_ignores_subcommands(conn, home: Path):
    # CLAUDE.md 引用 `memory search`/`memory write` 等子命令，不該被當成 dangling 記憶引用
    write_memory(home / "memory", "real-global", "真的全域記憶")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    (home / "CLAUDE.md").write_text(
        "用 `memory search \"x\"` 查詢；`memory write` 新增；`memory learn --supersedes`。\n"
        "引用真記憶 `memory real-global`；引用不存在 `memory no-such-mem`。\n",
        encoding="utf-8")
    rep = audit.run(conn, _cfg())
    dangling = {f.detail for f in rep.findings if f.code == "claude_md_dangling"}
    assert "no-such-mem" in dangling          # 真的 dangling 要抓到
    assert "search" not in dangling and "write" not in dangling and "learn" not in dangling
    assert "real-global" not in dangling      # 存在的全域記憶不算 dangling


def test_dup_candidate(conn, home: Path):
    g = home / "memory"
    write_memory(g, "dup-x", "部署主機位址與環境設定的完整說明文件")
    write_memory(g, "dup-y", "部署主機位址與環境設定的完整說明文件")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    rep = audit.run(conn, _cfg())
    assert any(f.code == "dup_candidate" for f in rep.findings)
