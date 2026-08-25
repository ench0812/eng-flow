"""寫入面：write / edit / learn / forget / verify。

原則：PG 為本體，這些操作直接改 DB（單一交易），改完由呼叫端 export 產生 md。
治理不變量（取代關係、scope、環）全由 schema 觸發器保證，這裡只負責把意圖翻成正確的
INSERT/UPDATE 與關係列，並在破壞性/易錯處 fail-closed（dup 拒寫、缺 scope 拒寫）。
"""

from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass

import psycopg

from . import frontmatter as fm
from . import projects as projmod
from .config import Config
from .errors import UsageError

DUP_JACCARD = 0.35
DUP_DESC_CAP = 300


class MutateError(UsageError):
    code = "mutate"


def _bigrams(s: str) -> set[str]:
    s = s[:DUP_DESC_CAP]
    return {s[i:i + 2] for i in range(len(s) - 1)} if len(s) >= 2 else ({s} if s else set())


def _bank_and_path(cfg: Config, conn, scope: str, name: str, project_slug: str | None):
    if scope == "global":
        return None, str((cfg.bank_global / f"{name}.md"))
    if not project_slug:
        raise MutateError("project scope 需要 --project <slug>")
    with conn.cursor() as cur:
        cur.execute("SELECT id, bank_path FROM projects WHERE slug=%s", (project_slug,))
        row = cur.fetchone()
    if not row:
        # 專案未登錄 → 自動建（root_path 反推）
        root = projmod.path_from_slug(project_slug)
        bank = str(projmod.bank_path_for_slug(cfg.home, project_slug))
        with conn.cursor() as cur:
            cur.execute("INSERT INTO projects(slug, root_path, bank_path) VALUES (%s,%s,%s) RETURNING id",
                        (project_slug, str(root) if root else project_slug, bank))
            pid = cur.fetchone()[0]
        return pid, str(projmod.bank_path_for_slug(cfg.home, project_slug) / f"{name}.md")
    pid, bank = row
    return pid, str(bank + "\\" + f"{name}.md")


def _parse_input(name: str | None, text: str) -> tuple[str, str, str]:
    """回傳 (name, description, body)。text 可為完整 md（含 frontmatter）或純 body。"""
    if text.lstrip().startswith("---"):
        p = fm.parse(name or "_tmp", text.encode("utf-8"))
        if p.errs and p.errs != ["name_stem_mismatch"]:
            raise MutateError(f"輸入 md 解析失敗: {','.join(p.errs)}")
        return (p.name or name or ""), p.description, p.body_raw
    return (name or ""), "", ("\n" + text.strip() + "\n" if text.strip() else "\n")


def write(conn, cfg: Config, *, name: str, scope: str, description: str, body: str,
          kind: str | None = None, pin: bool = False, review_by: str | None = None,
          project_slug: str | None = None, tags: list[str] | None = None,
          importance: int | None = None, confidence: str = "high",
          source_type: str = "manual", source_id: str | None = None) -> str:
    if not name:
        raise MutateError("缺 --name")
    if not description:
        raise MutateError("缺 description（--description 或 md frontmatter）")
    if not fm.ID_RE.match(name):
        raise MutateError(f"name 不合法（{name}）")
    pid, path = _bank_and_path(cfg, conn, scope, name, project_slug)
    imp = importance if importance is not None else (4 if pin else 3)
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO memories(name, description, body, file_path, scope, home_project_id,
                 kind, pinned, review_by, importance, confidence, source_type, source_id)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
            (name, description, body, path, scope, pid, kind, pin, review_by or None,
             imp, confidence, source_type, source_id),
        )
        mid = cur.fetchone()[0]
        for slug in (tags or []):
            cur.execute("SELECT id FROM projects WHERE slug=%s", (slug,))
            r = cur.fetchone()
            if not r:
                raise MutateError(f"--tag 指向未登錄的 project: {slug}")
            cur.execute("INSERT INTO memory_projects(memory_id, project_id) VALUES (%s,%s)", (mid, r[0]))
    return name


