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


# ---------- Task 8：四 scope 相關的稽核 ----------

def test_audit_forbidden_ref_distinct_from_dangling(conn, home: Path):
    """「目標存在但方向不允許」與「目標不存在」是兩件事，要分開報。

    非撰寫路徑（backfill、import）刻意把前者留成 dangling 而不拋錯，資訊由這裡承接。
    """
    from conftest import seed_banks
    from memory_pg import mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="g-waiting", scope="global", description="等目標的",
                 body="\n引用 [[later]] 與 [[never]]。\n")
    conn.commit()
    mutate.write(conn, _cfg(), name="later", scope="machine", description="本機的", body="\nb\n")
    conn.commit()
    rep = audit.run(conn, _cfg())
    codes = {(f.code, f.detail.split("：")[0]) for f in rep.findings}
    assert any(c == "forbidden_ref" and "later" in d for c, d in codes), codes
    assert any(c == "dangling_ref" and "never" in d for c, d in codes), codes


def test_audit_pinned_work_without_tag_is_warn(conn, home: Path):
    """untagged 且 pinned 的 work → WARN：memory-work/MEMORY.md 不產 PINNED，
    實際不會常駐，列著只會誤導。"""
    from conftest import seed_banks
    from memory_pg import mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="wp", scope="work", description="工作的",
                 body="\nb\n", pin=True)
    conn.commit()
    rep = audit.run(conn, _cfg())
    assert any(f.code == "pinned_work_without_tag" and f.level == "WARN" for f in rep.findings)


def test_audit_work_without_tag_is_suggest(conn, home: Path):
    from conftest import seed_banks
    from memory_pg import mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="wu", scope="work", description="工作的", body="\nb\n")
    conn.commit()
    rep = audit.run(conn, _cfg())
    assert any(f.code == "work_without_tag" and f.level == "SUGGEST" for f in rep.findings)


def test_audit_cross_repo_link_detects_hand_edit(conn, home: Path):
    """手改 bank 加上禁止方向的 wikilink → 要被抓到。

    DB 觸發器擋得住 CLI，擋不住有人直接編輯 bank 檔案；而 import 對禁止方向是留 dangling
    不 abort，所以在下一次 import 之前，唯一會發聲的就是這條檢查。
    """
    from conftest import seed_banks
    from memory_pg import exporter, mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mach", scope="machine", description="本機", body="\nb\n")
    mutate.write(conn, _cfg(), name="glob", scope="global", description="全域", body="\nb\n")
    conn.commit()
    exporter.run(conn, _cfg(), verify_dir=None)
    p = home / "memory" / "glob.md"
    p.write_text(p.read_text(encoding="utf-8") + "\n手改加上 [[mach]]。\n", encoding="utf-8")
    rep = audit.run(conn, _cfg())
    assert any(f.code == "cross_repo_link" for f in rep.findings), \
        [f.code for f in rep.findings]
