"""夢境衰減（decay）的公式、休眠/甦醒判定與 migration 語義。

分兩層：純函式的曲線行為不碰 DB；狀態機（休眠、甦醒、豁免、cutoff）要真的塞 access log
重播，因為它的錯誤形態正是「重播順序錯了但每一步看起來都對」。
"""

from __future__ import annotations

import datetime as _dt

import psycopg
import pytest

from memory_pg import decay


# --- 純函式 -----------------------------------------------------------------

def test_strength_growth_two_tiers():
    """rank 1–3 是一次完整命中，rank ≥4 是半次——兩次半次才等於一次完整。"""
    assert decay._grow(30.0, 1) == pytest.approx(48.0)
    assert decay._grow(30.0, 3) == pytest.approx(48.0)
    half = decay._grow(30.0, 4)
    assert half == pytest.approx(30.0 * decay.GROWTH_HALF)
    assert decay._grow(half, 9) == pytest.approx(48.0)      # 兩次半次 == 一次完整
    assert decay._grow(decay.MAX_STRENGTH, 1) == decay.MAX_STRENGTH   # 封頂


def test_score_decays_and_clamps():
    today = _dt.date(2026, 9, 4)
    assert decay._score(30.0, today, today) == pytest.approx(1.0)
    assert decay._score(30.0, today - _dt.timedelta(days=30), today) == pytest.approx(0.3679, abs=1e-3)
    # anchor 在未來（時鐘偏移）不得算出 >1 的機率
    assert decay._score(30.0, today + _dt.timedelta(days=5), today) == 1.0


def test_below_threshold_at_is_first_day_at_or_below():
    """推導出的日期必須是 R **首次** ≤ 門檻的那天，前一天仍在門檻之上。

    這條釘住的是 `date + timedelta(days=56.9)` 會截成 56 天的陷阱：不向上取整的話，
    回傳日當天的 R 其實還是 0.1546 > 0.15，休眠會早一天觸發、與 `_score` 互相矛盾。
    """
    anchor = _dt.date(2026, 1, 1)
    for s in (10.0, 30.0, 77.5, 365.0):
        d = decay.below_threshold_at(s, anchor)
        assert decay._score(s, anchor, d) <= decay.DORMANT_THRESHOLD
        assert decay._score(s, anchor, d - _dt.timedelta(days=1)) > decay.DORMANT_THRESHOLD


def test_today_comes_from_db_not_localtime(conn):
    """「今天」必須與 SQL 端同一個基準。

    PG 跑在 Etc/UTC 而本機是 UTC+8，凌晨 00:00–08:00 兩者差一天。Python 端若用
    `date.today()`，同一則記憶會出現「compute 判定在保護期內、search 的 SQL 判定在保護期外」
    這種互相矛盾的狀態。
    """
    with conn.cursor() as cur:
        cur.execute("SELECT current_date")
        assert decay.db_today(conn) == cur.fetchone()[0]


# --- DB helper --------------------------------------------------------------

def _mem(conn, name: str, *, created_days_ago: int = 400, pinned: bool = False,
         exempt: bool = False, dormant: _dt.date | None = None) -> str:
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO memories(name, description, body, file_path, scope, pinned, "
            "decay_exempt, dormant_since) VALUES (%s,'d','b',%s,'global',%s,%s,%s) RETURNING id",
            (name, f"C:\\g\\{name}.md", pinned, exempt, dormant),
        )
        mid = cur.fetchone()[0]
        cur.execute("UPDATE memories SET created_at = now() - make_interval(days => %s) WHERE id=%s",
                    (created_days_ago, mid))
    conn.commit()
    return str(mid)


def _hit(conn, ids: list[str], *, days_ago: int, event: str = "search"):
    """塞一筆 access log。ids 的順序就是命中排名（cutoff 之後才這樣解讀）。"""
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO memory_access_log(ts, event, keyword, n, memory_ids) "
            "VALUES (now() - make_interval(days => %s), %s, 'k', %s, %s::uuid[])",
            (days_ago, event, len(ids), ids),
        )
    conn.commit()


def _state(rep, name: str):
    return next(s for s in rep.states if s.name == name)


# --- cutoff 與歷史資料 -------------------------------------------------------

