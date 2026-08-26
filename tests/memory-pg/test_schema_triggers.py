"""schema 不變量（觸發器 / CHECK）的回歸測試。

這些規則的價值在「靠結構保證、不靠事後稽核」，所以每一條都要有測試釘住：
取代關係的環偵測、單一取代者、同 bank、只能取代 active、刪連結還原；
連結 scope 規則；連結不可變（但 FK 的 ON DELETE SET NULL 要放行）；active ⇔ valid_until NULL。
"""

from __future__ import annotations

import psycopg
import pytest

from pathlib import Path


def _seed(conn):
    with conn.cursor() as cur:
        cur.execute("INSERT INTO projects(slug, root_path, bank_path) VALUES ('P1','D:\\p1','C:\\b1'),('P2','D:\\p2','C:\\b2') RETURNING id")
        p1, p2 = [r[0] for r in cur.fetchall()]
        cur.execute(
            """INSERT INTO memories(name, description, file_path, scope, home_project_id) VALUES
               ('g1','g','C:\\g\\g1.md','global',NULL),
               ('a1','a','C:\\b1\\a1.md','project',%s),
               ('a2','a','C:\\b1\\a2.md','project',%s),
               ('a3','a','C:\\b1\\a3.md','project',%s),
               ('b1','b','C:\\b2\\b1.md','project',%s)""",
            (p1, p1, p1, p2),
        )
    conn.commit()


