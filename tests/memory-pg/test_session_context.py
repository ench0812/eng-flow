from __future__ import annotations

import datetime as dt
from pathlib import Path

from conftest import seed_banks, write_memory  # noqa: E402

from memory_pg import config, importer, session_context  # noqa: E402
from memory_pg.audit import AuditReport, Finding  # noqa: E402


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
    text, pk, pinned = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark")
    assert pk == "D--Projects-IntelliPark"
    # pinned：本專案 + 全域無標籤
    assert "ip-pin" in text and "g-pin" in text
    assert set(pinned) == {"ip-pin", "g-pin"}
    # 不重印全文（只列名字），且註明由 MEMORY.md 載入
    assert "via=\"MEMORY.md\"" in text and "全文已由 MEMORY.md 載入" in text
    # 到期提醒出現
    assert "ip-soon" in text and "到期提醒" in text


def test_render_empty_bank_silent(conn, home: Path):
    # 只有一個空的專案 bank、沒有記憶 → 完全不輸出
    (home / "projects" / "D--Projects-empty" / "memory").mkdir(parents=True)
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    text, pk, pinned = session_context.render(conn, _cfg(), r"D:\Projects\empty")
    assert text == "" and pinned == []


def test_workspace_root_subrepo_resolves(conn, home: Path):
    _seed(conn, home)
    # 在 IntelliPark 子 repo cwd → 仍解析到 IntelliPark，注入 ip-pin
    text, pk, pinned = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark\pgs-admin")
    assert pk == "D--Projects-IntelliPark" and "ip-pin" in pinned


# --- 到期提醒的三個缺口（2026-08-27，codex 跨家族複查逼出來的）-----------------
#
# 背景：到期提醒原本只查 review_by BETWEEN today AND today+14，逾期項掉出下界，
# 只能靠 audit 的 overdue WARN 兜底。但那條兜底有兩個獨立的失效途徑：
#   1. session_context 過濾 audit finding 時用 `\<pk>\ in path`，而 machine/global/work
#      的 bank 路徑（memory-machine / memory / memory-work）不含任何專案 slug，
#      在任何 project session 下必被過濾掉 → 這三個 scope 根本沒有兜底。
#   2. audit.run() 外面包著 `except Exception: pass`，一失敗就靜默吞掉全部 finding。
# 所以逾期項改由 soon 直接涵蓋，兜底只當第二層。


def test_overdue_memory_still_reminded(conn, home: Path):
    """逾期的記憶要繼續提醒，而且文案不能出現負數天數。"""
    _seed(conn, home)
    ip = home / "projects" / "D--Projects-IntelliPark" / "memory"
    write_memory(ip, "ip-overdue", "早就該覆核了", pin="false",
                 review_by=(dt.date.today() - dt.timedelta(days=3)).isoformat())
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()

    text, _, _ = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark")
    assert "ip-overdue" in text, "逾期記憶掉出提醒窗口，等於永遠不會被覆核"
    assert "已逾期" in text
    assert "-3 天" not in text and "將於 -" not in text, "逾期項不可算成負數天數"


def test_non_project_warn_visible_in_project_session(conn, home: Path, monkeypatch):
    """machine/global/work 的 **WARN** 在專案 session 也要看得見。

    這三個 bank 的路徑不含專案 slug，舊的 `\\<pk>\\ in path` 比對等於永遠不匹配——
    症狀是使用者在任何專案裡都看不到本機層級的 unmanaged_file / index_drift 這類阻斷項。
    """
    _seed(conn, home)
    fake = AuditReport()
    fake.findings.append(
        Finding("WARN", str(home / "memory-machine"), "unmanaged_file", "手改的檔案.md"))
    monkeypatch.setattr(session_context.auditmod, "run", lambda conn, cfg: fake)

    text, pk, _ = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark")
    assert pk == "D--Projects-IntelliPark"
    assert "unmanaged_file" in text, "machine bank 的阻斷級 WARN 被專案 slug 過濾掉了"


def test_non_project_suggest_stays_filtered(conn, home: Path):
    """但非專案 scope 的 **SUGGEST** 維持過濾——放行的粒度按 level 分，兩者不對稱。

    實測：全庫放行後 47 筆 orphan 會把 12 條上限佔滿，連本專案自己的 SUGGEST
    都被擠掉，等於用一個問題換另一個。建議類的東西跨 scope 對當下工作沒幫助。
    """
    _seed(conn, home)
    seed_banks(home)
    write_memory(home / "memory-machine", "mach-orphan", "本機孤兒", pin="false")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()

    text, _, _ = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark")
    assert "mach-orphan" not in text


def test_other_project_findings_still_filtered(conn, home: Path):
    """放行非專案 scope 不等於放行別的專案——別的專案 bank 仍要濾掉。"""
    _seed(conn, home)
    other = home / "projects" / "D--Projects-Other" / "memory"
    write_memory(other, "other-orphan", "別的專案的孤兒", pin="false")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()

    text, _, _ = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark")
    assert "other-orphan" not in text


def test_warn_survives_suggest_flood(conn, home: Path, monkeypatch):
    """WARN 不可被大量 SUGGEST 擠出 12 條的顯示上限。

    findings 是 append 順序，而 audit 把 index_drift / unmanaged_file 這組 WARN 產生在
    orphan SUGGEST 之後。使用者實際有 47 筆 orphan，於是那組阻斷級 WARN 永遠排在 12 名之外。
    這裡直接注入假 findings，測的是 session_context 的截斷策略本身，不依賴 audit 怎麼產生它們。
    """
    _seed(conn, home)
    bank = str(home / "projects" / "D--Projects-IntelliPark" / "memory")

    fake = AuditReport()
    for i in range(20):
        fake.findings.append(Finding("SUGGEST", bank, "orphan", f"noise-{i:02d} no_inbound_link"))
    fake.findings.append(Finding("WARN", bank, "unmanaged_file", "手改的檔案.md"))
    monkeypatch.setattr(session_context.auditmod, "run", lambda conn, cfg: fake)

    text, _, _ = session_context.render(conn, _cfg(), r"D:\Projects\IntelliPark")
    assert "unmanaged_file" in text, "阻斷級 WARN 被 SUGGEST 洪水擠掉了"
