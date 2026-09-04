from __future__ import annotations

import io
import shutil
import sys

from pathlib import Path

import pytest

from conftest import seed_banks, write_memory  # noqa: E402

from memory_pg import cli, config, exporter, importer, mutate  # noqa: E402


def _cfg():
    return config.load(use_test_db=True)


def _seed_projects(conn, home: Path):
    # 建兩個已登錄專案（write 到 project scope 需要）
    (home / "projects" / "D--Projects-IntelliPark" / "memory").mkdir(parents=True)
    (home / "projects" / "D--Projects-pcpms-car-navigator" / "memory").mkdir(parents=True)
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()


def test_write_global_and_export(conn, home: Path):
    _seed_projects(conn, home)
    with conn.cursor():
        pass
    mutate.write(conn, _cfg(), name="new-global", scope="global",
                 description="全域新記憶——摘要", body="\n內容一段。\n", kind="reference" if False else "semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT scope::text, pinned, importance FROM memories WHERE name='new-global'")
        assert cur.fetchone() == ("global", False, 3)
    exporter.run(conn, _cfg(), verify_dir=None)
    assert (home / "memory" / "new-global.md").exists()


def test_write_project_needs_slug(conn, home: Path):
    _seed_projects(conn, home)
    with pytest.raises(mutate.MutateError):
        mutate.write(conn, _cfg(), name="x", scope="project", description="d", body="\nb\n")


def test_write_tags(conn, home: Path):
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="shared-fact", scope="global", description="共享事實",
                 body="\nb\n", tags=["D--Projects-IntelliPark", "D--Projects-pcpms-car-navigator"])
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memory_projects mp JOIN memories m ON m.id=mp.memory_id WHERE m.name='shared-fact'")
        assert cur.fetchone()[0] == 2


def test_learn_supersedes(conn, home: Path):
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="old-way", scope="global", description="舊做法 alpha beta", body="\nold\n")
    conn.commit()
    mutate.learn(conn, _cfg(), supersedes=["old-way"], confirms=[], force=True,
                 name="new-way", scope="global", description="新做法 gamma delta", body="\nnew\n")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT status::text FROM memories WHERE name='old-way'")
        assert cur.fetchone()[0] == "superseded"
    # 匯出：新的帶 supersedes、舊的帶 superseded_by
    exporter.run(conn, _cfg(), verify_dir=None)
    new_md = (home / "memory" / "new-way.md").read_text(encoding="utf-8")
    old_md = (home / "memory" / "old-way.md").read_text(encoding="utf-8")
    assert "supersedes: [old-way]" in new_md
    assert "superseded_by: new-way" in old_md


def test_learn_dup_refused(conn, home: Path):
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="fact-a", scope="global",
                 description="部署主機位址與環境設定說明", body="\nx\n")
    conn.commit()
    with pytest.raises(mutate.MutateError) as e:
        mutate.learn(conn, _cfg(), supersedes=[], confirms=[], force=False,
                     name="fact-b", scope="global",
                     description="部署主機位址與環境設定說明", body="\ny\n")
    assert "疑似重複" in str(e.value)
    conn.rollback()   # 清掉 dup 偵測 SELECT 開的交易；fact-a 已 commit 仍在
    # --force 可過（fact-a 依舊存在，這次新增 fact-b）
    mutate.learn(conn, _cfg(), supersedes=[], confirms=[], force=True,
                 name="fact-b", scope="global", description="部署主機位址與環境設定說明", body="\ny\n")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name IN ('fact-a','fact-b')")
        assert cur.fetchone()[0] == 2


def test_learn_confirms_validates(conn, home: Path):
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="base-fact", scope="global", description="基礎 aaa bbb", body="\nx\n")
    conn.commit()
    # --confirms 指向不存在 → 拋錯，不靜默新增
    with pytest.raises(mutate.MutateError):
        mutate.learn(conn, _cfg(), supersedes=[], confirms=["no-such"], force=True,
                     name="c1", scope="global", description="全新 ccc ddd", body="\ny\n")
    conn.rollback()
    # 重複 --confirms 只加一次 evidence
    mutate.learn(conn, _cfg(), supersedes=[], confirms=["base-fact", "base-fact"], force=True,
                 name="c2", scope="global", description="全新 eee fff", body="\nz\n")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT evidence_count FROM memories WHERE name='base-fact'")
        assert cur.fetchone()[0] == 2   # 起始 1 + 一次（去重）