def test_cutoff_read_from_schema_migrations(conn):
    """cutoff 是 DB 事實不是程式常數——換機器或重建 DB 都要各自正確。"""
    cut = decay.cutoff(conn)
    assert cut is not None
    with conn.cursor() as cur:
        cur.execute("SELECT applied_at FROM schema_migrations WHERE version=3")
        assert cur.fetchone()[0] == cut


def test_pre_cutoff_log_ignores_array_order(conn):
    """cutoff 之前的 memory_ids 是 array_agg 的掃描順序，不是排名。

    兩則記憶在同一筆舊 log 裡分居陣列首尾，若誤把位置當 rank，後面那則會被少算強度——
    而那完全是 DB 掃描順序的偶然。這裡直接斷言兩者強度相同。
    """
    a = _mem(conn, "old-first")
    b = _mem(conn, "old-last")
    # 把 log 時間推到 cutoff 之前
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO memory_access_log(ts, event, keyword, n, memory_ids) "
            "VALUES ((SELECT applied_at FROM schema_migrations WHERE version=3) "
            "        - interval '1 day', 'search', 'k', 2, %s::uuid[])",
            ([a, b],),
        )
    conn.commit()
    rep = decay.compute(conn)
    assert _state(rep, "old-first").strength == _state(rep, "old-last").strength
    assert _state(rep, "old-last").strength == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_FULL)


def test_post_cutoff_log_uses_array_order(conn):
    """cutoff 之後的順序由 log_access 保序寫入，位置就是 rank。"""
    ids = [_mem(conn, f"r{i}") for i in range(5)]
    _hit(conn, ids, days_ago=0)
    rep = decay.compute(conn)
    assert _state(rep, "r0").strength == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_FULL)
    assert _state(rep, "r2").strength == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_FULL)
    assert _state(rep, "r3").strength == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_HALF)
    assert _state(rep, "r4").strength == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_HALF)


def test_inject_events_are_ignored(conn):
    """inject 是灌 pinned，與有沒有用無關——算進去等於讓已豁免的更豁免。"""
    m = _mem(conn, "injected-only")
    _hit(conn, [m], days_ago=1, event="inject")
    rep = decay.compute(conn)
    assert _state(rep, "injected-only").hit_count == 0
    assert _state(rep, "injected-only").strength == decay.INITIAL_STRENGTH


# --- 休眠與甦醒 --------------------------------------------------------------

def test_dormant_only_after_grace_period(conn):
    """跌破門檻不會立刻休眠，要再撐滿 DORMANT_GRACE_DAYS。"""
    # 400 天沒被碰過、S=30 → below_threshold_at ≈ created + 57 天，早就過了寬限期
    _mem(conn, "long-cold", created_days_ago=400)
    rep = decay.compute(conn)
    assert _state(rep, "long-cold").newly_dormant is True

    # 剛好跌破門檻但寬限期未滿：R < 門檻，仍不休眠
    m2 = _mem(conn, "just-below", created_days_ago=400)
    with conn.cursor() as cur:
        cur.execute("SELECT created_at::date FROM memories WHERE id=%s", (m2,))
        created = cur.fetchone()[0]
    edge = decay.below_threshold_at(decay.INITIAL_STRENGTH, created) + _dt.timedelta(days=1)
    rep2 = decay.compute(conn, today=edge)
    st = _state(rep2, "just-below")
    assert st.score < decay.DORMANT_THRESHOLD
    assert st.newly_dormant is False and st.dormant_since is None


def test_revive_beats_dormant_in_same_pass(conn):
    """被撈回來命中的記憶，同一輪不得又被判休眠；S 重設為 REVIVE_STRENGTH。"""
    yesterday = decay.db_today(conn) - _dt.timedelta(days=1)
    m = _mem(conn, "came-back", created_days_ago=400, dormant=yesterday - _dt.timedelta(days=10))
    _hit(conn, [m], days_ago=1)
    rep = decay.compute(conn)
    st = _state(rep, "came-back")
    assert st.revived is True
    assert st.dormant_since is None
    assert st.strength == decay.REVIVE_STRENGTH
    assert st.newly_dormant is False


