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


def _finding_visible(path: str, pk: str | None, level: str) -> bool:
    """這則 audit finding 該不該在目前 session 顯示。

    專案 bank 的 finding 只在該專案顯示——別的專案的問題不是現在該處理的事。

    非專案 bank（`memory` / `memory-machine` / `memory-work`）的路徑**不含任何專案 slug**，
    舊版一律拿 `\\<pk>\\` 去比對，等於這三個 scope 在任何專案 session 下都必被濾掉，
    連 unmanaged_file / index_drift 這種阻斷項也看不見（2026-08-27 實測：裸跑 pk=None
    看得到 47 筆，指定 slug 後只剩該專案的）。

    但**放行的粒度按 level 分**，兩者不對稱：
      WARN    —— 不論哪個 bank 都放行。它是阻斷項（CLAUDE.md：「有 WARN 先處理」），
                 在哪個 scope 壞掉都得先修。
      SUGGEST —— 只放行本專案的。跨 scope 的建議對當下的工作沒有幫助，而顯示有 12 條
                 上限：實測全庫放行後，47 筆 orphan 會把名額佔滿，連本專案自己的
                 SUGGEST 都被擠掉——噪音比修之前更大，等於用一個問題換另一個。
    """
    if pk is None or path == "-":
        return True
    norm = path.replace("/", "\\")
    if "\\projects\\" not in norm:
        return level == "WARN"
    return ("\\" + pk + "\\") in (norm + "\\")


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
        # 到期提醒：review_by <= today+14（**含已逾期**），範圍＝本專案 + 所有非專案特定的 scope。
        # machine/work 也要收——這台機器的位址、案場的資產同樣會腐爛，漏掉它們等於那類
        # 記憶永遠不會被提醒覆核。
        #
        # 刻意不設下界（舊版是 BETWEEN current_date AND ...）：逾期項掉出下界後，唯一的
        # 兜底是 audit 的 overdue WARN，而那條路有兩個獨立的失效途徑——非專案 scope 會被
        # _finding_visible 濾掉（舊版），且 audit.run() 外面包著 `except: pass`，一失敗就
        # 靜默吞掉全部 finding。錯過提醒窗口的記憶因此可能永遠不再被提醒，而那正是最該
        # 覆核的一批。既然 soon 直接涵蓋，下面組裝 warns 時要把 overdue 濾掉避免重複顯示。
        cur.execute(
            """SELECT m.name, m.review_by FROM memories m LEFT JOIN projects p ON p.id=m.home_project_id
               WHERE m.status='active' AND m.review_by IS NOT NULL
                 AND m.review_by <= current_date + 14
                 AND (m.scope IN ('global','machine','work') OR p.slug=%(pk)s)
               ORDER BY m.review_by""",
            {"pk": pk},
        )
        soon = cur.fetchall()

    # 本 bank 的 audit（WARN + SUGGEST；修掉舊 hook 只印 SUGGEST 的 bug）
    warns = []
    try:
        arep = auditmod.run(conn, cfg)
        # overdue 已由上面的 soon 涵蓋（含逾期），這裡濾掉避免同一則記憶顯示兩次。
        visible = [f for f in arep.findings
                   if f.level in ("WARN", "SUGGEST")
                   and f.code != "overdue"
                   and _finding_visible(f.path, pk, f.level)]
        # WARN 排在 SUGGEST 前面，因為下面要截斷。audit 的 findings 是 append 順序，
        # 而 index_drift / unmanaged_file 這組**阻斷級** WARN 產生在 orphan SUGGEST
        # 之後；使用者實際有 47 筆 orphan，那組 WARN 於是永遠排在上限之外看不到。
        # sort 是穩定的，同 level 內維持 audit 原本的順序。
        visible.sort(key=lambda f: 0 if f.level == "WARN" else 1)
        warns = [f"{f.level}: {f.code} {f.detail}".rstrip() for f in visible]
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
        if days < 0:
            lines.append(f"到期提醒: {name} 已逾期 {-days} 天(review_by={rb})")
        else:
            lines.append(f"到期提醒: {name} 將於 {days} 天內到期(review_by={rb})")
    for w in warns[:12]:
        lines.append("稽核: " + w)
    lines.append('搜尋: `~/.claude/scripts/memory search "<關鍵字>"`；寫入用 `memory write/learn`')
    lines.append("</project-memory>")
    return "\n".join(lines) + "\n", pk, pinned
