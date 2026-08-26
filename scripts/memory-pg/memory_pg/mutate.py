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
from .errors import MemoryError_, UsageError

DUP_JACCARD = 0.35
DUP_DESC_CAP = 300


class MutateError(UsageError):
    code = "mutate"


class BankStateError(MemoryError_):
    """bank 狀態不明（unavailable / damaged_install）→ exit 1。

    與 not_installed 的 UsageError（exit 2）刻意分開：
      not_installed = 設定沒做完，使用者知道怎麼修 → 用法錯
      unavailable   = bank 可能有內容但讀不到，**無法判定正確性** → 契約規定 exit 1
    """
    code = "bank_state"


def _bigrams(s: str) -> set[str]:
    s = s[:DUP_DESC_CAP]
    return {s[i:i + 2] for i in range(len(s) - 1)} if len(s) >= 2 else ({s} if s else set())


def _bank_and_path(cfg: Config, conn, scope: str, name: str, project_slug: str | None):
    # global / machine / work 各自單一 bank、home_project_id 為 NULL；只有 project 要 slug。
    if scope in ("global", "machine", "work"):
        st = cfg.bank_presence(scope)
        if st == "not_installed":
            # 拒寫而不是照寫：export 對 not_installed 是「跳過且 exit 0」，照寫的話會變成
            # 「DB 有記憶、repo 沒檔案、命令回成功」——沒有任何訊號的不一致。
            raise UsageError(
                f"{scope} 的 bank（{cfg.bank_for_scope(scope)}）尚未安裝，拒絕寫入。"
                f"先跑 `claude-repos.sh install --repo {scope}`", code="bank_not_installed")
        if st != "installed":
            raise BankStateError(f"{scope} 的 bank 狀態是 {st}，拒絕寫入（先排除安裝問題）")
        return None, str(cfg.bank_for_scope(scope) / f"{name}.md")
    if scope != "project":
        raise MutateError(f"未知的 scope: {scope}")
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
        _sync_wikilinks(cur, mid, body)
        _backfill_inbound(cur, mid, name)
    return name


def _backfill_inbound(cur, mid: str, name: str) -> None:
    """把既有記憶指向這個名字的 dangling wikilink 接回來。

    _sync_wikilinks 只處理「來源這一則」的出向連結，所以先寫 A（正文含 [[B]]）、後寫 B 時，
    A 那一列永遠停在 target_id=NULL：audit 會永久報 `dangling_ref [[B]] in A`，同時把 B 報成
    `orphan`（查不到 inbound）。兩個都是假警報而且清不掉——只能跑一次 full import 才會消。

    **不可用 UPDATE**：trg_links_immutable 只放行 target_id 由 NOT NULL 轉 NULL，反向會
    RAISE EXCEPTION 'links_immutable'。所以是 DELETE 掉舊的 dangling 列再重新 INSERT。

    **方向不允許的列刻意留在 dangling，不拋錯**——這裡與來源側（_resolve_link_target）刻意
    不同，理由是誤傷範圍：
      來源側是使用者「正在寫 [[x]]」，拋錯即時、可行動、就在他手上那則。
      這裡是「別人的記憶引用了我正要建立的名字」。拋錯會讓 B 專案建不了 `foo`，只因為
      A 專案有一條過期的 [[foo]]——那是與本次寫入無關的附帶損害。
    資訊沒有流失：audit 會把「目標存在但方向不允許」報成 `forbidden_ref`（WARN），與
    「目標不存在」的 `dangling_ref` 分開，責任也歸在真正該改的那一則（來源）身上。
    """
    cur.execute("SELECT scope::text, home_project_id FROM memories WHERE id=%s", (mid,))
    t_scope, t_home = cur.fetchone()
    cur.execute(
        """DELETE FROM memory_links l USING memories s
            WHERE l.source_id = s.id AND l.kind='wikilink' AND l.target_name = %s
              AND l.target_id IS NULL AND l.source_id <> %s
              AND link_allowed(s.scope, s.home_project_id, %s::memory_scope, %s::uuid, 'wikilink')
            RETURNING l.source_id""",
        (name, mid, t_scope, t_home),
    )
    for (sid,) in cur.fetchall():
        cur.execute("INSERT INTO memory_links(source_id, target_name, target_id, kind) "
                    "VALUES (%s,%s,%s,'wikilink') ON CONFLICT DO NOTHING", (sid, name, mid))



def _resolve_link_target(cur, src_scope: str, src_home, lid: str):
    """三分支：不存在 → None（dangling）；存在但方向禁止 → 拋錯；允許 → id。

    **必須在全庫查**（name 全域唯一），不可只在允許的 scope 內搜尋——那會把「已知但禁止」
    降級成「未知」，寫成 target_id=NULL 之後 trigger 對 NULL 直接放行，命令會成功，
    最後只由 audit 報一個 dangling。那與「這個方向不允許」的語義完全不同。
    """
    cur.execute("SELECT id, scope::text, home_project_id FROM memories WHERE name=%s", (lid,))
    row = cur.fetchone()
    if not row:
        return None                                   # 真的不存在 → dangling
    tid, t_scope, t_home = row
    cur.execute("SELECT link_allowed(%s::memory_scope, %s::uuid, %s::memory_scope, "
                "%s::uuid, 'wikilink')", (src_scope, src_home, t_scope, t_home))
    if not cur.fetchone()[0]:
        raise MutateError(
            f"cross_repo_link: {lid} 的 scope 是 {t_scope}，不允許從 {src_scope} 連過去。"
            f"要提到它請用純文字（反引號），不要用 wikilink")
    return tid


