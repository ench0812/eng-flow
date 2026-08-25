"""search — hybrid 檢索（全文 + 可選向量），CLI 與 MCP 共用的核心。

設計見 plan 的 A3/A4。三個貫穿判斷：
  * 幾百則規模，兩路都 exact scan、一句 SQL 融合。
  * 9 個實測失敗查詢靠「全文 + id 索引 + OR 語意」就能解；向量路是「用詞不同」的加成。
  * id 是第一等檢索欄位。
fail-closed（A4）：無法判定結果正確性時 raise，讓 CLI 回 exit 1 且 stdout 零輸出——
「失敗不可以長得像查無」。全文單路是被 golden set 驗證過的正當降級，不是失敗偽裝。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

import psycopg

from . import db, projects
from .config import Config
from .errors import RetrievalUnavailable, SearchAborted

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
RRF_K = 60
FTS_LIMIT = 40
VEC_LIMIT = 40


@dataclass
class Hit:
    name: str
    file_path: str
    description: str
    scope: str
    project_key: str | None
    kind: str | None
    status: str
    pinned: bool
    stale: bool
    id_hit: bool
    fts_rank: int | None
    vec_rank: int | None
    sim: float | None
    rrf: float


@dataclass
class SearchResult:
    hits: list[Hit]
    backend: str                 # pgroonga | ilike
    mode: str                    # hybrid | fts
    degraded: str | None = None  # 降級原因（None = 沒降級）
    model: str | None = None
    warnings: list[str] = field(default_factory=list)


_CJK = re.compile(r"[㐀-鿿豈-﫿]")


def _is_cjk_run(t: str) -> bool:
    return len(t) >= 2 and all(_CJK.match(c) for c in t)


def tokenize(query: str) -> list[str]:
    """空白切詞；純 CJK 長詞（≥4 字，多半是沒斷詞的自然語言）額外展開成 2-gram，
    讓「哪台是正式機」也能靠「正式」「式機」子串命中——PGroonga &@ 對整串是 phrase 比對，
    要求每個 bigram 都在，對自然語言問句太嚴。展開後靠 OR + coverage 排名，雜訊 bigram 不傷。
    保留原詞：len==4 時原詞的 &@ 等於「完整片語」，命中就是精準加分。"""
    q = query.replace("[[", " ").replace("]]", " ").replace('"', " ").replace("'", " ")
    raw = [t for t in q.split() if t]
    out: list[str] = []
    seen: set[str] = set()

    def add(t: str):
        if t and t not in seen:
            seen.add(t); out.append(t)

    for t in raw:
        add(t)
        if _is_cjk_run(t) and len(t) >= 4:
            for i in range(len(t) - 1):
                add(t[i:i + 2])
    return out


def resolve_project_key(conn: psycopg.Connection, cwd: str | None) -> str | None:
    """cwd → project slug。優先: workspace root 前綴比對；否則 slug 直算後查表。"""
    if not cwd:
        return None
    cwd_n = cwd.replace("/", "\\").rstrip("\\").lower()
    with conn.cursor() as cur:
        cur.execute("SELECT slug, root_path, is_workspace_root FROM projects")
        rows = cur.fetchall()
    # 先比 workspace root（IntelliPark 6 repo 在 root 之下）——取最長前綴
    best = None
    for slug, root, ws in rows:
        r = (root or "").replace("/", "\\").rstrip("\\").lower()
        if not r:
            continue
        if cwd_n == r or cwd_n.startswith(r + "\\"):
            if ws or cwd_n == r:
                if best is None or len(r) > best[1]:
                    best = (slug, len(r))
    if best:
        return best[0]
    slug = projects.slug_from_path(cwd)
    known = {r[0] for r in rows}
    return slug if slug in known else None


def _to_gitbash(path: str) -> str:
    s = path.replace("\\", "/")
    if len(s) > 1 and s[1] == ":":
        s = "/" + s[0].lower() + s[2:]
    return s


def _embedding_config(conn: psycopg.Connection):
    with conn.cursor() as cur:
        cur.execute("SELECT model, dim, query_prefix, tau FROM embedding_config LIMIT 1")
        return cur.fetchone()


def _rows_have_embeddings(conn: psycopg.Connection, model: str) -> tuple[int, int, int]:
    """回傳 (本模型已嵌入數, 他模型數, 本模型缺嵌入數)。"""
    with conn.cursor() as cur:
        cur.execute("SELECT "
                    "count(*) FILTER (WHERE embedding IS NOT NULL AND embedding_model=%s), "
                    "count(*) FILTER (WHERE embedding_model IS NOT NULL AND embedding_model<>%s), "
                    "count(*) FILTER (WHERE embedding IS NULL OR embedding_model IS DISTINCT FROM %s) "
                    "FROM memories WHERE status='active'", (model, model, model))
        return cur.fetchone()


def _assert_no_supersede_ambiguity(conn: psycopg.Connection) -> None:
    """dangling supersedes 或雙邊不一致 → 無法判定誰已被取代（A4）。觸發器平時擋住寫入，
    但直接改 DB 或匯入中斷仍可能留下，所以查詢前再驗一次。"""
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memory_links WHERE kind='supersedes' AND target_id IS NULL")
        if cur.fetchone()[0]:
            raise SearchAborted("取代關係無法判定（dangling supersedes）")


def _fts_predicate(backend: str, col: str, param: str) -> str:
    return f"{col} &@ {param}" if backend == "pgroonga" else f"{col} ILIKE '%'||{param}||'%'"


def search(
    conn: psycopg.Connection,
    cfg: Config,
    query: str,
    *,
    cwd: str | None = None,
    scope: str | None = None,          # None=current+global；'all'；'global'；或某 project_key
    k: int = 10,
    include_superseded: bool = False,
    mode: str = "hybrid",              # hybrid | fts
    degrade_ok: bool = False,
    embed_fn=None,                     # (cfg, text)->list[float]；None 時 hybrid 自動降 fts
) -> SearchResult:
    _assert_no_supersede_ambiguity(conn)
    backend = db.fts_backend(conn)
    pk = resolve_project_key(conn, cwd)
    terms = tokenize(query)
    warnings: list[str] = []

    # 向量路可用性
    qv = None
    model = None
    degraded = None
    if mode == "hybrid":
        cfgrow = _embedding_config(conn)
        if not cfgrow or embed_fn is None:
            degraded = "no_embedding_config" if not cfgrow else "no_embedder"
        else:
            model, dim, qprefix, tau = cfgrow
            n_ok, n_mismatch, n_missing = _rows_have_embeddings(conn, model)
            if n_mismatch:
                # 混模型的向量距離是垃圾，比查無更糟 → fail-closed（除非明示降級）
                if not degrade_ok:
                    raise RetrievalUnavailable(f"embedding 模型不一致（{n_mismatch} 列非 {model}），執行 memory embed --all")
                degraded = "embed_model_mismatch"
            else:
                try:
                    # prefix 由 embed_fn 內部負責，這裡只傳原始 query（避免重複加 prefix）
                    qv = embed_fn(cfg, query)
                except Exception as e:  # noqa: BLE001
                    if not degrade_ok:
                        raise RetrievalUnavailable(f"embedding 查詢失敗: {e}") from e
                    degraded = f"embed_failed:{type(e).__name__}"
                if n_ok == 0 and qv is not None:
                    warnings.append("沒有任何列有此模型的 embedding，向量路無效果")
                elif n_missing and qv is not None:
                    # 有列缺 embedding（embed 失敗留 NULL）：向量路會略過它們，可能對只能靠語意
                    # 命中的查詢造成假陰性。明確警示（plan A5：只警示不 fail），提示補算。
                    warnings.append(f"{n_missing} 列缺 embedding，向量路略過（memory embed --pending 補算）")

    use_vec = qv is not None
    eff_mode = "hybrid" if use_vec else "fts"

    # scope 過濾（在排名之前）
    scope_sql, scope_params = _scope_filter(scope, pk)

    id_hit_expr = "(m.name = %(q)s OR m.name ILIKE '%%'||%(q)s||'%%')" if ID_RE.match(query.strip()) else "false"

    params: dict = {"q": query.strip(), "terms": terms, "tau": (tau if use_vec else 0.0)}
    params.update(scope_params)

    fts_where = " OR ".join(
        f"{_fts_predicate(backend, c, 't.t')}" for c in ("m.search_name", "m.description", "m.body")
    )
    name_c = _fts_predicate(backend, "m.search_name", "t.t")
    desc_c = _fts_predicate(backend, "m.description", "t.t")
    body_c = _fts_predicate(backend, "m.body", "t.t")

    vec_cte = ""
    vec_join = "LEFT JOIN (SELECT name, NULL::int AS r, NULL::float AS sim FROM memories WHERE false) v USING (name)"
    if use_vec:
        params["qv"] = str(qv)
        vec_cte = f""",
        vec AS (
          SELECT name, 1 - (embedding <=> %(qv)s::vector) AS sim,
                 row_number() OVER (ORDER BY embedding <=> %(qv)s::vector) AS r
          FROM vis WHERE embedding IS NOT NULL
          ORDER BY embedding <=> %(qv)s::vector LIMIT {VEC_LIMIT}
        )"""
        vec_join = "LEFT JOIN vec v USING (name)"

    sql = f"""
    WITH terms AS (SELECT unnest(%(terms)s::text[]) AS t),
    vis AS (
      SELECT * FROM memories m
      WHERE {scope_sql}
        {"" if include_superseded else "AND m.status = 'active'"}
    ),
    cand AS (
      SELECT m.name,
             count(*) FILTER (WHERE {name_c}) AS c_name,
             count(*) FILTER (WHERE {desc_c}) AS c_desc,
             count(*) FILTER (WHERE {body_c}) AS c_body
      FROM vis m CROSS JOIN terms t
      WHERE {fts_where}
      GROUP BY m.name
    ),
    fts AS (
      SELECT name, row_number() OVER (
               ORDER BY (3*c_name + 2*c_desc + c_body) DESC, c_name DESC, name) AS r
      FROM cand LIMIT {FTS_LIMIT}
    ){vec_cte}
    SELECT m.file_path, m.name, m.description, m.scope::text, p.slug,
           m.kind::text, m.status::text, m.pinned,
           (m.review_by IS NOT NULL AND m.review_by < current_date) AS stale,
           {id_hit_expr} AS id_hit,
           f.r AS fts_rank, v.r AS vec_rank, v.sim,
           coalesce(1.0/({RRF_K}+f.r),0) + coalesce(1.0/({RRF_K}+v.r),0) AS rrf
    FROM vis m
    LEFT JOIN projects p ON p.id = m.home_project_id
    LEFT JOIN fts f USING (name)
    {vec_join}
    WHERE f.name IS NOT NULL
       OR (v.name IS NOT NULL AND v.sim >= %(tau)s)
       OR {id_hit_expr}
    ORDER BY id_hit DESC, rrf DESC, m.name
    LIMIT {int(k)}
    """
    with conn.cursor() as cur:
        cur.execute(sql, params)
        cols = [d.name for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]

    hits = [
        Hit(
            name=r["name"], file_path=_to_gitbash(r["file_path"]), description=r["description"],
            scope=r["scope"], project_key=r["slug"], kind=r["kind"], status=r["status"],
            pinned=r["pinned"], stale=r["stale"], id_hit=r["id_hit"],
            fts_rank=r["fts_rank"], vec_rank=r["vec_rank"], sim=r["sim"], rrf=float(r["rrf"]),
        )
        for r in rows
    ]

    # 降級且零命中 → 不可信（少了一路，無法排除是向量路才命中的查詢）→ A4：升級為失敗
    if degraded and not hits and mode == "hybrid":
        if not degrade_ok:
            raise RetrievalUnavailable(f"向量路不可用（{degraded}）且全文零命中，無法確認查無")
    return SearchResult(hits=hits, backend=backend, mode=eff_mode, degraded=degraded,
                        model=model, warnings=warnings)


def _scope_filter(scope: str | None, pk: str | None) -> tuple[str, dict]:
    if scope == "all":
        return "true", {}
    if scope == "global":
        return "m.scope = 'global'", {}
    if scope and scope not in ("all", "global"):    # 指定某 project_key
        # vis CTE 只有 memories m，沒有 join projects——用子查詢比對，不能寫 p.slug
        return ("(m.scope = 'global' OR m.home_project_id = (SELECT id FROM projects WHERE slug = %(pk)s))",
                {"pk": scope})
    # 預設：目前專案 + 全域
    if pk:
        return "(m.scope = 'global' OR m.home_project_id = (SELECT id FROM projects WHERE slug = %(pk)s))", {"pk": pk}
    return "m.scope = 'global'", {}


def log_access(conn: psycopg.Connection, *, event: str, cwd: str | None, keyword: str,
               hits: list[Hit], mode: str) -> None:
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM projects WHERE slug = %s", (resolve_project_key(conn, cwd),))
            row = cur.fetchone()
            cur.execute(
                """INSERT INTO memory_access_log(event, project_id, cwd, keyword, n, memory_ids, mode)
                   VALUES (%s,%s,%s,%s,%s,
                           (SELECT coalesce(array_agg(id),'{}') FROM memories WHERE name = ANY(%s)), %s)""",
                (event, row[0] if row else None, cwd, keyword, len(hits),
                 [h.name for h in hits], mode),
            )
        conn.commit()
    except psycopg.Error:
        conn.rollback()   # 遙測失敗絕不影響查詢結果
