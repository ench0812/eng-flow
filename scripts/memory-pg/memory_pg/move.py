"""move-scope：把記憶搬到另一個 scope（等同搬到另一個 repo）。

為什麼不是 `edit --scope`：scope 變更會改 `file_path`，只更新 DB 再 export 會讓舊路徑的
檔案變成 `unmanaged_file`，讓 export 整批 abort。所以 DB 與兩側檔案要在同一個流程裡處理。

順序是**先產新、後刪舊**：先刪唯一的舊副本再嘗試產新檔，在磁碟滿或權限錯時會兩邊都沒有。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from . import projects as projmod
from .config import Config
from .errors import UsageError


class MoveError(UsageError):
    code = "move"


@dataclass
class MovePlan:
    name: str
    old_scope: str
    new_scope: str
    old_path: str
    new_path: str
    old_tags: list[str]
    new_tags: list[str]
    old_slug: str | None
    new_slug: str | None
    affected_banks: list[Path] = field(default_factory=list)
    blockers: list[str] = field(default_factory=list)
    is_noop: bool = False


def _bank_of(cfg: Config, conn, scope: str, project_slug: str | None) -> Path:
    if scope != "project":
        return cfg.bank_for_scope(scope)
    with conn.cursor() as cur:
        cur.execute("SELECT bank_path FROM projects WHERE slug=%s", (project_slug,))
        r = cur.fetchone()
    return Path(r[0]) if r and r[0] else projmod.bank_path_for_slug(cfg.home, project_slug or "")


def new_tags_for(old_scope: str, new_scope: str, old_tags: list[str],
                 old_slug: str | None, clear_tags: bool) -> list[str]:
    """目標 scope 決定 tags（不是原樣保留）：

      machine / project  → 清空（DB 不變量 1 不允許它們持有 tag）
      work / global      → 保留既有 tags
      project → work/global：預設把原 home project **加為 tag**，保留原本的常駐注入範圍
                             （否則搬完之後那則記憶就從該專案的 MEMORY.md 消失了）；
                             `--clear-tags` 可明確取消
    """
    if new_scope in ("machine", "project"):
        return []
    if clear_tags:
        return []
    tags = list(old_tags)
    if old_scope == "project" and old_slug and old_slug not in tags:
        tags.append(old_slug)
    return tags


def plan(conn, cfg: Config, name: str, *, to_scope: str, project: str | None,
         clear_tags: bool) -> MovePlan:
    """純規劃，零寫入。`blockers` 非空時呼叫端不得繼續。"""
    with conn.cursor() as cur:
        cur.execute(
            """SELECT m.scope::text, m.file_path, p.slug
                 FROM memories m LEFT JOIN projects p ON p.id = m.home_project_id
                WHERE m.name = %s AND m.status = 'active'""",
            (name,),
        )
        row = cur.fetchone()
        if not row:
            return MovePlan(name, "", to_scope, "", "", [], [], None, None,
                            blockers=[f"找不到 active 的記憶: {name}"])
        old_scope, old_path, old_slug = row
        cur.execute(
            """SELECT p.slug FROM memory_projects mp
                 JOIN projects p ON p.id = mp.project_id
                 JOIN memories m ON m.id = mp.memory_id
                WHERE m.name = %s ORDER BY p.slug""",
            (name,),
        )
        old_tags = [r[0] for r in cur.fetchall()]

    b: list[str] = []
    if to_scope not in ("global", "machine", "work", "project"):
        b.append(f"未知的目標 scope: {to_scope}")
    if to_scope == "project" and not project:
        b.append("--to project 時必須指定 --project <slug>")
    if to_scope != "project" and project:
        b.append(f"--to {to_scope} 時不得給 --project")
    if b:
        return MovePlan(name, old_scope, to_scope, old_path, "", old_tags, [],
                        old_slug, project, blockers=b)

    is_noop = to_scope == old_scope and (to_scope != "project" or project == old_slug)
    new_bank = _bank_of(cfg, conn, to_scope, project)
    new_path = str(new_bank / f"{name}.md")
    new_tags = new_tags_for(old_scope, to_scope, old_tags, old_slug, clear_tags)

    # bank presence：只有 installed 才能搬。project 的 bank 由 export 自行建立，不在此檢查。
    for sc in {old_scope, to_scope}:
        if sc == "project":
            continue
        st = cfg.bank_presence(sc)
        if st != "installed":
            b.append(f"{sc} 的 bank 狀態是 {st}（需要 installed）")

    if not is_noop:
        np, op = Path(new_path), Path(old_path)
        # 目標檔已存在時：內容與來源相同 → 是上次中斷留下的、可續跑；其餘一律擋。
        # 來源檔還沒匯出（op 不存在）時，任何既存的目標檔都來路不明，同樣要擋——
        # 不可因為「比不了」就當成沒問題。
        if np.exists() and (not op.exists() or np.read_bytes() != op.read_bytes()):
            b.append(f"目標路徑已存在且內容不同（或來源尚未匯出、無從比對）: {new_path}")

        # 移動後所有進出連結是否仍合法——**逐條列出**，不是只報第一條。
        # inbound 與 outbound 都要看：搬動同時改變了「它連出去」與「別人連進來」兩側的判定。
        new_home_sql = ("(SELECT id FROM projects WHERE slug = %s)" if to_scope == "project"
                        else "NULL::uuid")
        with conn.cursor() as cur:
            args: list = [name, name]
            cur.execute(
                """SELECT 'out' AS dir, l.kind::text, t.name, t.scope::text, t.home_project_id
                     FROM memory_links l JOIN memories s ON s.id = l.source_id
                     JOIN memories t ON t.id = l.target_id
                    WHERE s.name = %s
                   UNION ALL
                   SELECT 'in', l.kind::text, s.name, s.scope::text, s.home_project_id
                     FROM memory_links l JOIN memories s ON s.id = l.source_id
                     JOIN memories t ON t.id = l.target_id
                    WHERE t.name = %s""",
                args,
            )
            rows = cur.fetchall()
            for direction, kind, other, o_scope, o_home in rows:
                params: list = []
                if direction == "out":
                    expr = (f"SELECT link_allowed(%s::memory_scope, {new_home_sql}, "
                            f"%s::memory_scope, %s::uuid, %s::link_kind)")
                    params = [to_scope]
                    if to_scope == "project":
                        params.append(project)
                    params += [o_scope, o_home, kind]
                    label = f"{name}({to_scope}) -> {other}({o_scope})"
                else:
                    expr = (f"SELECT link_allowed(%s::memory_scope, %s::uuid, "
                            f"%s::memory_scope, {new_home_sql}, %s::link_kind)")
                    params = [o_scope, o_home, to_scope]
                    if to_scope == "project":
                        params.append(project)
                    params.append(kind)
                    label = f"{other}({o_scope}) -> {name}({to_scope})"
                cur.execute(expr, params)
                if not cur.fetchone()[0]:
                    b.append(f"移動後連結方向不允許（{direction}bound）: {label}"
                             f"——請先把該處的 wikilink 改成純文字")

    # 受影響的索引：來源 bank、目標 bank，以及 tag 有變動的各專案 bank。
    # 只搬檔案不重產索引，會讓 DB／檔案／常駐注入三者不一致。
    affected = {Path(old_path).parent, new_bank}
    for slug in set(old_tags) ^ set(new_tags):
        affected.add(projmod.bank_path_for_slug(cfg.home, slug))
    return MovePlan(name, old_scope, to_scope, old_path, new_path, old_tags, new_tags,
                    old_slug, project, affected_banks=sorted(affected),
                    blockers=b, is_noop=is_noop)
