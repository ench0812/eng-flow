"""decay — 夢境的遺忘曲線：召回強度（S）、召回分數（R）、休眠與甦醒。

模型是 Ebbinghaus 的 R = exp(-t/S) 加上 spacing effect：每被想起一次，S 就變大一點，
所以常用的記憶幾乎不衰減，久未被想起的才慢慢淡出。

**三個貫穿判斷**：

1. **分數是夜間物化的，不在搜尋路徑即時算。** 每次搜尋多一次 UPDATE 不划算，而且分數要能
   被報告與 audit 引用、可稽核；一天一次的粒度對「天」為單位的衰減完全夠。
2. **訊號只取 search，完全排除 inject。** inject 是 SessionStart 灌 pinned，與「有沒有用」
   無關；而 pinned 本來就豁免衰減，把它算進去只會讓已豁免的更豁免。
3. **命中不等於被採用。** access_log 記的是「出現在結果裡」，這是這套模型能拿到的最強訊號，
   但它偏弱——所以有 floor、有保護期、有豁免，讓判斷錯誤的代價是「排後面幾名」而不是
   「消失」。

**歷史資料的 cutoff 讀 DB 不讀常數**：0003 之前的 `memory_access_log.memory_ids` 是
`array_agg` 的 DB 掃描順序、不是命中排名，只能當「有無命中」用。cutoff 取
`schema_migrations.applied_at`（0001 就有這個欄位），寫成程式常數的話換機器或重建 DB
就會把新資料誤判成歷史資料。
"""

from __future__ import annotations

import datetime as _dt
import math
from dataclasses import dataclass, field

import psycopg

# --- 模型參數 ---------------------------------------------------------------
# 調整這些值會改變全庫的淡出速度，改完要重跑 `memory decay --report` 看分佈再決定。
INITIAL_STRENGTH = 30.0      # S 初值（天）。新記憶約一個月沒被想起就掉到 R≈0.37
MAX_STRENGTH = 365.0         # S 上限。到頂等於「一年不想起才開始明顯衰減」
GROWTH_FULL = 1.6            # rank 1–3 命中的 S 成長倍率
GROWTH_HALF = math.sqrt(GROWTH_FULL)   # rank ≥4：半次命中，兩次才等於一次完整命中
TOP_RANK = 3                 # 「排在前面」的界線
REVIVE_STRENGTH = 60.0       # 甦醒後的 S。比初值高——再學習比初學快
DORMANT_THRESHOLD = 0.15     # R 低於此值才算「快忘了」
DORMANT_GRACE_DAYS = 14      # 低於門檻後還要撐這麼多天才真的休眠
PROTECT_DAYS = 30            # 新記憶保護期：天生沒有命中數，不該因此被壓
DECAY_FLOOR = 0.55           # 權重下限（0~1）。R 再低，權重也不低於此
# 降權在**名次空間**進行：等效名次 = 實際名次 + PENALTY_RANKS × (1 − weight)。
# 所以這個常數就是「最多往後推幾名」的字面意思。
#
# **不可以改回 `rrf * weight` 的乘法**（2026-09-04 review 抓到，實測驗證）：RRF 在候選窗內
# 的整個動態範圍只有 `(60+40)/(60+1) = 1.64` 倍，而權重下限的倒數是 `1/0.55 = 1.82` 倍。
# 1.82 > 1.64 意味著**權重完全支配相關性**——被壓到 floor 的第 1 名會排在滿權重的第 51 名
# 之後（等效名次 `(60+1)/0.55 − 60 ≈ 51`），也就是直接掉出預設的 k=10。
# 那還會自我維持：掉出 top-k → 不進 access log → 拿不到命中 → R 繼續掉。
DECAY_PENALTY_RANKS = 10

MIGRATION_VERSION = 3        # 本功能的 migration 版本，cutoff 由它的 applied_at 決定


@dataclass
class MemoryDecay:
    """一則記憶重算後的衰減狀態。"""
    id: str
    name: str
    strength: float
    score: float
    dormant_since: _dt.date | None
    hit_count: int
    last_hit: _dt.datetime | None
    exempt_reason: str | None      # pinned | exempt | new | None
    revived: bool = False
    newly_dormant: bool = False

    @property
    def weight(self) -> float:
        return 1.0 if self.exempt_reason else max(DECAY_FLOOR, self.score)


@dataclass
class RecomputeReport:
    cutoff: _dt.datetime | None = None
    scanned: int = 0
    newly_dormant: list[str] = field(default_factory=list)
    revived: list[str] = field(default_factory=list)
    states: list[MemoryDecay] = field(default_factory=list)


