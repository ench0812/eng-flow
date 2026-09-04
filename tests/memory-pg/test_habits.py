"""習慣學習：訊號提取、證據累加、autonomy 門檻與常駐檔渲染。

最容易靜默壞掉的是**增量掃描**——重掃同一批 transcript 會讓證據灌水，「看過 3 次」變成
「看過 30 次」，於是門檻形同虛設而且外表完全正常。那條有專門的測試。
"""

from __future__ import annotations

import datetime as _dt
import json

import pytest

from memory_pg import habits as H


def _rec(kind: str, content, ts="2026-09-01T10:00:00Z"):
    return json.dumps({"type": kind, "timestamp": ts, "message": {"content": content}},
                      ensure_ascii=False)


def _user(text):
    return _rec("user", text)


def _bash(cmd):
    return _rec("assistant", [{"type": "tool_use", "name": "Bash", "id": "t1",
                               "input": {"command": cmd}}])


def _askq(labels, qid="q1"):
    return _rec("assistant", [{"type": "tool_use", "name": "AskUserQuestion", "id": qid,
                               "input": {"questions": [{"header": "h", "options":
                                                        [{"label": l} for l in labels]}]}}])


def _answer(text, qid="q1"):
    return _rec("user", [{"type": "tool_result", "tool_use_id": qid, "content": text}])


@pytest.fixture
def tx(tmp_path, monkeypatch):
    """假的 transcript 樹。monkeypatch transcript_root 讓掃描指到這裡。"""
    root = tmp_path / "projects" / "P"
    root.mkdir(parents=True)
    monkeypatch.setattr(H, "transcript_root", lambda: tmp_path / "projects")
    return root


def _write(root, name: str, lines: list[str]):
    p = root / name
    p.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return p


# --- 純函式 -----------------------------------------------------------------

def test_first_command_signature():
    """簽名取前兩個詞：git push origin main 與 git push 是同一件事，git commit 不是。"""
    assert H._first_command({"command": "git push origin main"}) == "git push"
    assert H._first_command({"command": "git push"}) == "git push"
    assert H._first_command({"command": "git commit -m x"}) == "git commit"
    assert H._first_command({"command": "git push && npm test"}) == "git push"
    assert H._first_command({"command": "  "}) is None


def test_first_command_skips_prefix_noise():
    """必須跳過前置片段才找得到真正的動作。

    實測 328 個 transcript 的第一版輸出幾乎全是 `cd ~/.claude`、`M=/c/...`、`echo "==="`
    ——因為實際指令長成 `cd /d/Projects/x && git push`，只看第一段就只學得到 cd。
    """
    assert H._first_command({"command": 'cd /d/Projects/x && git push'}) == "git push"
    assert H._first_command({"command": 'cd ~/.claude; git status'}) == "git status"
    assert H._first_command({"command": 'M=/c/tmp; ls $M'}) == "ls $M"
    assert H._first_command({"command": 'B="/c/x"; docker exec claude-memory-pg pg_dump'}) \
        == "docker exec"
    assert H._first_command({"command": 'echo "==="; npm run build'}) == "npm run"
    # 修飾詞是剝掉、不是跳過整段——後面才是動作
    assert H._first_command({"command": 'for f in *; do git add $f; done'}) == "git add"
    assert H._first_command({"command": 'sudo systemctl restart x'}) == "systemctl restart"
    # 整條都是前置就沒有動作可學
    assert H._first_command({"command": 'cd /d/Projects/x'}) is None


def test_noise_is_not_user_speech():
    """tool_result 與系統訊息不是使用者說的話——不濾掉的話統計會被工具輸出淹沒。"""
    assert H._user_text("推") == ["推"]
    assert H._user_text("<local-command-caveat>Caveat: ...") == []
    assert H._user_text("Stop hook feedback: ...") == []
    assert H._user_text([{"type": "tool_result", "content": "很長的工具輸出"}]) == []
    assert H._user_text([{"type": "text", "text": "真的發言"}]) == ["真的發言"]


def test_confidence():
    assert H.confidence(9, 1) == pytest.approx(0.9)
    assert H.confidence(0, 0) == 0.0


# --- 掃描 -------------------------------------------------------------------