def test_verify_rejects_negative_and_nonactive(conn, home: Path):
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="vf", scope="global", description="d", body="\nx\n", review_by="2026-09-01")
    conn.commit()
    with pytest.raises(mutate.MutateError):
        mutate.verify(conn, _cfg(), "vf", method=None, extend_days=-5)
    conn.rollback()
    mutate.forget(conn, _cfg(), "vf", reason="停用")
    conn.commit()
    with pytest.raises(mutate.MutateError):
        mutate.verify(conn, _cfg(), "vf", method=None, extend_days=90)


def test_forget_and_verify(conn, home: Path):
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="temp-fact", scope="global", description="暫時", body="\nx\n",
                 review_by="2026-01-01")
    conn.commit()
    mutate.forget(conn, _cfg(), "temp-fact", reason="過時", status="deprecated")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT status::text, valid_until IS NOT NULL FROM memories WHERE name='temp-fact'")
        assert cur.fetchone() == ("deprecated", True)
        cur.execute("SELECT count(*) FROM memory_revisions WHERE memory_id=(SELECT id FROM memories WHERE name='temp-fact')")
        assert cur.fetchone()[0] == 1
    # forget 非 active 應報錯
    with pytest.raises(mutate.MutateError):
        mutate.forget(conn, _cfg(), "temp-fact", reason="again")
    conn.rollback()
    # verify 順延 review_by
    mutate.write(conn, _cfg(), name="check-me", scope="global", description="要覆核", body="\nx\n",
                 review_by="2026-09-01")
    conn.commit()
    mutate.verify(conn, _cfg(), "check-me", method="實測", extend_days=90)
    conn.commit()
    import datetime as dt
    with conn.cursor() as cur:
        # `last_verified` 由 `verify()` 寫成 PG 的 `current_date`，所以斷言也要用 DB 的今天。
        # 拿 Python 的 `date.today()` 比對會在本地凌晨 00:00–08:00 失敗——PG 跑 Etc/UTC，
        # 那個窗口內兩者差一天（2026-09-04 02:53 實際踩到）。這是測試的時間基準錯，
        # 不是 verify 的行為錯。
        cur.execute("SELECT review_by, last_verified, current_date FROM memories WHERE name='check-me'")
        rb, lv, db_today = cur.fetchone()
        assert rb > dt.date(2026, 9, 1) and lv == db_today


def test_edit_body_only_keeps_description(conn, home: Path):
    """純 body 編輯不可把 description 洗成空字串（CHECK 會擋，實測 2026-08-26 全數失敗）。"""
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="keep-desc", scope="global",
                 description="原始描述——不該被動到", body="\n舊正文。\n", kind="semantic")
    conn.commit()
    mutate.edit(conn, _cfg(), "keep-desc", description=None, body="\n新正文。\n", reason="只改正文")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT description, body FROM memories WHERE name='keep-desc'")
        desc, body = cur.fetchone()
    assert desc == "原始描述——不該被動到"
    assert "新正文" in body