def _link(conn, src: str, dst: str, kind: str, *, resolve: bool = True):
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO memory_links(source_id, target_name, target_id, kind)
               SELECT s.id, %s, CASE WHEN %s THEN t.id END, %s
               FROM memories s LEFT JOIN memories t ON t.name = %s WHERE s.name = %s""",
            (dst, resolve, kind, dst, src),
        )
    conn.commit()


def _status(conn, name: str):
    with conn.cursor() as cur:
        cur.execute("SELECT status::text, valid_until IS NULL FROM memories WHERE name=%s", (name,))
        return cur.fetchone()


def _expect_error(conn, needle: str, fn):
    with pytest.raises(psycopg.Error) as e:
        fn()
    conn.rollback()
    assert needle in str(e.value), str(e.value)


def test_link_scope_rules(conn):
    _seed(conn)
    _link(conn, "a1", "g1", "wikilink")                                   # project → global OK
    _link(conn, "a1", "a2", "wikilink")                                   # 同 project OK
    _link(conn, "a1", "nope", "wikilink", resolve=False)                  # dangling OK
    _expect_error(conn, "cross_project_link", lambda: _link(conn, "a1", "b1", "wikilink"))
    # 0002 起 global → project 改報 cross_repo_link：它不是「跨專案」的衛生問題，而是
    # 跨 repo——通用 repo 不能相依工作 repo。cross_project_link 保留給 project → 別的 project。
    _expect_error(conn, "cross_repo_link", lambda: _link(conn, "g1", "a1", "wikilink"))


def test_supersede_lifecycle(conn):
    _seed(conn)
    _link(conn, "a2", "a1", "supersedes")
    assert _status(conn, "a1") == ("superseded", False)
    _expect_error(conn, "supersede_cycle", lambda: _link(conn, "a1", "a2", "supersedes"))
    _expect_error(conn, "memory_links_one_superseder", lambda: _link(conn, "a3", "a1", "supersedes"))
    _expect_error(conn, "cross_bank_supersede", lambda: _link(conn, "a3", "g1", "supersedes"))
    with conn.cursor() as cur:
        cur.execute("DELETE FROM memory_links WHERE kind='supersedes'")
    conn.commit()
    assert _status(conn, "a1") == ("active", True)


def test_supersede_refuses_non_active_target(conn):
    _seed(conn)
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET status='deprecated', valid_until=now() WHERE name='a3'")
    conn.commit()
    _expect_error(conn, "supersede_target_not_active", lambda: _link(conn, "a2", "a3", "supersedes"))
    assert _status(conn, "a3") == ("deprecated", False)      # 沒被改動


def test_active_iff_no_valid_until(conn):
    _seed(conn)

    def bad():
        with conn.cursor() as cur:
            cur.execute("UPDATE memories SET valid_until=now() WHERE name='a1'")
        conn.commit()

    _expect_error(conn, "active_iff_no_until", bad)


def test_links_immutable_but_fk_set_null_allowed(conn):
    _seed(conn)
    _link(conn, "a1", "g1", "wikilink")

    def upd():
        with conn.cursor() as cur:
            cur.execute("UPDATE memory_links SET kind='supersedes'")
        conn.commit()

    _expect_error(conn, "links_immutable", upd)
    # 刪掉被指到的記憶：FK ON DELETE SET NULL 走的是 UPDATE，必須放行 → 連結變 dangling
    with conn.cursor() as cur:
        cur.execute("DELETE FROM memories WHERE name='g1'")
        cur.execute("SELECT target_name, target_id IS NULL FROM memory_links")
        assert cur.fetchall() == [("g1", True)]
    conn.commit()


def test_deleting_superseder_restores_target(conn):
    _seed(conn)
    _link(conn, "a2", "a1", "supersedes")
    with conn.cursor() as cur:
        cur.execute("DELETE FROM memories WHERE name='a2'")   # source 刪除 → 連結 CASCADE → 觸發還原
    conn.commit()
    assert _status(conn, "a1") == ("active", True)


# ---------- 0002：四 scope 與連結判定 ----------

LINK_MATRIX = [
    ("project", True,  "global",  None,  True),
    ("machine", None,  "global",  None,  True),
    ("work",    None,  "global",  None,  True),
    ("global",  None,  "machine", None,  False),
    ("project", True,  "machine", None,  False),
    ("machine", None,  "machine", None,  True),
    ("project", True,  "work",    None,  True),
    ("work",    None,  "work",    None,  True),
    ("machine", None,  "work",    None,  False),
    ("work",    None,  "project", True,  True),
    ("project", True,  "project", True,  True),
    ("project", True,  "project", False, False),
    ("global",  None,  "project", True,  False),
]


@pytest.mark.parametrize("s_scope,s_same,t_scope,t_same,allowed", LINK_MATRIX)
def test_link_allowed_matrix(conn, s_scope, s_same, t_scope, t_same, allowed):
    """判準：持有來源 repo 的人是否必然也持有目標 repo。"""
    p1 = "11111111-1111-1111-1111-111111111111"
    p2 = "22222222-2222-2222-2222-222222222222"
    s_home = p1 if s_scope == "project" else None
    t_home = (p1 if t_same else p2) if t_scope == "project" else None
    with conn.cursor() as cur:
        cur.execute("SELECT link_allowed(%s::memory_scope, %s::uuid, %s::memory_scope, "
                    "%s::uuid, 'wikilink')", (s_scope, s_home, t_scope, t_home))
        assert cur.fetchone()[0] is allowed


def test_scope_enum_after_rename(conn):
    """最終 schema 的 smoke test。"""
    with conn.cursor() as cur:
        cur.execute("SELECT enumlabel FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid "
                    "WHERE t.typname='memory_scope' ORDER BY enumsortorder")
        assert [r[0] for r in cur.fetchall()] == ["global", "machine", "work", "project"]


def test_migration_renames_existing_rows(test_dsn):
    """證明 migration 對【既有列】的實際語義，不只看 enum label。

    enum rename 會同步改變使用舊 label 的列。現況實測 user/workspace 為 0 列，所以要在
    隔離的 schema 裡塞四種舊 scope 的 fixture 才驗得到——不能靠正式庫「碰巧沒有」來證明。
    """
    from memory_pg import migrate

    with psycopg.connect(test_dsn, connect_timeout=3) as c:
        with c.cursor() as cur:
            cur.execute("DROP SCHEMA IF EXISTS mig_probe CASCADE")
            cur.execute("CREATE SCHEMA mig_probe")
            cur.execute("SET search_path TO mig_probe, public")
        try:
            migrate.apply_one(c, "0001_init.sql")
            with c.cursor() as cur:
                cur.execute("INSERT INTO projects(slug, root_path, bank_path) "
                            "VALUES ('s','/r','/bk') RETURNING id")
                pid = cur.fetchone()[0]
                cur.execute("INSERT INTO memories(name, description, body, file_path, scope) "
                            "VALUES ('a','d','b','/a','global'), ('b','d','b','/b','user'), "
                            "('c','d','b','/c','workspace')")
                cur.execute("INSERT INTO memories(name, description, body, file_path, scope, "
                            "home_project_id) VALUES ('d','d','b','/d','project',%s)", (pid,))
            migrate.apply_one(c, "0002_scope_machine_work.sql")
            with c.cursor() as cur:
                cur.execute("SELECT name, scope::text FROM memories ORDER BY name")
                assert dict(cur.fetchall()) == {"a": "global", "b": "machine",
                                                "c": "work", "d": "project"}
        finally:
            c.rollback()
            with c.cursor() as cur:
                cur.execute("DROP SCHEMA IF EXISTS mig_probe CASCADE")
            c.commit()


def test_tag_scope_forbidden(conn, home: Path):
    """machine / project 不得持有 tag。"""
    from memory_pg import config, importer

    cfg = config.load(use_test_db=True)
    (home / "projects" / "D--Projects-A" / "memory").mkdir(parents=True)
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    # 直接用 SQL 造 machine 列：這一則測的是 DB 不變量，不該相依「寫入面對 machine 的支援」
    with conn.cursor() as cur:
        cur.execute("INSERT INTO memories(name, description, body, file_path, scope) "
                    "VALUES ('m1','本機','\nb\n','/m1','machine')")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM projects LIMIT 1")
        pid = cur.fetchone()[0]
        cur.execute("SELECT id FROM memories WHERE name='m1'")
        mid = cur.fetchone()[0]
        with pytest.raises(psycopg.errors.RaiseException, match="tag_scope_forbidden"):
            cur.execute("INSERT INTO memory_projects(memory_id, project_id) VALUES (%s,%s)",
                        (mid, pid))
    conn.rollback()


def test_scope_update_revalidates_links(conn, home: Path):
    """直接 UPDATE scope 留下非法 link 必須 rollback；同交易內先清理再改則可 commit。"""
    from memory_pg import config, mutate

    cfg = config.load(use_test_db=True)
    mutate.write(conn, cfg, name="g-target", scope="global", description="目標", body="\nb\n")
    mutate.write(conn, cfg, name="g-src", scope="global", description="來源",
                 body="\n見 [[g-target]]。\n")
    conn.commit()
    with pytest.raises(psycopg.errors.RaiseException, match="cross_repo_link_after_move"):
        with conn.cursor() as cur:
            cur.execute("UPDATE memories SET scope='machine' WHERE name='g-target'")
        conn.commit()
    conn.rollback()
    with conn.cursor() as cur:
        cur.execute("DELETE FROM memory_links l USING memories t "
                    "WHERE l.target_id=t.id AND t.name='g-target'")
        cur.execute("UPDATE memories SET scope='machine' WHERE name='g-target'")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT scope::text FROM memories WHERE name='g-target'")
        assert cur.fetchone()[0] == "machine"


def test_deferred_trigger_uses_commit_time_state(conn, home: Path):
    """同一交易內多次改 scope，deferred trigger 必須驗【交易末的最終狀態】。

    事件裡的 NEW.scope 是該次 UPDATE 當下的值，不會自動變成 commit 時的值。若直接用 NEW，
    較早那次事件會拿中間狀態去判（machine 不得持有 tag），把最終合法的 work 誤擋下來。
    """
    from memory_pg import config, importer, mutate

    cfg = config.load(use_test_db=True)
    (home / "projects" / "D--Projects-A" / "memory").mkdir(parents=True)
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    mutate.write(conn, cfg, name="multi", scope="global", description="會被改兩次",
                 body="\nb\n", tags=["D--Projects-A"])
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("UPDATE memories SET scope='machine' WHERE name='multi'")
        cur.execute("UPDATE memories SET scope='work' WHERE name='multi'")
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT scope::text FROM memories WHERE name='multi'")
        assert cur.fetchone()[0] == "work"