def test_scan_attributes_whole_turn_not_first_command(conn, tx):
    """一句簡語之後跑的**所有**動作都要歸因，不是只算第一個。

    實際情形是「推」之後先 `git status` 看一下、再 `git push`。只歸因第一個會學成
    「推 = git status」——實測 328 個 transcript 的第二版就是這樣壞的。每輪去重、各記一次，
    每次都出現的 git push 一致率才會壓過只在部分輪次出現的檢查指令。
    """
    lines = ([_user("推"), _bash("git status"), _bash("git push"), _bash("git push")]
             + [_user("推"), _bash("git push")] * 3)
    _write(tx, "turn.jsonl", lines)
    rep = H.scan(conn)
    c = next(c for c in rep.candidates if c["kind"] == "term" and c["quote"] == "推")
    # 同一輪內 git push 呼叫兩次只算一次（去重）；git status 是唯讀，完全不算動作
    assert dict(c["top_actions"]) == {"git push": 4}
    assert c["observations"] == 4


def test_scan_ignores_question_as_shorthand(conn, tx):
    """問句不是指令——不該被當成「這句話代表某個動作」。"""
    _write(tx, "q.jsonl", [_user("要用哪個?"), _bash("git push")] * 5)
    rep = H.scan(conn)
    assert [c for c in rep.candidates if c["kind"] == "term"] == []


def test_scan_skips_turns_with_too_many_actions(conn, tx):
    """一輪跑太多種動作就不歸因——那是一段工作，不是一個簡語的意思。"""
    lines = ([_user("繼續")] + [_bash(f"tool{i} run")
             for i in range(H.MAX_ACTIONS_PER_TURN + 1)]) * 4
    _write(tx, "many.jsonl", lines)
    rep = H.scan(conn)
    assert [c for c in rep.candidates if c["quote"] == "繼續"] == []


def test_term_is_candidate_only_never_auto(conn, tx):
    """簡語→動作**只當候選，不自動寫入**。

    實測 328 個 transcript：「推」36 次觀察，最高票 `git add` 只佔 14%、`git push` 11%；
    濾掉唯讀後最好的「推送」也只有 36%，而門檻是 85%。一句簡語之後是一整串工作，
    單一指令簽名代表不了意圖——所以交給 LLM 讀上下文，CLI 只提供統計佐證。
    """
    lines = []
    for _ in range(4):
        lines += [_user("推"), _bash("git push origin main")]
    _write(tx, "a.jsonl", lines)
    rep = H.scan(conn)
    assert [s for s in rep.auto if s.kind == "term"] == []      # 不進 auto
    c = next(c for c in rep.candidates if c["quote"] == "推")
    assert c["observations"] == 4 and c["top_actions"][0] == ["git push", 4]


def test_readonly_commands_are_not_actions():
    """唯讀指令不是意圖，是達成意圖過程中順手查看的東西。"""
    assert H._is_readonly("git status") and H._is_readonly("git log")
    assert H._is_readonly("grep foo") and H._is_readonly("sed 1,5p")
    assert not H._is_readonly("git push") and not H._is_readonly("git commit")
    assert not H._is_readonly("npm publish")


def test_rare_shorthand_not_worth_llm_attention(conn, tx):
    """觀察次數太少的簡語不進候選——不值得讓 LLM 花力氣判斷。"""
    _write(tx, "rare.jsonl", [_user("咦"), _bash("git push")])
    rep = H.scan(conn)
    assert [c for c in rep.candidates if c["quote"] == "咦"] == []


def test_scan_reports_every_pairing_without_filtering(conn, tx):
    """歧義的簡語**照樣如實輸出**，一列一個配對——過濾是 promote 的事，不是提取的事。

    提取端設門檻會讓跨晚的證據永遠累積不起來（掃描是增量的，每晚各看到一次就各自被丟掉）。
    這裡三個動作各一次，之後 promote 會因為一致率只有 33% 而不給任何一個 act。
    """
    lines = [_user("弄一下"), _bash("git push"),
             _user("弄一下"), _bash("npm test"),
             _user("弄一下"), _bash("docker ps")]
    _write(tx, "b.jsonl", lines)
    rep = H.scan(conn)
    c = next(c for c in rep.candidates if c["quote"] == "弄一下")
    assert dict(c["top_actions"]) == {"git push": 1, "npm test": 1, "docker ps": 1}