def _sync_wikilinks(cur, mid: str, body: str) -> None:
    """把正文的 [[target]] 同步進 memory_links(kind='wikilink')。

    解析規則與 importer 相同：同 bank 優先，非 global 的來源可退回 global bank，跨專案不解析
    （留 target_id=NULL，由 audit 報 dangling）。write/edit 都要呼叫——不呼叫的話連結圖就只是
    import 當下的快照，orphan / dangling_ref 稽核會對著過期的圖做判斷（實測 2026-08-26：正文
    55 個 wikilink，links 表只有 38 列）。
    """
    seen, names = set(), []
    for m in fm.WIKILINK_RE.finditer(body or ""):
        lid = m.group(1)
        if fm.LINK_CONTROL_RE.search(lid) or lid in seen:
            continue
        seen.add(lid); names.append(lid)
    cur.execute("SELECT scope::text, home_project_id, name FROM memories WHERE id=%s", (mid,))
    scope, pid, self_name = cur.fetchone()
    cur.execute("DELETE FROM memory_links WHERE source_id=%s AND kind='wikilink'", (mid,))
    for lid in names:
        if lid == self_name:
            continue                      # 自我連結沒有語意，且 CHECK 會擋
        tid = _resolve_link_target(cur, scope, pid, lid)
        cur.execute("INSERT INTO memory_links(source_id, target_name, target_id, kind) "
                    "VALUES (%s,%s,%s,'wikilink') ON CONFLICT DO NOTHING", (mid, lid, tid))


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


KEEP = object()   # 「不動這個欄位」的哨兵，與「設成 NULL」區分開


def edit(conn, cfg: Config, name: str, *, description: str | None, body: str | None, reason: str,
         kind=KEEP, pin=KEEP, review_by=KEEP) -> str:
    """改記憶。description/body 傳 None = 不動；kind/pin/review_by 用 KEEP 哨兵表示不動。

    kind/pin/review_by 是**治理**欄位而非內容：kind 決定匯出索引的分組，pin 決定常駐成本，
    review_by 決定到期覆核。原本只有 write 時能設，改不了就只能重建記憶（會掉 revisions 與
    access 歷史），所以 edit 要能改。
    """
    with conn.cursor() as cur:
        mid = _get_mid(cur, name)
        _snapshot(cur, mid, reason)
        sets, vals = ["frontmatter_raw = NULL", "updated_at = now()"], []
        if description is not None:
            sets.append("description = %s"); vals.append(description)
        if body is not None:
            sets.append("body = %s"); vals.append(body)
        if kind is not KEEP:
            sets.append("kind = %s"); vals.append(kind)
        if review_by is not KEEP:
            sets.append("review_by = %s"); vals.append(review_by or None)
        if pin is not KEEP:
            sets.append("pinned = %s"); vals.append(bool(pin))
            # 沿用 write() 的慣例（pin 時 importance 4）。只在 importance 仍等於對向的預設值時動，
            # 所以人工設成 1/2/5 的不會被碰；但 importance=4 分不出是 pin 帶來的還是人工設的，
            # --unpin 會把那種也降回 3。importance 目前不參與排名，影響僅止於欄位語意。
            sets.append("importance = CASE WHEN importance = %s THEN %s ELSE importance END")
            vals.extend([3, 4] if pin else [4, 3])
        vals.append(mid)
        cur.execute(f"UPDATE memories SET {', '.join(sets)} WHERE id=%s", vals)
        if body is not None:
            _sync_wikilinks(cur, mid, body)
    return name


def dup_candidates(conn, scope: str, project_slug: str | None, description: str) -> list[tuple[str, float]]:
    with conn.cursor() as cur:
        # 精確比對 scope：machine 與 global 是不同的庫，描述相同不算重複。
        if scope == "project":
            cur.execute("SELECT m.name, m.description FROM memories m "
                        "JOIN projects p ON p.id=m.home_project_id "
                        "WHERE m.status='active' AND p.slug=%s", (project_slug,))
        else:
            cur.execute("SELECT name, description FROM memories "
                        "WHERE scope=%s AND status='active'", (scope,))
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
        for cid in dict.fromkeys(confirms):   # 去重：重複參數不重複加 evidence
            _get_mid(cur, cid)                 # 不存在 → 拋錯，不靜默遺失確認意圖
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
    if extend_days < 0:
        raise MutateError("--extend-days 不可為負（verify 是順延，不是往回推）")
    with conn.cursor() as cur:
        mid = _get_mid(cur, name)
        cur.execute("SELECT status::text FROM memories WHERE id=%s", (mid,))
        if cur.fetchone()[0] != "active":
            raise MutateError(f"{name} 非 active，無法 verify（已 deprecated/invalid 的不需覆核）")
        new_rb = _dt.date.today() + _dt.timedelta(days=extend_days)
        cur.execute("UPDATE memories SET last_verified=current_date, verification_method=%s, "
                    "review_by = CASE WHEN review_by IS NOT NULL THEN %s ELSE review_by END WHERE id=%s",
                    (method, new_rb, mid))
    return name