def test_dormant_stays_dormant_without_hit(conn):
    """沒有新命中就維持休眠，不會每晚重複回報成『新休眠』。"""
    old = decay.db_today(conn) - _dt.timedelta(days=5)
    _mem(conn, "still-asleep", created_days_ago=400, dormant=old)
    rep = decay.compute(conn)
    st = _state(rep, "still-asleep")
    assert st.dormant_since == old and st.newly_dormant is False and st.revived is False


# --- 豁免 --------------------------------------------------------------------

@pytest.mark.parametrize("name,kw,reason", [
    ("p", {"pinned": True}, "pinned"),
    ("e", {"exempt": True}, "exempt"),
    ("n", {"created_days_ago": 3}, "new"),
])
def test_exemptions_never_dormant_and_full_weight(conn, name, kw, reason):
    _mem(conn, name, **{"created_days_ago": 400, **kw})
    st = _state(decay.compute(conn), name)
    assert st.exempt_reason == reason
    assert st.newly_dormant is False and st.dormant_since is None
    assert st.weight == 1.0


def test_weight_has_floor(conn):
    """降權是往後推幾名，不是埋掉——權重不得低於 floor。"""
    _mem(conn, "ancient", created_days_ago=3650)
    st = _state(decay.compute(conn), "ancient")
    assert st.score < 0.01
    assert st.weight == decay.DECAY_FLOOR


# --- 寫回 --------------------------------------------------------------------

def test_recompute_backfills_dead_columns(conn):
    """access_count / last_accessed_at 在此之前是死欄位（建表就有，沒有 UPDATE 路徑）。"""
    m = _mem(conn, "counted")
    _hit(conn, [m], days_ago=3)
    _hit(conn, [m], days_ago=1)
    decay.recompute(conn)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT access_count, last_accessed_at, recall_strength, recall_score, "
                    "dormant_since FROM memories WHERE name='counted'")
        cnt, last, s, r, dorm = cur.fetchone()
    assert cnt == 2
    assert last is not None and (decay.db_today(conn) - last.date()).days == 1
    assert s == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_FULL ** 2, rel=1e-5)
    assert 0.0 <= r <= 1.0 and dorm is None


# --- 與檢索路徑的接縫 --------------------------------------------------------

def test_log_access_preserves_rank_order(conn):
    """`memory_ids` 的順序**就是**命中排名——這是整個 spacing effect 的資料來源。

    舊版用 `array_agg(id) FROM memories WHERE name = ANY(...)`，出來是 DB 掃描順序，
    「排第 1」與「排第 10」在資料裡分不出來。這裡塞一組刻意與字典序、與插入序都不同的
    順序，斷言讀回來一模一樣。
    """
    from memory_pg import search as S

    ids = [_mem(conn, f"h{i}") for i in range(5)]
    order = [ids[3], ids[0], ids[4], ids[1], ids[2]]
    hits = [S.Hit(id=i, name=f"n{k}", file_path="p", description="d", scope="global",
                  project_key=None, kind=None, status="active", pinned=False, stale=False,
                  id_hit=False, fts_rank=1, vec_rank=None, sim=None, rrf=0.1)
            for k, i in enumerate(order)]
    S.log_access(conn, event="search", cwd=None, keyword="k", hits=hits, mode="fts")
    with conn.cursor() as cur:
        cur.execute("SELECT memory_ids FROM memory_access_log ORDER BY id DESC LIMIT 1")
        assert [str(x) for x in cur.fetchone()[0]] == order


def _search_names(conn, query: str, **kw):
    from memory_pg import config, search as S
    res = S.search(conn, config.load(use_test_db=True), query, cwd=None, mode="fts", **kw)
    return [h.name for h in res.hits]


def _seed_searchable(conn, name: str, **kw) -> str:
    """建一則搜得到的記憶（description 帶關鍵字）。"""
    mid = _mem(conn, name, **kw)
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET description='關於松鼠的事實' WHERE id=%s", (mid,))
    conn.commit()
    return mid


def test_search_excludes_dormant_by_default(conn, home):
    _seed_searchable(conn, "awake-one")
    _seed_searchable(conn, "asleep-one", dormant=decay.db_today(conn))
    assert _search_names(conn, "松鼠") == ["awake-one"]
    assert sorted(_search_names(conn, "松鼠", include_dormant=True)) == ["asleep-one", "awake-one"]


