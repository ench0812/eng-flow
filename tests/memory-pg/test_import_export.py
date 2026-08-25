from __future__ import annotations

from pathlib import Path

import pytest

from conftest import write_memory  # noqa: E402

from memory_pg import config, exporter, importer  # noqa: E402


def _cfg():
    return config.load(use_test_db=True)


def test_import_then_verify_is_lossless(conn, home: Path):
    g = home / "memory"
    p1 = home / "projects" / "D--Projects-X" / "memory"
    write_memory(g, "g-one", "全域一", pin="true", review_by="2026-12-31", node_type="memory",
                 modified="2026-08-24T03:20:00.000Z")
    write_memory(p1, "a-one", "專案 A 一", body="\n連到 [[g-one]] 與 [[a-two]]。\n\n第二段。\n", type="project")
    write_memory(p1, "a-two", "專案 A 二", body="\n[[nope]] dangling。\n")
    # CRLF 檔也要原樣回寫
    crlf = write_memory(p1, "a-crlf", "CRLF 檔")
    crlf.write_bytes(crlf.read_bytes().replace(b"\n", b"\r\n"))

    cfg = _cfg()
    rep = importer.run(conn, cfg, dry_run=False)
    conn.commit()
    assert rep.memories == 4 and rep.projects == 1

    with conn.cursor() as cur:
        cur.execute("SELECT name, scope::text, pinned, review_by::text, para_count FROM memories ORDER BY name")
        rows = cur.fetchall()
    assert ("g-one", "global", True, "2026-12-31", 1) in rows
    assert ("a-one", "project", False, None, 2) in rows
    with conn.cursor() as cur:
        cur.execute("SELECT target_name, target_id IS NOT NULL FROM memory_links WHERE kind='wikilink' ORDER BY target_name")
        links = cur.fetchall()
    assert links == [("a-two", True), ("g-one", True), ("nope", False)]

    vrep = exporter.run(conn, cfg, verify_dir=home / "cache" / "verify")
    statuses = {d.path.name: d.status for d in vrep.diffs if d.path.name != "MEMORY.md"}
    assert statuses == {"g-one.md": "same", "a-one.md": "same", "a-two.md": "same", "a-crlf.md": "same"}
    assert not vrep.memory_mismatches


def test_import_persists_across_connections(conn, home: Path, test_dsn: str):
    """回歸：寫入必須是頂層交易並 commit。同一連線內的驗證看得到、換連線就消失，正是實際踩過的坑。"""
    import psycopg

    write_memory(home / "memory", "persist-me", "要留下來")
    cfg = _cfg()
    # 先做一次讀取，製造「隱式交易已開啟」的前置狀態（模擬 CLI 的 assert_schema）
    with conn.cursor() as cur:
        cur.execute("SELECT 1")
    importer.run(conn, cfg, dry_run=False)
    conn.close()                       # 刻意不 commit
    with psycopg.connect(test_dsn) as c2, c2.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='persist-me'")
        assert cur.fetchone()[0] == 1


def test_import_aborts_on_malformed(conn, home: Path):
    write_memory(home / "memory", "ok-one", "好的")
    (home / "memory" / "bad-one.md").write_text("---\nname: bad-one\ndescription: d\npin: true\n---\n", encoding="utf-8")
    with pytest.raises(importer.ImportAborted) as e:
        importer.run(conn, _cfg(), dry_run=False)
    assert "misplaced_key:pin" in str(e.value)
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories")
        assert cur.fetchone()[0] == 0     # 零寫入


def test_duplicate_name_across_banks_aborts(conn, home: Path):
    # id 全域唯一：兩個 project bank 各有同名檔 → 碰撞，fail-closed 拒絕、零寫入
    write_memory(home / "projects" / "D--Projects-A" / "memory", "dup", "A 的 dup")
    write_memory(home / "projects" / "D--Projects-B" / "memory", "dup", "B 的 dup")
    with pytest.raises(importer.ImportAborted) as e:
        importer.run(conn, _cfg(), dry_run=False)
    assert "duplicate_name dup" in str(e.value)
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories")
        assert cur.fetchone()[0] == 0


def test_import_is_full_sync_deletes_absent(conn, home: Path):
    g = home / "memory"
    f_keep = write_memory(g, "keep", "留著")
    f_gone = write_memory(g, "gone", "會被刪")
    cfg = _cfg()
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories")
        assert cur.fetchone()[0] == 2
    # 刪掉一個檔案再匯入 → DB 內對應列必須消失（否則 export 會把它寫回 bank）
    f_gone.unlink()
    rep = importer.run(conn, cfg, dry_run=False)
    conn.commit()
    assert rep.deleted == 1
    with conn.cursor() as cur:
        cur.execute("SELECT name FROM memories")
        assert [r[0] for r in cur.fetchall()] == ["keep"]
    assert f_keep.exists()