def test_edit_governance_fields(conn, home: Path):
    """kind / pin / review_by 要能改；pin 沿用 write 的 importance 慣例。"""
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="gov", scope="global", description="治理欄位",
                 body="\nb\n", kind="semantic")
    conn.commit()

    mutate.edit(conn, _cfg(), "gov", description=None, body=None, reason="補分類",
                kind="environment", pin=True, review_by="2026-11-24")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT kind::text, pinned, review_by::text, importance FROM memories WHERE name='gov'")
        assert cur.fetchone() == ("environment", True, "2026-11-24", 4)

    # KEEP 哨兵：沒傳的欄位不可被動到；review_by 傳 None 才是清除
    mutate.edit(conn, _cfg(), "gov", description=None, body=None, reason="只降 pin", pin=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT kind::text, pinned, review_by::text, importance FROM memories WHERE name='gov'")
        assert cur.fetchone() == ("environment", False, "2026-11-24", 3)

    mutate.edit(conn, _cfg(), "gov", description=None, body=None, reason="清除覆核日", review_by=None)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT review_by FROM memories WHERE name='gov'")
        assert cur.fetchone()[0] is None


def test_write_and_edit_sync_wikilinks(conn, home: Path):
    """連結圖要隨寫入更新——只有 import 會建的話，orphan/dangling 稽核會對著過期的圖判斷。"""
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="target-mem", scope="global", description="被連的",
                 body="\nb\n", kind="semantic")
    mutate.write(conn, _cfg(), name="source-mem", scope="global", description="來源",
                 body="\n見 [[target-mem]]。\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("""SELECT t.name FROM memory_links l JOIN memories s ON s.id=l.source_id
                       LEFT JOIN memories t ON t.id=l.target_id
                       WHERE s.name='source-mem' AND l.kind='wikilink'""")
        assert cur.fetchall() == [("target-mem",)]

    # 移除連結 → 該列要消失（不是只增不減）
    mutate.edit(conn, _cfg(), "source-mem", description=None, body="\n不再引用任何東西。\n",
                reason="拿掉引用")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memory_links l JOIN memories s ON s.id=l.source_id "
                    "WHERE s.name='source-mem' AND l.kind='wikilink'")
        assert cur.fetchone()[0] == 0

    # 指向不存在的名字 → 留 dangling（target_id NULL），交給 audit 報，不是靜默丟掉
    mutate.edit(conn, _cfg(), "source-mem", description=None, body="\n見 [[not-a-memory]]。\n",
                reason="指向不存在")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("""SELECT l.target_name, l.target_id IS NULL FROM memory_links l
                       JOIN memories s ON s.id=l.source_id WHERE s.name='source-mem'""")
        assert cur.fetchall() == [("not-a-memory", True)]


def test_cli_edit_file_without_frontmatter_keeps_description(conn, home: Path, tmp_path: Path):
    """走 CLI 的純 body 編輯（--file 給無 frontmatter 的檔）。

    這是實際用法，也是原始缺陷的所在：cli 用 `args.description or desc`，而 _parse_input 對
    純 body 回傳 description=""——空字串不是 None，於是被當成「要寫入空值」，每次都撞
    memories_description_check。mutate.edit 那層測不到，要從 CLI 進去才會重現。
    """
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="cli-edit", scope="global",
                 description="CLI 描述——保持不變", body="\n舊。\n", kind="semantic")
    conn.commit()
    f = tmp_path / "body.md"
    f.write_text("\n改過的正文，沒有 frontmatter。\n", encoding="utf-8")

    assert cli.main(["edit", "cli-edit", "--file", str(f), "--reason", "只改正文"]) == 0

    with conn.cursor() as cur:
        cur.execute("SELECT description, body FROM memories WHERE name='cli-edit'")
        desc, body = cur.fetchone()
    assert desc == "CLI 描述——保持不變"
    assert "改過的正文" in body


def _set_embed_cfg(conn, model="test-model"):
    with conn.cursor() as cur:
        cur.execute("DELETE FROM embedding_config")
        cur.execute("INSERT INTO embedding_config(model,dim,tau) VALUES (%s,1024,0.35)", (model,))
    conn.commit()
    return model


def test_cli_meta_only_edit_with_non_tty_stdin_keeps_body(conn, home: Path, monkeypatch):
    """純治理型 edit（只給 --kind）在非 tty stdin 下不可清空正文。

    這是最容易踩的組合：hook / CI / 管線下 isatty() 為 False，_read_input 讀到空字串，
    _parse_input 回一個只有換行的 body。實測 2026-08-26 曾讓 44 bytes 的正文變成 1 byte，
    連 wikilink 列一起刪光，而且完全不報錯。
    """
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="target-mem", scope="global", description="被連的",
                 body="\nb\n", kind="semantic")
    mutate.write(conn, _cfg(), name="meta-edit", scope="global", description="治理型編輯",
                 body="\n正文要活著，含 [[target-mem]]。\n", kind="semantic")
    conn.commit()
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert sys.stdin.isatty() is False

    assert cli.main(["edit", "meta-edit", "--kind", "decision", "--reason", "只補分類"]) == 0

    with conn.cursor() as cur:
        cur.execute("SELECT kind::text, body FROM memories WHERE name='meta-edit'")
        kind, body = cur.fetchone()
        cur.execute("SELECT count(*) FROM memory_links l JOIN memories s ON s.id=l.source_id "
                    "WHERE s.name='meta-edit' AND l.kind='wikilink'")
        links = cur.fetchone()[0]
    assert kind == "decision"
    assert "正文要活著" in body
    assert links == 1


def test_cli_edit_refuses_inherited_nonempty_stdin(conn, home: Path, monkeypatch):
    """繼承到的非空 stdin 不可被當成新正文（2026-08-26 實際毀掉一則記憶）。

    炸掉的寫法是 `while read -r n k; do memory edit "$n" --kind "$k" --reason r; done <<< "$MAP"`：
    第一次呼叫把 heredoc 剩下的行整段吃成新正文，迴圈也因 stdin 被吸乾只跑一輪，
    卻印 ok=1。**audit 在定義上看不出來**——正文有內容、連結沒斷。所以只能在 CLI 層 fail-closed。
    """
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="loop-victim", scope="global", description="會被迴圈掃到的",
                 body="\n原本的正文，不可以被 stdin 蓋掉。\n", kind="semantic")
    conn.commit()
    leftover = "other-mem procedural\nthird-mem decision\n"
    monkeypatch.setattr(sys, "stdin", io.StringIO(leftover))
    assert sys.stdin.isatty() is False

    assert cli.main(["edit", "loop-victim", "--kind", "decision", "--reason", "只補分類"]) == 2

    with conn.cursor() as cur:
        cur.execute("SELECT kind::text, body FROM memories WHERE name='loop-victim'")
        kind, body = cur.fetchone()
    # 拒絕要是「整個不做」，不能只擋正文卻把 kind 改掉——那會留下半套狀態。
    assert kind == "semantic"
    assert "原本的正文" in body
    assert "other-mem" not in body


def test_cli_edit_stdin_flag_is_the_explicit_way(conn, home: Path, monkeypatch):
    """正控組：明講 --stdin 時 stdin 就是新正文，上一個測試擋的不是「stdin 永遠不能用」。

    沒有這一組，把 `_read_input` 改成永遠回空字串也會讓上面那個測試通過——
    那種修法會讓 `memory edit --stdin` 靜默失效（判準見記憶 verification-must-discriminate）。
    """
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="stdin-ok", scope="global", description="舊描述",
                 body="\n舊正文。\n", kind="semantic")
    conn.commit()
    monkeypatch.setattr(sys, "stdin", io.StringIO("新正文從 stdin 進來。\n"))

    assert cli.main(["edit", "stdin-ok", "--stdin", "--reason", "換正文"]) == 0

    with conn.cursor() as cur:
        cur.execute("SELECT body FROM memories WHERE name='stdin-ok'")
        assert "新正文從 stdin 進來" in cur.fetchone()[0]


def test_cli_edit_refuses_empty_stdin_flag(conn, home: Path, monkeypatch):
    """--stdin 卻讀到空的：與 --file 指到空檔同一個理由，不當成「請清空」。"""
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="stdin-empty", scope="global", description="有內容",
                 body="\n原本的正文。\n", kind="semantic")
    conn.commit()
    monkeypatch.setattr(sys, "stdin", io.StringIO("   \n"))

    assert cli.main(["edit", "stdin-empty", "--stdin", "--reason", "手滑"]) == 2
    with conn.cursor() as cur:
        cur.execute("SELECT body FROM memories WHERE name='stdin-empty'")
        assert "原本的正文" in cur.fetchone()[0]


def test_cli_edit_refuses_empty_file(conn, home: Path, tmp_path: Path, monkeypatch):
    """--file 指向空檔是用法錯（2），不可靜默把記憶清空。"""
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="not-empty", scope="global", description="有內容",
                 body="\n原本的正文。\n", kind="semantic")
    conn.commit()
    empty = tmp_path / "empty.md"
    empty.write_text("   \n", encoding="utf-8")
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))

    assert cli.main(["edit", "not-empty", "--file", str(empty), "--reason", "手滑"]) == 2
    with conn.cursor() as cur:
        cur.execute("SELECT body FROM memories WHERE name='not-empty'")
        assert "原本的正文" in cur.fetchone()[0]


def test_cli_edit_rejects_bad_review_by(conn, home: Path, monkeypatch):
    """--review-by 格式錯是用法錯（2），不是「無法判定正確性」（1）。"""
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="dated", scope="global", description="有日期",
                 body="\nb\n", kind="semantic")
    conn.commit()
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["edit", "dated", "--review-by", "2026-13-45", "--reason", "x"]) == 2
    assert cli.main(["edit", "dated", "--review-by", "2026-02-29", "--reason", "x"]) == 2
    assert cli.main(["edit", "dated", "--review-by", "2028-02-29", "--reason", "x"]) == 0


def test_forward_reference_is_backfilled_on_write(conn, home: Path):
    """先寫來源（引用尚未存在的目標）、後寫目標時，那一列要被接回來。

    不回填的話 audit 會永久報 dangling_ref 又把目標報成 orphan，兩個都清不掉，
    正好抵銷「寫入時同步連結圖」想達成的目的。
    """
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="src-first", scope="global", description="先寫的來源",
                 body="\n之後才會有 [[tgt-later]]。\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT target_id IS NULL FROM memory_links WHERE target_name='tgt-later'")
        assert cur.fetchone()[0] is True

    mutate.write(conn, _cfg(), name="tgt-later", scope="global", description="後寫的目標",
                 body="\nb\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT s.name, l.target_id = t.id FROM memory_links l "
                    "JOIN memories s ON s.id=l.source_id JOIN memories t ON t.name='tgt-later' "
                    "WHERE l.target_name='tgt-later' AND l.kind='wikilink'")
        assert cur.fetchall() == [("src-first", True)]


def test_forward_reference_backfill_respects_scope(conn, home: Path):
    """跨專案不可被回填——那是 trg_link_scope 明文禁止的方向，回填了會 raise。"""
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="a-mem", scope="project", description="A 專案的",
                 body="\n引用 [[b-only-mem]]。\n", kind="semantic",
                 project_slug="D--Projects-IntelliPark")
    conn.commit()
    mutate.write(conn, _cfg(), name="b-only-mem", scope="project", description="B 專案的",
                 body="\nb\n", kind="semantic", project_slug="D--Projects-pcpms-car-navigator")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT target_id IS NULL FROM memory_links WHERE target_name='b-only-mem'")
        assert cur.fetchone()[0] is True


def test_auto_embed_clears_stale_vector_on_failure(conn, home: Path, monkeypatch):
    """ollama 算不出來時要把舊向量清成 NULL。

    留著舊向量的話：DB 是新內容、向量是舊內容，而 embedding_model 仍等於現行模型，
    search 的檢查（只看 IS NULL 與 model 是否一致）看不出異常，會拿舊內容的語意召回它，
    且完全不警示——比「缺 embedding」更糟，因為後者至少會印 WARN。
    """
    from memory_pg import embed as embedmod
    model = _set_embed_cfg(conn)
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="vec-mem", scope="global", description="有向量的",
                 body="\n舊內容。\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET embedding=%s, embedding_model=%s, embedding_dim=1024, "
                    "embedding_src_hash='oldhash', embedded_at=now() WHERE name='vec-mem'",
                    (str([0.1] * 1024), model))
    conn.commit()

    monkeypatch.setattr(embedmod, "embed_texts", lambda *a, **k: [None])
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["edit", "vec-mem", "--description", "改過的描述", "--reason", "換內容"]) == 0

    with conn.cursor() as cur:
        cur.execute("SELECT embedding IS NULL, embedding_model, embedding_src_hash "
                    "FROM memories WHERE name='vec-mem'")
        assert cur.fetchone() == (True, None, None)


def test_auto_embed_skips_when_content_unchanged(conn, home: Path, monkeypatch):
    """內容沒變的治理型編輯不可再打一次 ollama（設計 A5 的重算判定）。"""
    from memory_pg import embed as embedmod
    model = _set_embed_cfg(conn)
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="stable-mem", scope="global", description="不變的",
                 body="\n內容。\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT name, description, body FROM memories WHERE name='stable-mem'")
        r = cur.fetchone()
        h = embedmod.src_hash(embedmod.build_embed_text(r[0], r[1], r[2], doc_prefix=""))
        cur.execute("UPDATE memories SET embedding=%s, embedding_model=%s, embedding_dim=1024, "
                    "embedding_src_hash=%s, embedded_at=now() WHERE name='stable-mem'",
                    (str([0.1] * 1024), model, h))
    conn.commit()

    calls = []
    monkeypatch.setattr(embedmod, "embed_texts", lambda *a, **k: calls.append(a) or [None])
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["edit", "stable-mem", "--pin", "--reason", "只切 pin"]) == 0
    assert calls == []
    with conn.cursor() as cur:
        cur.execute("SELECT pinned, embedding IS NOT NULL FROM memories WHERE name='stable-mem'")
        assert cur.fetchone() == (True, True)


def test_auto_embed_clears_vector_when_embed_raises(conn, home: Path, monkeypatch):
    """embed_texts **拋例外**（不是回 None）時也必須清掉舊向量。

    embed_texts 只吞 httpx.HTTPError / RetrievalUnavailable，ollama 回非 JSON、結構不符、
    空陣列取 [0] 這幾種會往外拋。若讓它冒到 _auto_embed 外層，只會印一行 WARN，而內容已改、
    舊向量還在——就是「過期但看起來健康」那個狀態，search 完全察覺不到。
    """
    from memory_pg import embed as embedmod
    model = _set_embed_cfg(conn)
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="raise-mem", scope="global", description="會拋例外的",
                 body="\n舊內容。\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET embedding=%s, embedding_model=%s, embedding_dim=1024, "
                    "embedding_src_hash='oldhash', embedded_at=now() WHERE name='raise-mem'",
                    (str([0.1] * 1024), model))
    conn.commit()

    def _boom(*a, **k):
        raise ValueError("ollama 回了非 JSON")

    monkeypatch.setattr(embedmod, "embed_texts", _boom)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["edit", "raise-mem", "--description", "改過的", "--reason", "換內容"]) == 0

    with conn.cursor() as cur:
        cur.execute("SELECT embedding IS NULL, embedding_model FROM memories WHERE name='raise-mem'")
        assert cur.fetchone() == (True, None)


def test_auto_embed_rejects_dim_mismatch(conn, home: Path, monkeypatch):
    """回傳維度與設定不符時不可寫入。

    embedding 欄位刻意不帶維度（換模型不必 ALTER），所以混維度寫得進去；代價是 hybrid search
    一跑 `<=>` 就**整批**失敗，而不是只有那一列壞掉。同名模型改版是最可能的觸發路徑。
    """
    from memory_pg import embed as embedmod
    model = _set_embed_cfg(conn)          # dim=1024
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="dim-mem", scope="global", description="維度不符的",
                 body="\n內容。\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET embedding=%s, embedding_model=%s, embedding_dim=1024, "
                    "embedding_src_hash='oldhash', embedded_at=now() WHERE name='dim-mem'",
                    (str([0.1] * 1024), model))
    conn.commit()

    monkeypatch.setattr(embedmod, "embed_texts", lambda *a, **k: [[0.2] * 768])   # 768 != 1024
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["edit", "dim-mem", "--description", "改過的", "--reason", "換內容"]) == 0

    with conn.cursor() as cur:
        cur.execute("SELECT embedding IS NULL, embedding_dim FROM memories WHERE name='dim-mem'")
        assert cur.fetchone() == (True, None)


def test_set_model_does_not_switch_on_dim_mismatch(conn, home: Path, monkeypatch):
    """--set-model 遇到維度不符不可切換 embedding_config。

    維度不符與「算不出來」是同一類失敗。若只在寫入迴圈裡才判，設定已經換成新模型、而那些列
    仍是舊模型的向量 → search 判模型不一致就**整體** fail-closed，比缺 embedding 更糟。
    原子性契約（非 --force 絕不切換）必須把維度不符也算進去。
    """
    from memory_pg import embed as embedmod
    _set_embed_cfg(conn, "old-model")
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="switch-mem", scope="global", description="要換模型的",
                 body="\n內容。\n", kind="semantic")
    conn.commit()

    monkeypatch.setattr(embedmod, "embed_texts", lambda *a, **k: [[0.2] * 768])   # 宣告 1024，回 768
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["embed", "--set-model", "new-model", "--dim", "1024"]) == 1

    with conn.cursor() as cur:
        cur.execute("SELECT model FROM embedding_config")
        assert cur.fetchone()[0] == "old-model"       # 設定沒被換掉


def test_auto_embed_skips_write_when_content_changed_meanwhile(conn, home: Path, monkeypatch):
    """讀內容 → 呼叫 ollama → 寫回向量分屬不同交易，期間內容又被改過就不可寫入。

    否則較慢的舊請求最後寫入，會讓新正文配上舊內容的向量；search 不比對 src_hash，
    完全察覺不到。這裡用「embed_texts 執行期間直接改 DB」把競態變成可重現的。
    """
    from memory_pg import embed as embedmod
    model = _set_embed_cfg(conn)
    _seed_projects(conn, home)
    mutate.write(conn, _cfg(), name="raced-mem", scope="global", description="會被插隊的",
                 body="\n第一版。\n", kind="semantic")
    conn.commit()

    import psycopg
    from memory_pg import config as cfgmod

    def _slow_embed(*a, **k):
        # 模擬另一個 edit 在 ollama 回來之前先落地（獨立連線，才是真的併行語意）
        other = psycopg.connect(cfgmod.load(use_test_db=True).dsn, connect_timeout=3)
        try:
            with other.cursor() as c:
                c.execute("UPDATE memories SET body=%s WHERE name='raced-mem'", ("\n第二版（別人改的）。\n",))
            other.commit()
        finally:
            other.close()
        return [[0.3] * 1024]

    monkeypatch.setattr(embedmod, "embed_texts", _slow_embed)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["edit", "raced-mem", "--description", "本輪的描述", "--reason", "慢請求"]) == 0

    with conn.cursor() as cur:
        cur.execute("SELECT body, embedding IS NULL FROM memories WHERE name='raced-mem'")
        body, no_vec = cur.fetchone()
    assert "第二版" in body            # 別人的改動還在
    assert no_vec is True              # 本輪算出的向量對不上現況，沒有寫進去


# ---------- Task 2：bank presence + 四 scope 寫入 ----------

def test_write_and_learn_route_four_scopes(conn, home: Path):
    """machine / work 不要求 --project、home_project_id 為 NULL、落到各自 bank。"""
    _seed_projects(conn, home)
    seed_banks(home)
    for scope in ("global", "machine", "work"):
        mutate.write(conn, _cfg(), name=f"r-{scope}", scope=scope,
                     description=f"{scope} 的", body="\nb\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT name, scope::text, home_project_id, file_path FROM memories "
                    "WHERE name LIKE 'r-%' ORDER BY name")
        rows = {r[0]: r for r in cur.fetchall()}
    assert rows["r-global"][1:3] == ("global", None)
    assert rows["r-machine"][1:3] == ("machine", None)
    assert rows["r-work"][1:3] == ("work", None)
    assert str(home / "memory-machine") in rows["r-machine"][3]
    assert str(home / "memory-work") in rows["r-work"][3]


@pytest.mark.parametrize("scope", ["machine", "work"])
def test_write_refuses_when_bank_not_installed(conn, home: Path, tmp_path, monkeypatch, scope):
    """bank not_installed 時必須 exit 2 且 DB 不得新增任何列。

    否則會出現「DB 有記憶、repo 沒檔案、命令回成功」——export 對 not_installed 是跳過且
    exit 0，不會有任何訊號。
    """
    from memory_pg import cli
    shutil.rmtree(home / f"memory-{scope}", ignore_errors=True)
    f = tmp_path / "b.md"
    f.write_text("\n內容。\n", encoding="utf-8")
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    name = f"nb-{scope}"
    assert cli.main(["write", "--name", name, "--scope", scope,
                     "--description", "描述", "--file", str(f)]) == 2
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name=%s", (name,))
        assert cur.fetchone()[0] == 0


def test_write_refuses_when_bank_unavailable(conn, home: Path, tmp_path, monkeypatch):
    """bank 路徑存在但不是目錄 → unavailable → exit 1，零寫入。"""
    from memory_pg import cli
    shutil.rmtree(home / "memory-work", ignore_errors=True)
    (home / "memory-work").write_text("我是檔案不是目錄", encoding="utf-8")
    f = tmp_path / "b.md"
    f.write_text("\n內容。\n", encoding="utf-8")
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["write", "--name", "nu", "--scope", "work",
                     "--description", "描述", "--file", str(f)]) == 1
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='nu'")
        assert cur.fetchone()[0] == 0


def test_dup_candidates_scoped_exactly(conn, home: Path):
    """重複偵測只比同 scope：machine 與 global 是不同的庫，描述相同不算重複。"""
    _seed_projects(conn, home)
    desc = "完全一樣的描述——用來觸發 Jaccard"
    mutate.write(conn, _cfg(), name="dup-global", scope="global", description=desc, body="\nb\n")
    conn.commit()
    assert mutate.dup_candidates(conn, "machine", None, desc) == []
    assert [n for n, _ in mutate.dup_candidates(conn, "global", None, desc)] == ["dup-global"]


def test_unknown_scope_rejected(conn, home: Path):
    _seed_projects(conn, home)
    with pytest.raises(Exception, match="沒有單一 bank 的 scope|未知的 scope"):
        mutate.write(conn, _cfg(), name="bad", scope="nonsense", description="x", body="\nb\n")


# ---------- Task 3：resolver 三分支 ----------

def test_resolver_forbidden_is_error_not_dangling(conn, home: Path):
    """來源側：目標存在但方向禁止 → 整筆 rollback，不可降級成 dangling。

    若 resolver 只在允許範圍內搜尋，「已知但禁止」會被當成「未知」寫成 target_id=NULL，
    trigger 對 NULL 直接放行，於是命令成功、audit 只報 dangling——與「禁止」的語義不符。
    """
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mach-only", scope="machine", description="本機的",
                 body="\nb\n", kind="semantic")
    conn.commit()
    with pytest.raises(mutate.MutateError, match="cross_repo_link"):
        mutate.write(conn, _cfg(), name="g-bad", scope="global", description="全域的",
                     body="\n引用 [[mach-only]]。\n", kind="semantic")
    conn.rollback()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='g-bad'")
        assert cur.fetchone()[0] == 0


def test_resolver_unknown_stays_dangling(conn, home: Path):
    """目標不存在仍是 dangling，交給 audit 報——與「禁止」是兩件事。"""
    mutate.write(conn, _cfg(), name="g-unknown", scope="global", description="全域的",
                 body="\n引用 [[nobody-here]]。\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT target_id IS NULL FROM memory_links WHERE target_name='nobody-here'")
        assert cur.fetchone()[0] is True


def test_backfill_forbidden_stays_dangling_without_blocking_creation(conn, home: Path):
    """目標側：建立目標時，別人那條禁止方向的 dangling 不可阻擋本次寫入。

    與來源側刻意不同——拋錯會讓「B 建不了 foo，只因為 A 有一條過期的 [[foo]]」，
    那是與本次寫入無關的附帶損害。資訊由 audit 的 forbidden_ref 承接。
    """
    seed_banks(home)
    mutate.write(conn, _cfg(), name="g-waiting", scope="global", description="等目標的",
                 body="\n引用 [[later]]。\n", kind="semantic")
    conn.commit()
    mutate.write(conn, _cfg(), name="later", scope="machine", description="本機的",
                 body="\nb\n", kind="semantic")          # 不得被擋下
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='later'")
        assert cur.fetchone()[0] == 1
        cur.execute("SELECT target_id IS NULL FROM memory_links WHERE target_name='later'")
        assert cur.fetchone()[0] is True                 # 那條仍是 dangling


def test_backfill_allowed_direction_links_up(conn, home: Path):
    """project 的 dangling 指向後來建立的 work 目標 → 正確 backfill 成非 NULL。"""
    _seed_projects(conn, home)
    seed_banks(home)
    mutate.write(conn, _cfg(), name="p-waiting", scope="project", description="專案的",
                 body="\n引用 [[w-later]]。\n", kind="semantic",
                 project_slug="D--Projects-IntelliPark")
    conn.commit()
    mutate.write(conn, _cfg(), name="w-later", scope="work", description="工作的",
                 body="\nb\n", kind="semantic")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT target_id IS NOT NULL FROM memory_links WHERE target_name='w-later'")
        assert cur.fetchone()[0] is True