def test_decay_weight_reorders_without_burying(conn, home):
    """低分的往後排，但不得被埋掉——floor 保證它仍在結果內。"""
    _seed_searchable(conn, "cold-one")
    _seed_searchable(conn, "warm-one")
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET recall_score=0.02 WHERE name='cold-one'")
        cur.execute("UPDATE memories SET recall_score=1.0 WHERE name='warm-one'")
    conn.commit()
    names = _search_names(conn, "松鼠")
    assert names == ["warm-one", "cold-one"]      # 排後面
    assert "cold-one" in names                    # 但還在


def test_protected_new_memory_keeps_full_weight(conn, home):
    """保護期內的新記憶即使分數低也拿滿權重——SQL 端與 compute 必須同調。"""
    _seed_searchable(conn, "brand-new", created_days_ago=1)
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET recall_score=0.01 WHERE name='brand-new'")
    conn.commit()
    from memory_pg import config, search as S
    res = S.search(conn, config.load(use_test_db=True), "松鼠", cwd=None, mode="fts")
    assert res.hits[0].decay_weight == 1.0
    assert _state(decay.compute(conn), "brand-new").exempt_reason == "new"


# --- 人工救回 ----------------------------------------------------------------

def _edit(conn, home, name: str, **kw):
    from memory_pg import config, mutate
    mutate.edit(conn, config.load(use_test_db=True), name,
                description=None, body=None, reason="test", **kw)
    conn.commit()


def _dormant_of(conn, name: str):
    with conn.cursor() as cur:
        cur.execute("SELECT dormant_since, decay_exempt FROM memories WHERE name=%s", (name,))
        return cur.fetchone()


@pytest.mark.parametrize("flag", ["no_decay", "pin"])
def test_manual_rescue_wakes_dormant(conn, home, flag):
    """`--no-decay` 與 `--pin` 都代表「這則要留著」，必須同時叫醒。

    不清 `dormant_since` 的話，被豁免/釘選的記憶仍被預設搜尋與索引排除——救回會變成
    無效操作，而且指令回報成功、外表看不出來。
    """
    _seed_searchable(conn, "rescue-me", dormant=decay.db_today(conn))
    assert _search_names(conn, "松鼠") == []
    _edit(conn, home, "rescue-me", **({"decay_exempt": True} if flag == "no_decay" else {"pin": True}))
    assert _dormant_of(conn, "rescue-me")[0] is None
    assert _search_names(conn, "松鼠") == ["rescue-me"]


def test_allow_decay_clears_exempt_but_does_not_sleep(conn, home):
    """反向操作只取消豁免，**不主動休眠**——是否休眠由下次 recompute 依分數決定。"""
    _seed_searchable(conn, "let-it-go", exempt=True)
    _edit(conn, home, "let-it-go", decay_exempt=False)
    dorm, exempt = _dormant_of(conn, "let-it-go")
    assert exempt is False and dorm is None
    assert _search_names(conn, "松鼠") == ["let-it-go"]


def test_unpin_does_not_sleep(conn, home):
    _seed_searchable(conn, "was-pinned", pinned=True)
    _edit(conn, home, "was-pinned", pin=False)
    assert _dormant_of(conn, "was-pinned")[0] is None


# --- 匯出與稽核 --------------------------------------------------------------

def _export(conn, home):
    from memory_pg import config, exporter
    return exporter.run(conn, config.load(use_test_db=True), verify_dir=None)


def _index_text(home) -> str:
    p = home / "memory" / "MEMORY.md"
    return p.read_text(encoding="utf-8") if p.exists() else ""