def test_dry_run_reports_real_stats(conn, home: Path):
    g = home / "memory"
    write_memory(g, "d1", "一")
    write_memory(g, "d2", "二", body="\n[[d1]]\n")
    rep = importer.run(conn, _cfg(), dry_run=True)
    assert rep.dry_run and rep.memories == 2 and rep.links == 1 and rep.projects >= 0
    with conn.cursor() as cur:      # rollback：DB 仍空
        cur.execute("SELECT count(*) FROM memories")
        assert cur.fetchone()[0] == 0


def test_import_aborts_on_hidden_file(conn, home: Path):
    write_memory(home / "memory", "ok-one", "好的")
    (home / "memory" / ".sneaky.md").write_text("x")
    with pytest.raises(importer.ImportAborted) as e:
        importer.run(conn, _cfg(), dry_run=False)
    assert "hidden_file" in str(e.value)


def test_supersede_roundtrip_and_mismatch(conn, home: Path):
    g = home / "memory"
    write_memory(g, "old-fact", "舊事實", superseded_by="new-fact")
    write_memory(g, "new-fact", "新事實", supersedes="[old-fact]")
    cfg = _cfg()
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT name, status::text FROM memories ORDER BY name")
        assert cur.fetchall() == [("new-fact", "active"), ("old-fact", "superseded")]
    vrep = exporter.run(conn, cfg, verify_dir=home / "cache" / "verify")
    assert not vrep.memory_mismatches
    # 索引：已取代者不進 TOPICS
    idx = (home / "cache" / "verify" / "memory" / "MEMORY.md").read_text(encoding="utf-8")
    assert "old-fact.md" not in idx and "new-fact.md" in idx

    # 單邊宣告 → relation_mismatch → abort
    write_memory(g, "lonely", "只寫了 superseded_by", superseded_by="new-fact")
    with pytest.raises(importer.ImportAborted) as e:
        importer.run(conn, cfg, dry_run=False)
    assert "relation_mismatch missing_reverse supersedes on new-fact" in str(e.value)


def test_cross_project_wikilink_is_dangling_not_resolved(conn, home: Path):
    pa = home / "projects" / "D--Projects-A" / "memory"
    pb = home / "projects" / "D--Projects-B" / "memory"
    write_memory(pa, "a-mem", "A", body="\n[[b-mem]]\n")
    write_memory(pb, "b-mem", "B")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT target_id IS NULL FROM memory_links WHERE target_name='b-mem'")
        assert cur.fetchone()[0] is True


def test_index_render_pinned_and_tags(conn, home: Path):
    g = home / "memory"
    p1 = home / "projects" / "D--Projects-X" / "memory"
    write_memory(g, "g-pin", "全域 pin", pin="true")
    write_memory(p1, "x-pin", "X pin", pin="true")
    write_memory(p1, "x-plain", "X 普通——後半")
    cfg = _cfg()
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    # 把 g-pin 標到專案 X → 應只出現在 X 的索引、不在全域索引
    with conn.cursor() as cur:
        cur.execute("INSERT INTO memory_projects SELECT m.id, p.id FROM memories m, projects p WHERE m.name='g-pin' AND p.slug='D--Projects-X'")
    conn.commit()
    exporter.run(conn, cfg, verify_dir=home / "cache" / "verify")
    gidx = (home / "cache" / "verify" / "memory" / "MEMORY.md").read_text(encoding="utf-8")
    xidx = (home / "cache" / "verify" / "projects" / "D--Projects-X" / "memory" / "MEMORY.md").read_text(encoding="utf-8")
    assert "PINNED:ITEM g-pin" not in gidx and "PINNED:ITEM g-pin" in xidx
    assert "PINNED:ITEM x-pin" in xidx
    assert "- [X 普通](x-plain.md) — 後半" in xidx
    assert xidx.index("PINNED:ITEM g-pin") < xidx.index("PINNED:ITEM x-pin")   # name 排序


def test_export_refuses_unmanaged_file(conn, home: Path):
    g = home / "memory"
    write_memory(g, "known", "已知")
    cfg = _cfg()
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    (g / "stranger.md").write_text("---\nname: stranger\ndescription: 沒 import 過\n---\n", encoding="utf-8")
    with pytest.raises(exporter.ExportAborted):
        exporter.run(conn, cfg, verify_dir=None)
    assert (g / "stranger.md").exists()          # 沒被刪