def cutoff(conn: psycopg.Connection) -> _dt.datetime | None:
    """0003 的套用時刻。None = 尚未套用（呼叫端應視為「全部都是歷史資料」）。"""
    with conn.cursor() as cur:
        cur.execute("SELECT applied_at FROM schema_migrations WHERE version = %s",
                    (MIGRATION_VERSION,))
        row = cur.fetchone()
    return row[0] if row else None


def db_today(conn: psycopg.Connection) -> _dt.date:
    """「今天」一律以 DB 為準，**不用 `date.today()`**。

    整套系統的日期判定都跑在 PG 的時區上：`review_by < current_date`（audit 的 overdue）、
    `created_at > now() - interval` （search 的保護期）、`verify` 寫的 `last_verified`。
    Python 端若改用本地日期，在 PG 是 UTC 而本地是 UTC+8 的凌晨時段，同一則記憶會出現
    「compute 判定為保護期內、SQL 判定為保護期外」這種互相矛盾的狀態。

    衰減是以 30–365 天為尺度的模型，日界差幾小時完全不影響結論；**一致性才是重點**。
    """
    with conn.cursor() as cur:
        cur.execute("SELECT current_date")
        return cur.fetchone()[0]


def _grow(strength: float, rank: int) -> float:
    factor = GROWTH_FULL if rank <= TOP_RANK else GROWTH_HALF
    return min(strength * factor, MAX_STRENGTH)


def _score(strength: float, anchor: _dt.date, today: _dt.date) -> float:
    """R = exp(-t/S)，t 以天計。anchor 在未來（時鐘偏移）時 t 視為 0。"""
    t = max(0, (today - anchor).days)
    return max(0.0, min(1.0, math.exp(-t / strength)))


def below_threshold_at(strength: float, anchor: _dt.date) -> _dt.date:
    """R 首次低於 DORMANT_THRESHOLD 的日期。由 anchor 與 S 完全決定，所以不另存欄位——
    多存一份就多一個會跟 S 漂移的真相來源。

    **必須向上取整**：`date + timedelta(days=56.9)` 會截掉小數變成 56 天，而第 56 天的
    R 還在門檻之上（S=30 時是 0.1546 > 0.15）。不進位會讓休眠早一天觸發，判定與 `_score`
    互相矛盾。
    """
    days = math.ceil(strength * math.log(1.0 / DORMANT_THRESHOLD))
    return anchor + _dt.timedelta(days=days)


def _exempt_reason(pinned: bool, exempt: bool, created: _dt.date, today: _dt.date) -> str | None:
    if pinned:
        return "pinned"
    if exempt:
        return "exempt"
    if (today - created).days < PROTECT_DAYS:
        return "new"
    return None


def _hits_by_memory(conn: psycopg.Connection,
                    cut: _dt.datetime | None) -> dict[str, list[tuple[_dt.datetime, _dt.date, int]]]:
    """每則記憶的 (命中時間, rank) 清單，依時間排序。

    rank 來自 `memory_ids` 的陣列位置，但**只有 cutoff 之後的資料能這樣讀**——之前的是
    `array_agg` 的掃描順序，一律當成 rank 1（完整命中）。把舊資料當成排名會系統性地
    誤判：碰巧排在陣列後面的記憶會被少算強度，而那完全是 DB 掃描順序的偶然。

    **同一天內的多次命中折疊成一次**（取當天最好的 rank）。這不是效能考量，是模型正確性：

    S 的成長要反映「在幾個**不同的日子**被想起過」，不是「被搜尋到幾次」——Ebbinghaus 的
    間隔重複本來就以間隔為單位。不折疊的話後果很硬：rank 1–3 的成長是 1.6 倍，
    `30 × 1.6⁶ > 365` 所以**六次命中就封頂**，而封頂等於「最後命中日 + 707 天」才會休眠
    （未命中過的是 71 天）。同一輪工作為同一個問題查 2–3 次是常態（自己查一次、subagent
    再查一次），於是兩三個 session 就讓一則記憶進入近兩年的免疫期，分佈退化成二元：
    查過幾次的永不淡出、一次沒查過的第 71 天淡出，中間沒有梯度——那等於整個功能空轉。
    """
    # (memory, 當地日期) → (當天最後一次的 ts, 當天最好的 rank)
    best: dict[tuple[str, _dt.date], tuple[_dt.datetime, int]] = {}
    with conn.cursor() as cur:
        # 日期由 PG 轉（`ts::date` 走連線時區），Python 端不自己算——見 db_today 的說明。
        # ts::date 必須給別名——不給的話輸出欄位也叫 ts，ORDER BY ts 會 AmbiguousColumn。
        cur.execute("SELECT ts, ts::date AS ts_date, memory_ids FROM memory_access_log "
                    "WHERE event = 'search' ORDER BY ts, id")
        for ts, ts_date, ids in cur.fetchall():
            ordered = bool(cut and ts >= cut)
            for i, mid in enumerate(ids or []):
                rank = (i + 1) if ordered else 1
                key = (str(mid), ts_date)
                prev = best.get(key)
                if prev is None:
                    best[key] = (ts, rank)
                else:
                    # ts 取當天最後一次（anchor 用），rank 取當天最好的一次
                    best[key] = (max(ts, prev[0]), min(rank, prev[1]))

    out: dict[str, list[tuple[_dt.datetime, _dt.date, int]]] = {}
    for (mid, ts_date), (ts, rank) in best.items():
        out.setdefault(mid, []).append((ts, ts_date, rank))
    for hits in out.values():
        hits.sort(key=lambda h: h[0])   # dict 的插入序不按時間，這裡不是 no-op
    return out