def test_dormant_leaves_file_but_drops_from_index(conn, home):
    """休眠的三個必要條件同時成立：**檔案還在**、索引沒有它、audit 不報 unmanaged_file。

    這三條是一組的。只要把 dormant 從寫檔迴圈跳過，第一條會壞，而且症狀不是「少一個檔」
    ——是下一次 export 直接 ExportAborted（那個 .md 落在 known 之外），整個匯出停擺。
    """
    from memory_pg import audit, config

    _mem(conn, "sleepy-pin", pinned=True)
    _mem(conn, "awake-pin", pinned=True)
    _export(conn, home)
    assert "sleepy-pin" in _index_text(home)

    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET dormant_since=current_date WHERE name='sleepy-pin'")
    conn.commit()
    _export(conn, home)

    assert (home / "memory" / "sleepy-pin.md").exists()          # 檔案還在
    idx = _index_text(home)
    assert "sleepy-pin" not in idx and "awake-pin" in idx        # 索引沒有它
    codes = [f.code for f in audit.run(conn, config.load(use_test_db=True)).findings]
    assert "unmanaged_file" not in codes                         # 不被當成未認領

    # 甦醒後索引重新含它
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET dormant_since=NULL WHERE name='sleepy-pin'")
    conn.commit()
    _export(conn, home)
    assert "sleepy-pin" in _index_text(home)


def test_dormant_tagged_pinned_not_leaked_into_project_index(conn, home):
    """tagged pinned 走的是另外兩個入口（預建 bank、tagged_pinned 收集）。

    只改 `pinned` / `topics` 那兩個 list comprehension 的話，被 tag 的休眠記憶仍會從這裡
    漏進專案索引——四個入口要一致。
    """
    from conftest import seed_banks
    seed_banks(home)
    with conn.cursor() as cur:
        cur.execute("INSERT INTO projects(slug, root_path, bank_path) VALUES "
                    "('P1', %s, %s) RETURNING id",
                    (str(home / "p1"), str(home / "projects" / "P1" / "memory")))
        pid = cur.fetchone()[0]
    mid = _mem(conn, "tagged-sleepy", pinned=True)
    with conn.cursor() as cur:
        cur.execute("INSERT INTO memory_projects(memory_id, project_id) VALUES (%s,%s)", (mid, pid))
    conn.commit()

    _export(conn, home)
    proj_idx = (home / "projects" / "P1" / "memory" / "MEMORY.md")
    assert proj_idx.exists() and "tagged-sleepy" in proj_idx.read_text(encoding="utf-8")

    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET dormant_since=current_date WHERE name='tagged-sleepy'")
    conn.commit()
    _export(conn, home)
    assert "tagged-sleepy" not in proj_idx.read_text(encoding="utf-8")


def test_audit_dormant_candidate(conn, home):
    from memory_pg import audit, config
    _mem(conn, "about-to-sleep")
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET recall_score=0.05 WHERE name='about-to-sleep'")
    conn.commit()
    codes = {f.code: f.detail for f in audit.run(conn, config.load(use_test_db=True)).findings}
    assert "dormant_candidate" in codes and "about-to-sleep" in codes["dormant_candidate"]


def test_audit_exempt_unused_spares_new_memories(conn, home):
    """90 天下界：剛建立就標豁免的不得被報——它還沒機會被叫到。"""
    from memory_pg import audit, config
    _mem(conn, "old-exempt", exempt=True, created_days_ago=200)
    _mem(conn, "new-exempt", exempt=True, created_days_ago=5)
    findings = [f.detail for f in audit.run(conn, config.load(use_test_db=True)).findings
                if f.code == "decay_exempt_unused"]
    assert any("old-exempt" in d for d in findings)
    assert not any("new-exempt" in d for d in findings)


# --- migration 對既有列的語義 ------------------------------------------------