def test_scan_measures_recommendation_uptake(conn, tx):
    """AskUserQuestion 的採納率：選了標(推薦)的算 evidence，選別的算 counter。"""
    lines = [
        _askq(["甲案（推薦）", "乙案"], "q1"),
        _answer('Your questions have been answered: "x"="甲案（推薦）". continue', "q1"),
        _askq(["丙案（推薦）", "丁案"], "q2"),
        _answer('Your questions have been answered: "x"="丁案". continue', "q2"),
    ]
    _write(tx, "c.jsonl", lines)
    rep = H.scan(conn)
    ch = [s for s in rep.auto if s.kind == "choice"]
    assert len(ch) == 1
    assert ch[0].evidence == 1 and ch[0].counter == 1


def test_scan_skips_questions_without_recommendation(conn, tx):
    """沒有推薦項的題目不進採納率統計，否則分母被灌水、比率失真。"""
    lines = [_askq(["甲", "乙"], "q1"),
             _answer('Your questions have been answered: "x"="甲". continue', "q1")]
    _write(tx, "d.jsonl", lines)
    rep = H.scan(conn)
    assert [s for s in rep.auto if s.kind == "choice"] == []


def test_scan_collects_candidates_for_llm(conn, tx):
    """明講的規則與糾正只當候選——語義要 LLM 讀原文才成立，正則只負責找到它們。"""
    _write(tx, "e.jsonl", [
        _user("以後一律走 warpgate，不要直連 ssh"),
        _user("不對，這裡應該是白底黑框"),
        _user("順手把測試跑一下"),
    ])
    rep = H.scan(conn)
    kinds = [c["kind"] for c in rep.candidates]
    assert "directive" in kinds and "correction" in kinds
    assert all("順手把測試" not in c["quote"] for c in rep.candidates)


# --- 增量掃描（最容易靜默壞掉的一條）-----------------------------------------

def test_rescan_does_not_double_count(conn, tx):
    """**重掃同一批檔案不得重複累加證據。**

    沒有掃描位置的話，夢境每晚重掃會讓 evidence_count 一路灌水，門檻形同虛設——
    而且 `habits --list` 看起來完全正常，只是數字愈來愈大。
    """
    _write(tx, "f.jsonl", [_user("推"), _bash("git push")] * 3)
    first = H.scan(conn, commit_marks=True)
    conn.commit()
    assert first.files_scanned == 1
    assert next(c for c in first.candidates if c["quote"] == "推")["observations"] == 3

    second = H.scan(conn, commit_marks=True)   # 檔案沒動過
    conn.commit()
    assert second.files_scanned == 0
    assert second.candidates == [] and second.auto == []


def test_appended_transcript_only_scans_new_lines(conn, tx):
    """transcript 會被續寫：只掃新增的行，舊行不得再算一次。"""
    p = _write(tx, "g.jsonl", [_user("推"), _bash("git push")] * 3)
    H.scan(conn, commit_marks=True); conn.commit()
    with p.open("a", encoding="utf-8", newline="\n") as fh:
        for _ in range(3):
            fh.write(_user("推") + "\n" + _bash("git push") + "\n")
    rep = H.scan(conn, commit_marks=True); conn.commit()
    assert rep.files_scanned == 1
    # 只算新增那三輪；舊的三輪不得再算一次（重掃會讓證據灌水且外表正常）
    assert next(c for c in rep.candidates if c["quote"] == "推")["observations"] == 3


def test_truncated_transcript_rescans_from_start(conn, tx):
    """檔案變小＝被重寫，沿用舊 offset 會跳過內容——整份重掃。"""
    _write(tx, "h.jsonl", [_user("推"), _bash("git push")] * 8)
    H.scan(conn, commit_marks=True); conn.commit()
    _write(tx, "h.jsonl", [_user("推"), _bash("git push")] * 3)        # 重寫成更短
    rep = H.scan(conn, commit_marks=True); conn.commit()
    assert rep.files_scanned == 1
    assert next(c for c in rep.candidates if c["quote"] == "推")["observations"] == 3