def _snapshot(cur, mid, reason):
    cur.execute("SELECT description, body, frontmatter_raw FROM memories WHERE id=%s", (mid,))
    d, b, fr = cur.fetchone()
    cur.execute("INSERT INTO memory_revisions(memory_id, description, body, frontmatter_raw, reason) "
                "VALUES (%s,%s,%s,%s,%s)", (mid, d, b, fr, reason))


def _get_mid(cur, name: str) -> str:
    cur.execute("SELECT id FROM memories WHERE name=%s", (name,))
    r = cur.fetchone()
    if not r:
        raise MutateError(f"找不到記憶: {name}")
    return r[0]


def edit(conn, cfg: Config, name: str, *, description: str | None, body: str | None, reason: str) -> str:
    with conn.cursor() as cur:
        mid = _get_mid(cur, name)
        _snapshot(cur, mid, reason)
        sets, vals = ["frontmatter_raw = NULL", "updated_at = now()"], []
        if description is not None:
            sets.append("description = %s"); vals.append(description)
        if body is not None:
            sets.append("body = %s"); vals.append(body)
        vals.append(mid)
        cur.execute(f"UPDATE memories SET {', '.join(sets)} WHERE id=%s", vals)
    return name


def dup_candidates(conn, scope: str, project_slug: str | None, description: str) -> list[tuple[str, float]]:
    with conn.cursor() as cur:
        if scope == "global":
            cur.execute("SELECT name, description FROM memories WHERE scope='global' AND status='active'")
        else:
            cur.execute("SELECT m.name, m.description FROM memories m JOIN projects p ON p.id=m.home_project_id "
                        "WHERE m.status='active' AND p.slug=%s", (project_slug,))
        rows = cur.fetchall()
    a = _bigrams(description)
    out = []
    for nm, d in rows:
        b = _bigrams(d)
        if a and b:
            j = len(a & b) / len(a | b)
            if j >= DUP_JACCARD:
                out.append((nm, round(j, 2)))
    return sorted(out, key=lambda x: -x[1])


def learn(conn, cfg: Config, *, supersedes: list[str], confirms: list[str], force: bool, **wkw) -> str:
    # dup 偵測（同 scope）：≥門檻且非 --force → 拒寫
    if not force:
        dups = dup_candidates(conn, wkw["scope"], wkw.get("project_slug"), wkw["description"])
        if dups:
            raise MutateError("疑似重複（同 scope，description 2-gram Jaccard≥0.35）: "
                              + ", ".join(f"{n}({j})" for n, j in dups) + "。確認要新增用 --force")
    name = write(conn, cfg, **wkw)
    with conn.cursor() as cur:
        mid = _get_mid(cur, name)
        for old in supersedes:
            oid = _get_mid(cur, old)
            # 觸發器負責環偵測/同 bank/只能取代 active/舊者轉 superseded
            cur.execute("INSERT INTO memory_links(source_id, target_name, target_id, kind) "
                        "VALUES (%s,%s,%s,'supersedes')", (mid, old, oid))
        for cid in confirms:
            cur.execute("UPDATE memories SET evidence_count = evidence_count + 1, last_verified = current_date "
                        "WHERE name = %s", (cid,))
    return name


def forget(conn, cfg: Config, name: str, *, reason: str, status: str = "deprecated") -> str:
    if status not in ("deprecated", "invalid"):
        raise MutateError("forget 的 --status 只接受 deprecated|invalid")
    with conn.cursor() as cur:
        mid = _get_mid(cur, name)
        _snapshot(cur, mid, reason)
        cur.execute("UPDATE memories SET status=%s, valid_until=now() WHERE id=%s AND status='active'",
                    (status, mid))
        if cur.rowcount == 0:
            raise MutateError(f"{name} 非 active，無法 forget")
    return name


def verify(conn, cfg: Config, name: str, *, method: str | None, extend_days: int = 90) -> str:
    with conn.cursor() as cur:
        mid = _get_mid(cur, name)
        new_rb = _dt.date.today() + _dt.timedelta(days=extend_days)
        cur.execute("UPDATE memories SET last_verified=current_date, verification_method=%s, "
                    "review_by = CASE WHEN review_by IS NOT NULL THEN %s ELSE review_by END WHERE id=%s",
                    (method, new_rb, mid))
    return name
