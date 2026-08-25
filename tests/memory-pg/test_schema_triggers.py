"""schema 不變量（觸發器 / CHECK）的回歸測試。

這些規則的價值在「靠結構保證、不靠事後稽核」，所以每一條都要有測試釘住：
取代關係的環偵測、單一取代者、同 bank、只能取代 active、刪連結還原；
連結 scope 規則；連結不可變（但 FK 的 ON DELETE SET NULL 要放行）；active ⇔ valid_until NULL。
"""

from __future__ import annotations

import psycopg
import pytest


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
    _expect_error(conn, "cross_project_link", lambda: _link(conn, "g1", "a1", "wikilink"))


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