# --- 寫入與門檻 --------------------------------------------------------------

def test_upsert_accumulates_not_duplicates(conn):
    H.upsert(conn, kind="term", pattern="推", meaning="git push", evidence=3)
    H.upsert(conn, kind="term", pattern="推", meaning="git push", evidence=2, counter=1)
    conn.commit()
    rows = H.listing(conn)
    assert len(rows) == 1
    assert rows[0]["evidence_count"] == 5 and rows[0]["counter_count"] == 1


def test_same_pattern_different_meaning_is_separate_row(conn):
    """同一簡語對到不同動作各自一列——這才看得見「另外那幾次做了別的事」。"""
    H.upsert(conn, kind="term", pattern="推", meaning="git push", evidence=9)
    H.upsert(conn, kind="term", pattern="推", meaning="npm publish", evidence=1)
    conn.commit()
    assert len(H.listing(conn)) == 2


def test_promote_consistency_spans_all_rows_of_a_pattern(conn):
    """一致率的分母是整個 pattern 的觀察總數，不是單列自己。

    只看單列的話「推→git push 9 次」永遠是 100%，完全看不見它另外 9 次做了別的事。
    """
    _seed_habit(conn, "推", ev=9, ct=0, span_days=30, meaning="git push")
    _seed_habit(conn, "推", ev=9, ct=0, span_days=30, meaning="npm publish")
    H.promote(conn); conn.commit()
    assert all(r["autonomy"] == "suggest" for r in H.listing(conn))


def test_upsert_caps_examples(conn):
    ex = [{"when": "2026-09-01", "where": f"f:{i}", "quote": "q"} for i in range(4)]
    H.upsert(conn, kind="term", pattern="推", meaning="git push", examples=ex)
    H.upsert(conn, kind="term", pattern="推", meaning="git push", examples=ex)
    conn.commit()
    assert len(H.listing(conn)[0]["examples"]) <= H.MAX_EXAMPLES


def _seed_habit(conn, pattern, ev, ct, span_days, meaning="git push", source="auto"):
    """source 預設 auto：這些測試驗的是**三道門檻本身**，不是來源分級（那有獨立測試）。
    用預設的 llm 會全部封頂在 suggest，門檻就測不到了。"""
    H.upsert(conn, kind="term", pattern=pattern, meaning=meaning,
             evidence=ev, counter=ct, source=source)
    with conn.cursor() as cur:
        cur.execute("UPDATE habits SET first_seen = current_date - %s WHERE pattern=%s",
                    (span_days, pattern))
    conn.commit()


def test_promote_requires_all_three_thresholds(conn):
    """三個門檻缺一不可。**跨天數那條最容易被忽略**——同一天連做五次不是習慣，是一次工作。"""
    _seed_habit(conn, "夠格", ev=6, ct=0, span_days=30)
    _seed_habit(conn, "次數不足", ev=2, ct=0, span_days=30)
    _seed_habit(conn, "一致率低", ev=6, ct=4, span_days=30)
    _seed_habit(conn, "同一天做完", ev=9, ct=0, span_days=0)
    H.promote(conn); conn.commit()
    got = {r["pattern"]: r["autonomy"] for r in H.listing(conn)}
    assert got["夠格"] == "act"
    assert got["次數不足"] == "suggest"
    assert got["一致率低"] == "suggest"
    assert got["同一天做完"] == "suggest"


def test_decay_demotes_but_never_retires(conn):
    """久未出現只收回『可直接執行』的授權，樣態留著——半年沒發版不代表發版流程變了。"""
    _seed_habit(conn, "久沒用", ev=9, ct=0, span_days=300)
    H.promote(conn); conn.commit()
    assert H.listing(conn)[0]["autonomy"] == "act"
    with conn.cursor() as cur:
        cur.execute("UPDATE habits SET last_seen = current_date - %s", (H.STALE_DAYS + 1,))
    conn.commit()
    stale = H.decay(conn); conn.commit()
    assert stale == ["久沒用"]
    row = H.listing(conn)[0]
    assert row["autonomy"] == "suggest" and row["status"] == "active"


