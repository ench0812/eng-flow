from __future__ import annotations

from pathlib import Path

from conftest import write_memory  # noqa: E402

from memory_pg import config, importer, session_context  # noqa: E402


def _cfg():
    return config.load(use_test_db=True)


def _seed(conn, home: Path):
    g = home / "memory"
    ip = home / "projects" / "D--Projects-IntelliPark" / "memory"
    write_memory(g, "g-pin", "全域常駐", pin="true")
    write_memory(ip, "ip-pin", "IntelliPark 常駐", pin="true")
    write_memory(ip, "ip-plain", "普通", pin="false")
    write_memory(ip, "ip-soon", "快到期", pin="false",
                 review_by=(__import__("datetime").date.today() + __import__("datetime").timedelta(days=5)).isoformat())
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("UPDATE projects SET is_workspace_root=true WHERE slug='D--Projects-IntelliPark'")
    conn.commit()


def test_render_in_project(conn, home: Path):
    _seed(conn, home)
    text, pk, n = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark")
    assert pk == "D--Projects-IntelliPark"
    # pinned：本專案 + 全域無標籤
    assert "ip-pin" in text and "g-pin" in text
    assert n == 2
    # 不重印全文（只列名字），且註明由 MEMORY.md 載入
    assert "via=\"MEMORY.md\"" in text and "全文已由 MEMORY.md 載入" in text
    # 到期提醒出現
    assert "ip-soon" in text and "到期提醒" in text


def test_render_empty_bank_silent(conn, home: Path):
    # 只有一個空的專案 bank、沒有記憶 → 完全不輸出
    (home / "projects" / "D--Projects-empty" / "memory").mkdir(parents=True)
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    text, pk, n = session_context.render(conn, _cfg(), r"D:\Projects\empty")
    assert text == "" and n == 0


def test_workspace_root_subrepo_resolves(conn, home: Path):
    _seed(conn, home)
    # 在 IntelliPark 子 repo cwd → 仍解析到 IntelliPark，注入 ip-pin
    text, pk, n = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark\pgs-admin")
    assert pk == "D--Projects-IntelliPark" and "ip-pin" in text
