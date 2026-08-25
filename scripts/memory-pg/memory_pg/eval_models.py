"""模型選型評測（memory eval）。對候選 embedding 模型跑 golden set，用數據選，不憑分數表。

指標：向量路 top-3 命中率、MRR、20 則批次耗時、冷啟動、500/NaN 次數、
負例最高 sim 與 golden 目標最低 sim 的分離度（→ 建議 tau）。
選擇規則（依序）：① 任何 500/NaN → 淘汰 ② hybrid top-3 需全中（達不到是全文路的問題）
③ vector-only MRR 高者勝（差<0.05 平手）④ 平手看 sim margin ⑤ 再平手取小模型。
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import psycopg

from . import embed as embedmod
from .config import Config

# (query, expected_id)；與 test_search 的 golden 對齊，但這裡只評向量路的相對排序能力
GOLDEN = [
    ("gh 權限不足 推不上去", "gh-auth-workflow-scope"),
    ("裝置流程 認證", "gh-auth-workflow-scope"),
    ("哪一台是正式生產機", "pgs-deployment-reality"),
    ("怎麼部署到 rose", "pgs-native-deploy-procedure"),
    ("三重玫瑰 樓層 車格 數量", "rose-map-import-baseline"),
    ("尋車機 怎麼連 怎麼量效能", "nav-jetson-field-access"),
    ("還需要做效能優化嗎", "nav-perf-ceiling-2026-08"),
    ("六個 repo 的工作區結構", "pgs-workspace-layout"),
]
NEGATIVES = ["React useEffect 依賴陣列", "藍牙耳機配對失敗", "統一發票 開立"]


@dataclass
class ModelResult:
    model: str
    top3: float = 0.0
    mrr: float = 0.0
    embed_20_ms: float = 0.0
    cold_ms: float = 0.0
    nan_count: int = 0
    tau_suggest: float = 0.0
    neg_max_sim: float = 0.0
    golden_min_sim: float = 0.0
    notes: list[str] = field(default_factory=list)


def _cos(a: list[float], b: list[float]) -> float:
    import math
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a)); nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def evaluate(conn: psycopg.Connection, cfg: Config, model: str) -> ModelResult:
    r = ModelResult(model=model)
    with conn.cursor() as cur:
        cur.execute("SELECT name, description, body FROM memories WHERE status='active'")
        rows = cur.fetchall()
    docs = [(n, embedmod.build_embed_text(n, d, b)) for n, d, b in rows]

    t0 = time.monotonic()
    embedmod.embed_texts(cfg, model, [docs[0][1]], timeout=120.0)
    r.cold_ms = (time.monotonic() - t0) * 1000

    best = 1e9
    for _ in range(3):
        t0 = time.monotonic()
        vecs = embedmod.embed_texts(cfg, model, [t for _, t in docs], timeout=180.0)
        best = min(best, (time.monotonic() - t0) * 1000)
    r.embed_20_ms = best
    r.nan_count = sum(1 for v in vecs if v is None)
    if r.nan_count:
        r.notes.append(f"{r.nan_count} 則嵌入失敗（500/NaN）→ 淘汰")
        return r
    docvec = {docs[i][0]: vecs[i] for i in range(len(docs))}

    qvecs = embedmod.embed_texts(cfg, model, [q for q, _ in GOLDEN], timeout=120.0)
    ranks = []
    golden_sims = []
    for (q, expected), qv in zip(GOLDEN, qvecs):
        if qv is None:
            r.nan_count += 1; r.notes.append(f"query 嵌入失敗: {q}"); return r
        sims = sorted(((_cos(qv, docvec[n]), n) for n in docvec), reverse=True)
        pos = next((i for i, (_, n) in enumerate(sims) if n == expected), 999)
        ranks.append(pos)
        golden_sims.append(next(s for s, n in sims if n == expected))
    r.top3 = sum(1 for p in ranks if p < 3) / len(ranks)
    r.mrr = sum(1.0 / (p + 1) for p in ranks) / len(ranks)
    r.golden_min_sim = min(golden_sims)

    nvecs = embedmod.embed_texts(cfg, model, NEGATIVES, timeout=120.0)
    neg_max = 0.0
    for nv in nvecs:
        if nv is None:
            continue
        neg_max = max(neg_max, max(_cos(nv, docvec[n]) for n in docvec))
    r.neg_max_sim = neg_max
    # tau 建議：落在負例最高與 golden 最低之間（取中點；若倒掛則取負例最高）
    r.tau_suggest = round((neg_max + r.golden_min_sim) / 2, 3) if r.golden_min_sim > neg_max else round(neg_max, 3)
    return r


def choose(results: list[ModelResult]) -> tuple[ModelResult | None, list[str]]:
    log = []
    alive = [r for r in results if r.nan_count == 0]
    for r in results:
        if r.nan_count:
            log.append(f"{r.model}: 淘汰（{r.nan_count} 次 500/NaN）")
    if not alive:
        return None, log
    alive.sort(key=lambda r: r.mrr, reverse=True)
    top = alive[0]
    if len(alive) > 1 and abs(alive[0].mrr - alive[1].mrr) < 0.05:
        # 平手 → sim margin 大者勝
        alive.sort(key=lambda r: (r.golden_min_sim - r.neg_max_sim), reverse=True)
        if abs((alive[0].golden_min_sim - alive[0].neg_max_sim) - (alive[1].golden_min_sim - alive[1].neg_max_sim)) < 0.02:
            alive.sort(key=lambda r: r.embed_20_ms)   # 再平手取快的
        top = alive[0]
        log.append(f"MRR 接近，改以 sim margin / 速度選出 {top.model}")
    else:
        log.append(f"MRR 最高：{top.model}")
    return top, log