def test_retire_requires_reason(conn):
    """retired 必須有原因，否則下次掃描又會把它學回來，而且沒人知道為什麼收掉。"""
    import psycopg
    H.upsert(conn, kind="term", pattern="沒用的", meaning="x")
    conn.commit()
    with pytest.raises(psycopg.Error):
        with conn.cursor() as cur:
            cur.execute("UPDATE habits SET status='retired' WHERE pattern='沒用的'")
    conn.rollback()
    assert H.retire(conn, "term", "沒用的", "使用者說不要了")
    conn.commit()
    assert H.listing(conn) == []
    assert len(H.listing(conn, include_retired=True)) == 1




# --- 常駐檔渲染 --------------------------------------------------------------

def test_render_md_within_budget_and_keeps_act(conn):
    """常駐檔有硬上限；砍的時候要砍信心最低的，act 區永遠保留。"""
    rows = []
    for i in range(60):
        rows.append({"kind": "term", "pattern": f"p{i}", "meaning": "m",
                     "evidence_count": 2, "counter_count": 0, "autonomy": "suggest",
                     "first_seen": _dt.date(2026, 1, 1), "last_seen": _dt.date(2026, 9, 1),
                     "status": "active", "examples": []})
    rows.insert(0, {"kind": "term", "pattern": "重要的", "meaning": "git push",
                    "evidence_count": 20, "counter_count": 0, "autonomy": "act",
                    "first_seen": _dt.date(2026, 1, 1), "last_seen": _dt.date(2026, 9, 1),
                    "status": "active", "examples": []})
    md = H.render_md(rows)
    assert len(md.splitlines()) <= H.HABITS_MAX_LINES + 3
    assert "重要的" in md and "可直接執行" in md
    assert "未列出" in md            # 有砍就要講砍了幾條


def test_render_md_states_the_three_rules(conn):
    """常駐檔開頭必須帶著使用規則——規則優先、要講依據、可逆性不因習慣鬆動。"""
    md = H.render_md([])
    assert "CLAUDE.md 的明文規則優先" in md
    assert "講一句依據" in md
    assert "可逆性把關不因習慣而鬆動" in md
    # 一致率的讀法不可省略，否則判讀寫入的 100% 會被當成機械統計的結論
    assert "不是統計結論" in md


def test_export_writes_file(conn, home):
    H.upsert(conn, kind="term", pattern="推", meaning="git push", evidence=9)
    conn.commit()
    n = H.export_md(conn, home / "habits.md")
    assert n == 1
    assert "推" in (home / "habits.md").read_text(encoding="utf-8")


def test_signal_carries_observed_dates_not_write_date(conn, tx):
    """訊號要帶著**實際觀察到的日期**，不是寫入當天。

    用寫入日的話，一次匯入四個月的歷史資料會全部變成 span=0，ACT_MIN_SPAN_DAYS 那條門檻
    對歷史資料永遠不成立（實測：89/22 的 choice 訊號匯入後 first_seen=last_seen=今天）。
    """
    lines = []
    for d in ("2026-05-01", "2026-08-20"):
        lines += [_askq(["甲（推薦）", "乙"], f"q{d}"),
                  _rec("user", [{"type": "tool_result", "tool_use_id": f"q{d}",
                                 "content": 'answered: "x"="甲"'}], ts=f"{d}T10:00:00Z")]
    _write(tx, "dates.jsonl", lines)
    rep = H.scan(conn)
    ch = next(s for s in rep.auto if s.kind == "choice")
    assert ch.first_seen == "2026-05-01" and ch.last_seen == "2026-08-20"

    H.upsert(conn, kind=ch.kind, pattern=ch.pattern, meaning=ch.meaning,
             evidence=ch.evidence, counter=ch.counter,
             first_seen=ch.first_seen, last_seen=ch.last_seen)
    conn.commit()
    row = H.listing(conn)[0]
    assert str(row["first_seen"]) == "2026-05-01" and str(row["last_seen"]) == "2026-08-20"


