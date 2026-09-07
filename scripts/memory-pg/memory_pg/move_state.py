"""move-scope 的狀態機與 journal。

順序（先產新、後刪舊；舊檔在重產索引前先改成非 `.md` 的恢復檔）：

    stage new (<new>.md.new，記 hash)   → phase=staged
    commit DB（scope/home/file_path/tags/連結，單一交易，deferred trigger 驗最終狀態）
                                        → phase=db_committed
    install new (rename .new → .md)     → phase=installed
    old.md → old.md.move-old            → phase=old_parked
    重產所有受影響的 MEMORY.md           → phase=indexes_written
    刪 .move-old、刪 journal             → done

**舊檔為什麼先改名成 `.move-old` 而不是直接刪**：exporter 對 bank 內「PG 沒有的 `.md`」會報
`unmanaged_file` 並中止，所以在刪舊檔前重產索引會固定失敗。改成非 `.md` 副檔名，exporter
看不見它，又保留一份可恢復的副本——不會出現「新舊都沒有」的瞬間。

**續跑的權威是檔案與 DB 的現況，不是 journal 的 phase**：副作用完成、checkpoint 之前被殺時
phase 會落後一格，照 phase 盲目重做會出事（例如再 rename 一次已經不存在的舊檔）。
journal 存在的意義是 DB commit 之後光靠當前 DB 列**無法**重建 before-state（舊路徑、
舊 tags、staging hash）。
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

from .config import Config
from .move import MoveError, MovePlan, plan

PHASE_ORDER = ["staged", "db_committed", "installed", "old_parked", "indexes_written", "done"]
PARKED_SUFFIX = ".move-old"


def journal_path(cfg: Config, name: str) -> Path:
    return cfg.home / "cache" / "move-scope" / f"{name}.json"


def _checkpoint(jp: Path, state: dict) -> None:
    """原子寫入 journal：同目錄暫存檔 → flush + fsync → os.replace。

    非原子寫入會在中斷時留下半截 JSON，續跑讀不出來就等於沒有 journal。
    """
    jp.parent.mkdir(parents=True, exist_ok=True)
    tmp = jp.with_name(jp.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, jp)


def _read_journal(jp: Path) -> dict | None:
    if not jp.is_file():
        return None
    try:
        return json.loads(jp.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return None          # 半截 JSON 當成沒有 journal，由現況重新推導


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _park_old(old: Path) -> None:
    """舊檔改名成非 `.md` 的恢復檔。依**檔案現況**冪等：

      old 在、parked 不在 → rename
      old 不在、parked 在 → 已完成，什麼都不做
      兩者都不存在        → 目標狀態已達成（舊檔本來就沒匯出，或已被清掉），no-op
      **兩者都在**        → inconsistent_state，明確報錯不猜測

    只有「兩者都在」是真的危險：有兩份候選的舊檔，分不出哪份權威，猜錯就是刪掉唯一的副本。
    「都不存在」是良性的——這一步要達成的就是「舊路徑上沒有 .md」，它已經成立了。
    """
    parked = old.with_name(old.name + PARKED_SUFFIX)
    if old.exists() and parked.exists():
        raise MoveError(f"inconsistent_state: {old} 與 {parked} 同時存在，需人工確認後再續跑")
    if old.exists():
        os.replace(old, parked)


def _render_one(conn, name: str) -> bytes:
    from . import exporter

    rows, _ = exporter._load(conn)
    row = next((r for r in rows if r["name"] == name), None)
    if row is None:
        raise MoveError(f"找不到記憶: {name}")
    return exporter.render_memory(row).encode("utf-8", errors="surrogateescape")


def _commit_db(conn, j: dict, name: str, reason: str) -> None:
    from . import db as dbmod
    from . import mutate

    with dbmod.top_level_transaction(conn):
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM memories WHERE name=%s", (name,))
            mid = cur.fetchone()[0]
            # 舊 scope / file_path / tags 寫進 revision 的 reason 文字。memory_revisions
            # 不存治理欄位（已知未決項），這裡用文字補記——搬錯了才追得回。
            mutate._snapshot(
                cur, mid,
                f"{reason}｜move-scope: {j['old_scope']}→{j['new_scope']}，"
                f"舊路徑 {j['old_path']}，舊 tags {j['old_tags']}")
            cur.execute("DELETE FROM memory_projects WHERE memory_id=%s", (mid,))
            if j["new_scope"] == "project":
                cur.execute(
                    "UPDATE memories SET scope=%s, "
                    "home_project_id=(SELECT id FROM projects WHERE slug=%s), "
                    "file_path=%s, frontmatter_raw=NULL, updated_at=now() WHERE id=%s",
                    (j["new_scope"], j["new_slug"], j["new_path"], mid))
            else:
                cur.execute(
                    "UPDATE memories SET scope=%s, home_project_id=NULL, "
                    "file_path=%s, frontmatter_raw=NULL, updated_at=now() WHERE id=%s",
                    (j["new_scope"], j["new_path"], mid))
            for slug in j["new_tags"]:
                cur.execute("INSERT INTO memory_projects(memory_id, project_id) "
                            "SELECT %s, id FROM projects WHERE slug=%s", (mid, slug))
            # 進出連結重驗：scope 換了，原本合法的方向可能不再合法。
            # deferred constraint trigger 會在 commit 時驗最終狀態。
            cur.execute("SELECT body FROM memories WHERE id=%s", (mid,))
            mutate._sync_wikilinks(cur, mid, cur.fetchone()[0])


def run(conn, cfg: Config, name: str, *, to_scope: str, project: str | None,
        clear_tags: bool, reason: str) -> MovePlan:
    """執行搬移。每個中斷點都可冪等重跑。"""
    from . import exporter

    jp = journal_path(cfg, name)
    j = _read_journal(jp)

    if j is None:
        p = plan(conn, cfg, name, to_scope=to_scope, project=project, clear_tags=clear_tags)
        if p.blockers:
            raise MoveError("；".join(p.blockers))
        if p.is_noop:
            return p
        j = {
            "name": name, "old_scope": p.old_scope, "new_scope": p.new_scope,
            "old_path": p.old_path, "new_path": p.new_path,
            "old_tags": p.old_tags, "new_tags": p.new_tags,
            "old_slug": p.old_slug, "new_slug": p.new_slug,
            "affected_banks": [str(x) for x in p.affected_banks],
            "content_sha256": "", "phase": "",
        }
    else:
        p = MovePlan(j["name"], j["old_scope"], j["new_scope"], j["old_path"], j["new_path"],
                     j["old_tags"], j["new_tags"], j["old_slug"], j["new_slug"],
                     affected_banks=[Path(x) for x in j["affected_banks"]])

    new_p, old_p = Path(j["new_path"]), Path(j["old_path"])
    staging = new_p.with_name(new_p.name + ".new")

    # ---- staged ----
    if not new_p.exists():
        data = _render_one(conn, name)
        h = _sha(data)
        if not (staging.exists() and _sha(staging.read_bytes()) == h):
            staging.parent.mkdir(parents=True, exist_ok=True)
            staging.write_bytes(data)      # hash 不符 → 重產，不沿用過期的 staging
        j["content_sha256"] = h
        j["phase"] = "staged"
        _checkpoint(jp, j)

    # ---- db_committed ----（權威是 DB 現況，不是 phase）
    with conn.cursor() as cur:
        cur.execute("SELECT scope::text FROM memories WHERE name=%s", (name,))
        r = cur.fetchone()
    if (r[0] if r else None) != j["new_scope"]:
        _commit_db(conn, j, name, reason)
    j["phase"] = "db_committed"
    _checkpoint(jp, j)

    # ---- installed ----（權威是檔案現況）
    if staging.exists() and not new_p.exists():
        os.replace(staging, new_p)
    elif staging.exists():
        staging.unlink()                   # 已裝好，清掉殘留的 staging
    j["phase"] = "installed"
    _checkpoint(jp, j)

    # ---- old_parked ----
    if old_p != new_p:
        _park_old(old_p)
    j["phase"] = "old_parked"
    _checkpoint(jp, j)

    # ---- indexes_written ----
    # 只搬檔案不重產索引，會讓 DB／檔案／常駐注入三者不一致。
    exporter.run(conn, cfg, verify_dir=None)
    j["phase"] = "indexes_written"
    _checkpoint(jp, j)

    # ---- done ----
    parked = old_p.with_name(old_p.name + PARKED_SUFFIX)
    if parked.exists():
        parked.unlink()
    jp.unlink(missing_ok=True)
    return p
