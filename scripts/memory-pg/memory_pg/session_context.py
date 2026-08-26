"""session-context — SessionStart hook 的內容產生（Task 4）。

決定：pinned 全文由原生 autoMemory 從 MEMORY.md 載入，hook 不重印全文（避免雙重注入）。
hook 只做原生做不到的：pinned 清單一行、稽核 WARN/SUGGEST（修掉舊 hook 把 WARN 丟到
/dev/null 的 bug）、到期提醒、（未來）相關摘要。PG 連不上時印一行提示、exit 0——session
不可被擋，且 pinned 已由 MEMORY.md 另一路徑載入，hook 沒有「回空被誤讀」的問題。
"""

from __future__ import annotations

import datetime as _dt

import psycopg

from . import audit as auditmod
from . import search as searchmod
from .config import Config


def render(conn: psycopg.Connection, cfg: Config, cwd: str | None,
           slug: str | None = None) -> tuple[str, str | None, list[str]]:
    """回傳 (輸出文字, project_slug, 本 session 實際注入的 pinned 名單)。空庫回 ('', slug, [])。
    slug 優先於 cwd（hook 從 transcript_path 取到的 slug 比路徑比對可靠）。"""
    pk = slug or searchmod.resolve_project_key(conn, cwd)
    with conn.cursor() as cur:
        # 該注入這個 session 的 pinned，與 exporter 的 MEMORY.md PINNED 規則一致：
        #   machine       ——全收。本機事實在這台機器上永遠相關，那就是它存在的理由。
        #   global / work ——無標籤者全域可見；有標籤者只在被標的專案。
        #   project       ——本專案的。
        # untagged work **不會**出現在這裡：memory-work/MEMORY.md 刻意不產 PINNED 區，
        # 沒有常駐載入路徑，列在這裡會讓人以為已常駐（audit 的 pinned_work_without_tag 會報）。
        cur.execute(
            """SELECT m.name FROM memories m
               LEFT JOIN projects p ON p.id = m.home_project_id
               WHERE m.pinned AND m.status='active' AND (
                     m.scope='machine'
                  OR (m.scope='global' AND NOT EXISTS (SELECT 1 FROM memory_projects mp WHERE mp.memory_id=m.id))
                  OR (m.scope IN ('global','work') AND EXISTS (
                        SELECT 1 FROM memory_projects mp JOIN projects pp ON pp.id=mp.project_id
                         WHERE mp.memory_id=m.id AND pp.slug=%(pk)s))
                  OR (m.scope='project' AND p.slug=%(pk)s))
               ORDER BY m.name""",
            {"pk": pk},
        )
        pinned = [r[0] for r in cur.fetchall()]
        # 到期提醒：review_by 在 [today, today+14]，範圍＝本專案 + 所有非專案特定的 scope。
        # machine/work 也要收——這台機器的位址、案場的資產同樣會腐爛，漏掉它們等於那類
        # 記憶永遠不會被提醒覆核。
        cur.execute(
            """SELECT m.name, m.review_by FROM memories m LEFT JOIN projects p ON p.id=m.home_project_id
               WHERE m.status='active' AND m.review_by IS NOT NULL
                 AND m.review_by BETWEEN current_date AND current_date + 14
                 AND (m.scope IN ('global','machine','work') OR p.slug=%(pk)s)
               ORDER BY m.review_by""",
            {"pk": pk},
        )
        soon = cur.fetchall()

    # 本 bank 的 audit（WARN + SUGGEST；修掉舊 hook 只印 SUGGEST 的 bug）
    warns = []
    try:
        arep = auditmod.run(conn, cfg)
        for f in arep.findings:
            if f.level in ("WARN", "SUGGEST") and (pk is None or ("\\" + pk + "\\") in (f.path + "\\") or f.path == "-"):
                warns.append(f"{f.level}: {f.code} {f.detail}".rstrip())
    except Exception:  # noqa: BLE001
        pass  # 稽核失敗不擋 session

    n = len(pinned)
    if n == 0 and not soon and not warns:
        return "", pk, []

    lines = [f'<project-memory bank="{pk or "global"}" pinned="{n}" via="MEMORY.md">']
    if pinned:
        lines.append("常駐(全文已由 MEMORY.md 載入): " + ", ".join(pinned))
    for name, rb in soon:
        days = (rb - _dt.date.today()).days
        lines.append(f"到期提醒: {name} 將於 {days} 天內到期(review_by={rb})")
    for w in warns[:12]:
        lines.append("稽核: " + w)
    lines.append('搜尋: `~/.claude/scripts/memory search "<關鍵字>"`；寫入用 `memory write/learn`')
    lines.append("</project-memory>")
    return "\n".join(lines) + "\n", pk, pinned