def test_upsert_widens_date_range_never_narrows(conn):
    """跨掃描合併日期範圍：取聯集，不是覆蓋成最近一次。"""
    H.upsert(conn, kind="term", pattern="推", meaning="git push",
             first_seen="2026-06-01", last_seen="2026-06-30")
    H.upsert(conn, kind="term", pattern="推", meaning="git push",
             first_seen="2026-05-01", last_seen="2026-07-15")
    conn.commit()
    row = H.listing(conn)[0]
    assert str(row["first_seen"]) == "2026-05-01" and str(row["last_seen"]) == "2026-07-15"


def test_agent_notifications_are_not_user_speech(conn, tx):
    """以 user 身分出現在 transcript 裡、但不是使用者打的字：全部要濾掉。

    實測 328 個 transcript：directive 候選有一半是 <task-notification>、context 續接訊息，
    以及我派給 subagent 的 brief（在子 agent 的 transcript 裡也是 user，而且常含
    「不要規劃…」「一律…」正好誤觸 DIRECTIVE_RE）。
    """
    _write(tx, "noise.jsonl", [
        _user("<task-notification>\n<task-id>abc</task-id>\n以後一律這樣"),
        _user("This session is being continued from a previous conversation. 記住這個"),
        _user("為 D:/Projects/x 設計實作計劃。" + "你負責的軸是資料契約，一律不要規劃 UI。" * 40),
        _user("以後一律走 warpgate"),
    ])
    rep = H.scan(conn)
    quotes = [c["quote"] for c in rep.candidates if c["kind"] == "directive"]
    assert quotes == ["以後一律走 warpgate"]


def test_choice_counted_per_question_not_per_call(conn, tx):
    """**逐題計數，不是逐次呼叫。**

    攤平成一個 pool 的話，「兩題、一題採納一題拒絕」會被記成一次完整採納，而且兩題只算
    一個樣本。實測全量 332 檔：攤平 90/112 = 80.4%，逐題 148/197 = 75.1%，樣本少 43%。
    這是全系統唯一分子分母都機械數出來的習慣，錯了會連帶誤導其他條目的讀法。
    """
    call = _rec("assistant", [{"type": "tool_use", "name": "AskUserQuestion", "id": "q1",
                               "input": {"questions": [
                                   {"question": "第一題", "options": [{"label": "甲（推薦）"},
                                                                      {"label": "乙"}]},
                                   {"question": "第二題", "options": [{"label": "丙（推薦）"},
                                                                      {"label": "丁"}]}]}}])
    # 真實格式：答案值連「（推薦）」標記一起回填
    ans = _answer('Your questions have been answered: "第一題"="甲（推薦）", '
                  '"第二題"="丁". continue', "q1")
    _write(tx, "perq.jsonl", [call, ans])
    rep = H.scan(conn)
    ch = next(s for s in rep.auto if s.kind == "choice")
    assert ch.evidence == 1 and ch.counter == 1          # 兩個樣本，一採納一拒絕


def test_choice_uses_exact_label_match_not_substring(conn, tx):
    """比對選中的 label 本體，不對整段答案做子字串比對。

    整段答案含問題原文，而問題常回述選項字眼——子字串比對會把「問題裡提到甲」誤判成
    「選了甲」。
    """
    call = _askq(["甲案（推薦）", "乙案"], "q1")
    ans = _answer('Your questions have been answered: "要用甲案還是乙案？"="乙案". continue', "q1")
    _write(tx, "sub.jsonl", [call, ans])
    rep = H.scan(conn)
    ch = next(s for s in rep.auto if s.kind == "choice")
    assert ch.evidence == 0 and ch.counter == 1          # 選的是乙案，不算採納


def test_limit_files_takes_most_recent_by_mtime(conn, tmp_path, monkeypatch):
    """--limit-files 要取最近修改的，不是路徑字典序。

    transcript 檔名是隨機 UUID，字典序的「最後 N 個」與「最近 N 個」交集為零（實測）。
    """
    import os, time
    root = tmp_path / "projects" / "P"
    root.mkdir(parents=True)
    monkeypatch.setattr(H, "transcript_root", lambda: tmp_path / "projects")
    # 字典序最後的是 zzz，但最近修改的是 aaa
    for name in ("zzz.jsonl", "mmm.jsonl", "aaa.jsonl"):
        p = root / name
        p.write_text(_user("推") + "\n" + _bash("git push") + "\n", encoding="utf-8", newline="\n")
    now = time.time()
    for name, age in (("zzz.jsonl", 300), ("mmm.jsonl", 200), ("aaa.jsonl", 1)):
        os.utime(root / name, (now - age, now - age))
    rep = H.scan(conn, limit_files=1)
    assert rep.files_seen == 1