def test_migration_defaults_on_existing_rows(test_dsn):
    """0003 套到【既有列】上的預設值——不能靠空庫「碰巧沒有列」來證明。"""
    from memory_pg import migrate

    with psycopg.connect(test_dsn, connect_timeout=3) as c:
        with c.cursor() as cur:
            cur.execute("DROP SCHEMA IF EXISTS decay_probe CASCADE")
            cur.execute("CREATE SCHEMA decay_probe")
            cur.execute("SET search_path TO decay_probe, public")
        try:
            migrate.apply_one(c, "0001_init.sql")
            migrate.apply_one(c, "0002_scope_machine_work.sql")
            with c.cursor() as cur:
                cur.execute("INSERT INTO memories(name, description, body, file_path, scope) "
                            "VALUES ('pre','d','b','/pre','global')")
            migrate.apply_one(c, "0003_dream_decay.sql")
            with c.cursor() as cur:
                cur.execute("SELECT recall_strength, recall_score, dormant_since, decay_exempt "
                            "FROM memories WHERE name='pre'")
                assert cur.fetchone() == (decay.INITIAL_STRENGTH, 1.0, None, False)

            # CHECK 約束要真的擋住不合法的值，否則錯誤會靜默留在資料裡。
            # **每條各用一個 savepoint**：違反約束會讓交易進 aborted 狀態，直接 rollback
            # 會把整個 probe schema 的 DDL 一起回捲，search_path 退回 public，接著的 UPDATE
            # 就落到測試庫真正的 memories 上、影響 0 列而不報錯——測試會假通過。
            for col, bad in (("recall_score", 1.5), ("recall_score", -0.1),
                             ("recall_strength", 0)):
                with pytest.raises(psycopg.Error):
                    with c.transaction():
                        with c.cursor() as cur:
                            cur.execute(f"UPDATE memories SET {col} = %s WHERE name='pre'", (bad,))
            with c.cursor() as cur:   # schema 還在，證明上面的回捲只到 savepoint
                cur.execute("SELECT count(*) FROM memories WHERE name='pre'")
                assert cur.fetchone()[0] == 1
        finally:
            c.rollback()
            with c.cursor() as cur:
                cur.execute("DROP SCHEMA IF EXISTS decay_probe CASCADE")
            c.commit()


# --- review 修正後補的迴歸測試 ------------------------------------------------

def test_same_day_hits_fold_into_one(conn):
    """同一天的多次命中只算一次成長。

    不折疊的話 S 依「被搜尋到幾次」成長而非「在幾個不同的日子被想起過」，而
    `30 × 1.6⁶ > 365`——**六次命中就封頂**，封頂等於最後命中日 +707 天才休眠。
    一輪工作為同一問題查三次是常態，兩三個 session 就讓記憶進入近兩年免疫期，
    分佈退化成「查過的永不淡出／沒查過的第 71 天淡出」，中間沒有梯度。
    """
    m = _mem(conn, "same-day")
    for _ in range(5):                       # 同一天查五次
        _hit(conn, [m], days_ago=3)
    st = _state(decay.compute(conn), "same-day")
    assert st.strength == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_FULL)
    assert st.hit_count == 1                 # 五次命中折疊成一天


def test_hits_on_distinct_days_do_grow(conn):
    """不同日子的命中才各自累積——這是 spacing effect 的本意。"""
    m = _mem(conn, "spaced")
    for d in (9, 6, 3):
        _hit(conn, [m], days_ago=d)
    st = _state(decay.compute(conn), "spaced")
    assert st.strength == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_FULL ** 3)
    assert st.hit_count == 3


def test_same_day_takes_best_rank(conn):
    """同一天既排第 1 也排第 8 時，算前者。"""
    ids = [_mem(conn, f"d{i}") for i in range(8)]
    _hit(conn, list(reversed(ids)), days_ago=2)   # d7 在第 1 位
    _hit(conn, ids, days_ago=2)                   # 同一天，d7 在第 8 位
    st = _state(decay.compute(conn), "d7")
    assert st.strength == pytest.approx(decay.INITIAL_STRENGTH * decay.GROWTH_FULL)


def test_revive_when_hit_lands_on_dormant_day(conn):
    """**命中日等於 dormant_since 時必須甦醒。**

    休眠是入夢當晚（本地 21:03 ＝ 13:03 UTC）寫下的，而兩個日期都是 UTC 日：使用者當晚
    22:00 用 --include-dormant 撈回並命中，ts::date 仍等於 dormant_since。用 `>` 比較的話
    這筆救回被永久吞掉——記憶繼續被預設搜尋與索引排除，而使用者以為已經叫醒它了。
    """
    today = decay.db_today(conn)
    m = _mem(conn, "same-day-rescue", created_days_ago=400, dormant=today)
    _hit(conn, [m], days_ago=0)              # 與 dormant_since 同一天
    st = _state(decay.compute(conn), "same-day-rescue")
    assert st.revived is True and st.dormant_since is None