def compute(conn: psycopg.Connection, *, today: _dt.date | None = None) -> RecomputeReport:
    """重算全庫狀態但**不寫入**。report 與 recompute 共用，確保兩者永遠一致。"""
    today = today or db_today(conn)
    cut = cutoff(conn)
    hits_map = _hits_by_memory(conn, cut)
    rep = RecomputeReport(cutoff=cut)

    with conn.cursor() as cur:
        cur.execute("SELECT id, name, created_at::date, pinned, decay_exempt, dormant_since "
                    "FROM memories WHERE status = 'active' ORDER BY name")
        rows = cur.fetchall()

    for mid, name, created, pinned, exempt, dormant_since in rows:
        hits = hits_map.get(str(mid), [])
        strength = INITIAL_STRENGTH
        for _ts, _d, rank in hits:
            strength = _grow(strength, rank)
        last_hit = hits[-1][0] if hits else None
        last_hit_date = hits[-1][1] if hits else None
        anchor = last_hit_date or created

        revived = False
        newly_dormant = False
        # 甦醒優先於休眠判定：剛被撈回來的不該在同一輪又被判休眠。
        #
        # **比較用 `>=` 不是 `>`。** 休眠是入夢當晚（本地 21:03 ＝ 13:03 UTC）寫下的，
        # 而 `dormant_since` 與命中日都是 **UTC 日**：使用者在當晚 22:00 用
        # `--include-dormant` 撈回並命中，`ts::date` 仍等於 `dormant_since`。用 `>` 的話
        # `D > D` 為假，這筆救回被永久吞掉——該則記憶繼續被預設搜尋與索引排除，
        # 而使用者以為自己已經把它叫醒了。受影響的是本地 21:03～隔日 08:00 那 11 小時，
        # 正好是入夢剛跑完、人還在工作的時段。
        #
        # `>=` 不會反向誤醒：命中日等於 D 的記憶其 anchor 就是 D，
        # `below_threshold_at(S, D) >= D + 56`，不可能在 D 當天被判休眠。
        if dormant_since is not None and last_hit_date is not None and last_hit_date >= dormant_since:
            dormant_since = None
            strength = REVIVE_STRENGTH
            revived = True

        reason = _exempt_reason(pinned, exempt, created, today)
        score = _score(strength, anchor, today)

        if dormant_since is None and reason is None:
            if today >= below_threshold_at(strength, anchor) + _dt.timedelta(days=DORMANT_GRACE_DAYS):
                dormant_since = today
                newly_dormant = True

        st = MemoryDecay(id=str(mid), name=name, strength=strength, score=score,
                         dormant_since=dormant_since, hit_count=len(hits), last_hit=last_hit,
                         exempt_reason=reason, revived=revived, newly_dormant=newly_dormant)
        rep.states.append(st)
        if revived:
            rep.revived.append(name)
        if newly_dormant:
            rep.newly_dormant.append(name)

    rep.scanned = len(rep.states)
    return rep


def recompute(conn: psycopg.Connection, *, today: _dt.date | None = None) -> RecomputeReport:
    """重算並寫回。呼叫端負責交易（沿用 write/edit 的 top_level_transaction 慣例）。

    `access_count` 與 `last_accessed_at` 在此之前是死欄位（建表就有，沒有任何 UPDATE 路徑，
    全表 0 / NULL）。這裡一併回填——不是為了排名（排名讀 recall_score），而是讓
    「這則記憶被叫過幾次」這個問題有一個直接查得到的答案。
    """
    rep = compute(conn, today=today)
    with conn.cursor() as cur:
        cur.executemany(
            "UPDATE memories SET recall_strength=%s, recall_score=%s, dormant_since=%s, "
            "access_count=%s, last_accessed_at=%s WHERE id=%s",
            [(s.strength, s.score, s.dormant_since, s.hit_count, s.last_hit, s.id)
             for s in rep.states],
        )
    return rep