# --- review 修正後補的迴歸測試 ------------------------------------------------

def test_llm_source_capped_at_suggest(conn):
    """**LLM 判讀寫入的習慣升不到 act**，不管證據數填多大。

    三道門檻（次數/一致率/跨天數）的輸入由夢境的 LLM 自己填，一次
    `--add --evidence 39 --first-seen ... --last-seen ...` 就三道全過——門檻約束不到
    真正產生 act 的那條路徑。實測 2026-09-04 寫入的四則 act 全部是這樣來的。
    """
    H.upsert(conn, kind="term", pattern="推", meaning="git push",
             evidence=39, first_seen="2026-07-01", last_seen="2026-09-03", source="llm")
    conn.commit()
    H.promote(conn); conn.commit()
    assert H.listing(conn)[0]["autonomy"] == "suggest"


def test_auto_and_human_sources_may_reach_act(conn):
    """機械統計與使用者親自確認可以升 act——門檻對它們才有意義。"""
    for src, pat in (("auto", "機械"), ("human", "人工")):
        H.upsert(conn, kind="term", pattern=pat, meaning="git push",
                 evidence=9, first_seen="2026-07-01", last_seen="2026-09-03", source=src)
    conn.commit()
    H.promote(conn); conn.commit()
    got = {r["pattern"]: r["autonomy"] for r in H.listing(conn)}
    assert got == {"機械": "act", "人工": "act"}


def test_source_only_upgrades(conn):
    """human 確認過的不會被之後的 llm 判讀降級。"""
    H.upsert(conn, kind="term", pattern="推", meaning="git push", source="human")
    H.upsert(conn, kind="term", pattern="推", meaning="git push", source="llm")
    conn.commit()
    assert H.listing(conn)[0]["source"] == "human"


def test_retired_habit_does_not_revive_on_rescan(conn):
    """**使用者的否決要黏著。**

    原本 upsert 無條件 `status='active', retired_reason=NULL`，於是「別再學這個」被下一次
    掃描原地撤銷、理由還被抹掉——使用者只會看到它又出現在 habits.md，得再講一次，
    而 DB 裡沒有任何線索說明它曾被否決。這是個無限循環。
    """
    H.upsert(conn, kind="term", pattern="別學我", meaning="x")
    conn.commit()
    H.retire(conn, "term", "別學我", "使用者說這不是習慣")
    conn.commit()

    H.upsert(conn, kind="term", pattern="別學我", meaning="x", evidence=5)   # 又被觀察到
    conn.commit()
    rows = H.listing(conn, include_retired=True)
    assert rows[0]["status"] == "retired"                    # 沒有復活
    assert rows[0]["evidence_count"] == 6                    # 但證據照樣累加
    assert rows[0]["last_retired_reason"] == "使用者說這不是習慣"   # 理由留著
    assert H.listing(conn) == []                             # 不出現在常駐清單


def test_unretire_is_the_explicit_way_back(conn):
    """改變主意要走明確入口，且回到 suggest 重新累積。"""
    H.upsert(conn, kind="term", pattern="回心轉意", meaning="x", source="human",
             evidence=9, first_seen="2026-07-01", last_seen="2026-09-03")
    conn.commit()
    H.retire(conn, "term", "回心轉意", "先收起來")
    conn.commit()
    assert H.unretire(conn, "term", "回心轉意")
    conn.commit()
    row = H.listing(conn)[0]
    assert row["status"] == "active" and row["autonomy"] == "suggest"
    assert row["retired_count"] == 1