def test_dormant_day_hit_does_not_cause_false_wake(conn):
    """反向確認 `>=` 不會誤醒：沒有任何命中的休眠記憶維持休眠。"""
    today = decay.db_today(conn)
    _mem(conn, "no-rescue", created_days_ago=400, dormant=today)
    st = _state(decay.compute(conn), "no-rescue")
    assert st.revived is False and st.dormant_since == today


def test_dormant_md_stays_current_not_just_present(conn, home):
    """休眠的 `.md` 不只要存在，**內容還要跟著更新**。

    原本的測試先 export（檔案已寫出）再設 dormant，所以「把 dormant 從寫檔迴圈跳過」
    這個改動照樣通過——檔案還在，只是從此凍結在休眠前那一版。而 CLAUDE.md 明文承諾
    「.md 檔照常匯出、內容仍是最新的」。這裡在休眠狀態下改 body，斷言檔案跟著變。
    """
    _mem(conn, "sleepy-fresh", pinned=True)
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET dormant_since=current_date, body=%s "
                    "WHERE name='sleepy-fresh'", ("\n第一版內容\n",))
    conn.commit()
    _export(conn, home)
    p = home / "memory" / "sleepy-fresh.md"
    assert "第一版內容" in p.read_text(encoding="utf-8")

    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET body=%s WHERE name='sleepy-fresh'",
                    ("\n第二版內容\n",))
    conn.commit()
    _export(conn, home)
    txt = p.read_text(encoding="utf-8")
    assert "第二版內容" in txt and "第一版內容" not in txt


def _seed_many(conn, n: int, best: str):
    """種 n 則都會命中「松鼠」的記憶；best 那則的 description 命中最多次（fts rank 1）。"""
    for i in range(n):
        _seed_searchable(conn, f"z-other-{i:02d}")
    mid = _mem(conn, best)
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET description='松鼠 松鼠 松鼠', body='\n松鼠松鼠\n' "
                    "WHERE id=%s", (mid,))
    conn.commit()
    return mid


def test_low_score_hit_is_pushed_back_not_buried(conn, home):
    """**降權必須是「往後推幾名」，不是踢出結果。**

    第一版用 `rrf * decay_weight`，而 RRF 在候選窗內的動態範圍只有 1.64 倍
    （rank1=1/61、rank40=1/100），權重下限的倒數卻是 1/0.55=1.82 倍——權重完全支配相關性，
    被壓到 floor 的第 1 名等效名次是 (60+1)/0.55-60 ≈ 51，直接掉出預設的 k=10。
    那還會自我維持：掉出 top-k → 不進 access log → 拿不到命中 → R 繼續掉。

    原本的測試只種 2 則、k=10，`assert "cold-one" in names` 在候選數 < k 時恆真，
    把 DECAY_FLOOR 改成 0.0001 也照樣綠。這裡種 12 則才有鑑別力。
    """
    mid = _seed_many(conn, 11, "aaa-best-match")
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET recall_score=0.02 WHERE id=%s", (mid,))
        cur.execute("UPDATE memories SET recall_score=1.0 WHERE name LIKE 'z-other-%'")
    conn.commit()
    names = _search_names(conn, "松鼠")
    assert "aaa-best-match" in names, f"最佳匹配被埋掉了：{names}"
    # 有被推後（不是完全不受影響），但仍在預設結果內
    assert names.index("aaa-best-match") > 0


def test_exact_id_finds_dormant_memory(conn, home):
    """用完整 id 查休眠記憶必須查得到。

    不豁免的話回傳的是與「這則不存在」位元組一致的空結果（exit 0、零行、無警示），
    而這個模組的 A4 原則正是「失敗不可以長得像查無」，docstring 也把 id 列為第一等檢索欄位。
    典型受害者正是「很少查但一查就救命」的陷阱型記憶。
    """
    _seed_searchable(conn, "sqlc-windows-silent-noop", dormant=decay.db_today(conn))
    assert _search_names(conn, "sqlc-windows-silent-noop") == ["sqlc-windows-silent-noop"]
    # 非 id 的一般查詢仍然照休眠規則排除
    assert _search_names(conn, "松鼠") == []
