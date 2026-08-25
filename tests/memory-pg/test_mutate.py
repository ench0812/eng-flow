from __future__ import annotations

from pathlib import Path

import pytest

from conftest import write_memory  # noqa: E402

from memory_pg import config, exporter, importer, mutate  # noqa: E402


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
        cur.execute("SELECT review_by, last_verified FROM memories WHERE name='check-me'")
        rb, lv = cur.fetchone()
        assert rb > dt.date(2026, 9, 1) and lv == dt.date.today()