def test_preview_scan_does_not_advance_marks(conn, tx):
    """**預覽不得推進掃描位置。**

    早期版本無論如何都寫 marks，於是 SKILL.md 教的順序（先看、再 --apply）第二步必然
    掃到 0 行，輸出像「今晚沒有新東西」，證據永遠累加不到。
    """
    _write(tx, "p.jsonl", [_user("推"), _bash("git push")] * 3)
    first = H.scan(conn)                      # 預覽（commit_marks 預設 False）
    conn.commit()
    assert first.files_scanned == 1
    second = H.scan(conn, commit_marks=True)  # 真正要寫入的那次仍看得到全部
    conn.commit()
    assert second.files_scanned == 1
    third = H.scan(conn, commit_marks=True)   # 這次才該是空的
    conn.commit()
    assert third.files_scanned == 0


def test_agent_transcripts_are_skipped(conn, tx):
    """subagent 的 transcript 不掃——那裡的 user 訊息是我派工的 brief。"""
    _write(tx, "agent-abc.jsonl", [_user("以後一律走 warpgate")] * 3)
    _write(tx, "normal.jsonl", [_user("以後一律用 rg")])
    rep = H.scan(conn)
    quotes = [c["quote"] for c in rep.candidates]
    assert quotes == ["以後一律用 rg"]


def test_first_command_handles_subshell(conn):
    """`( cd /d/x && git push )` 的第一段是 `(cd`，精確比對認不出來。"""
    assert H._first_command({"command": "( cd /d/Projects/x && git push )"}) == "git push"
    assert not H._is_readonly("git config")      # git config user.email x 是寫入


def test_llm_evidence_cannot_inflate_trusted_row(conn):
    """**LLM 判讀不得為 auto/human 的列增加證據。**

    只擋「來源升級」是不夠的：auto 列被 llm upsert 灌進自填的 evidence 之後 source 仍是
    auto，promote() 就拿那些數字把它升成 act——0005 想擋的整個繞過去。
    """
    H.upsert(conn, kind="choice", pattern="機械統計", meaning="x",
             evidence=2, counter=1, source="auto",
             first_seen="2026-07-01", last_seen="2026-09-03")
    conn.commit()
    H.upsert(conn, kind="choice", pattern="機械統計", meaning="x",
             evidence=99, source="llm")          # LLM 想灌進來
    conn.commit()
    row = H.listing(conn)[0]
    # evidence_count 是總數（顯示與一致率用），evidence_trusted 才是門檻吃的那個
    assert row["evidence_count"] == 101
    assert row["evidence_trusted"] == 2, "LLM 的證據被算進可信證據了"
    assert row["source"] == "auto"
    H.promote(conn); conn.commit()
    assert H.listing(conn)[0]["autonomy"] == "suggest"


def test_counter_accumulates_from_any_source(conn):
    """反例相反：任何來源的反例都要算，證據不可以被洗白。"""
    H.upsert(conn, kind="choice", pattern="有反例", meaning="x", evidence=9, source="auto",
             first_seen="2026-07-01", last_seen="2026-09-03")
    conn.commit()
    H.upsert(conn, kind="choice", pattern="有反例", meaning="x",
             evidence=0, counter=5, source="llm")
    conn.commit()
    row = H.listing(conn)[0]
    assert row["counter_count"] == 5


def test_trusted_evidence_survives_source_upgrade(conn):
    """**先 llm、後 auto 的順序也不能把 LLM 的證據洗成可信。**

    只擋「auto 列被 llm 灌」是不夠的：先由 LLM 寫入高 evidence 與跨月日期，之後一次真實的
    auto 訊號讓 source 升級成 auto，那些自填的數字就掛在一列 source='auto' 上，promote()
    照樣升 act。單一計數器 + 單一來源標記在結構上做不到這件事——來源是列的屬性，
    證據是逐次累加的，粒度不同。
    """
    H.upsert(conn, kind="choice", pattern="順序繞過", meaning="x",
             evidence=99, source="llm", first_seen="2026-06-01", last_seen="2026-09-03")
    conn.commit()
    H.upsert(conn, kind="choice", pattern="順序繞過", meaning="x",
             evidence=1, source="auto")          # 一次真實訊號讓來源升級
    conn.commit()
    row = H.listing(conn)[0]
    assert row["source"] == "auto"
    assert row["evidence_count"] == 100
    assert row["evidence_trusted"] == 1, "LLM 先寫入的證據被來源升級洗白了"
    H.promote(conn); conn.commit()
    assert H.listing(conn)[0]["autonomy"] == "suggest"
