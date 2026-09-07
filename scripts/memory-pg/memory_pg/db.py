"""DB 連線與前置檢查。所有連線都走這裡，fail-closed 的判定集中一處。"""

from __future__ import annotations

from contextlib import contextmanager
from importlib import resources

import psycopg

from .config import Config
from .errors import BackendTimeout, BackendUnavailable, SchemaMismatch

CONNECT_TIMEOUT_S = 3
STATEMENT_TIMEOUT_MS = 5000


def connect(cfg: Config, *, autocommit: bool = False) -> psycopg.Connection:
    try:
        conn = psycopg.connect(
            cfg.dsn,
            connect_timeout=CONNECT_TIMEOUT_S,
            options=f"-c statement_timeout={STATEMENT_TIMEOUT_MS}",
            autocommit=autocommit,
        )
    except psycopg.OperationalError as e:
        msg = str(e).strip().splitlines()[0] if str(e).strip() else repr(e)
        if "timeout" in msg.lower():
            raise BackendTimeout(f"連線 PostgreSQL 逾時（{CONNECT_TIMEOUT_S}s）: {msg}") from e
        raise BackendUnavailable(
            f"連不上 PostgreSQL: {msg}。啟動：cd ~/.claude/memory-pg && docker compose up -d"
        ) from e
    return conn


@contextmanager
def top_level_transaction(conn: psycopg.Connection):
    """保證區塊是【頂層】交易並在成功時 commit。

    psycopg3 在非 autocommit 連線上，任何先前的 SELECT 都會隱式開啟交易；此時 conn.transaction()
    只建 SAVEPOINT，區塊結束不 commit，連線關閉整批 rollback——而同一連線後續的讀取仍看得到資料，
    所以「印了成功、verify 也過、資料卻沒有」（2026-08-25 migrate 與 import 各踩一次）。
    所有寫入路徑一律走這裡。
    """
    conn.commit()            # 收掉隱式交易
    with conn.transaction():
        yield
    conn.commit()            # transaction() 退出已 commit；這行讓意圖顯性，且對 autocommit 連線無害


def expected_schema_version() -> int:
    """migrations/ 目錄裡最大的版本號＝程式期望的 schema 版本。"""
    files = resources.files("memory_pg").joinpath("migrations")
    versions = [int(p.name.split("_", 1)[0]) for p in files.iterdir() if p.name.endswith(".sql")]
    return max(versions) if versions else 0


def current_schema_version(conn: psycopg.Connection) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass('public.schema_migrations') IS NOT NULL")
        if not cur.fetchone()[0]:
            return 0
        cur.execute("SELECT coalesce(max(version), 0) FROM schema_migrations")
        return int(cur.fetchone()[0])


def expected_schema_versions() -> set[int]:
    files = resources.files("memory_pg").joinpath("migrations")
    versions = [int(p.name.split("_", 1)[0]) for p in files.iterdir() if p.name.endswith(".sql")]
    if len(versions) != len(set(versions)):
        raise SchemaMismatch("migrations/ 有重複版本號")
    return set(versions)


def applied_schema_versions(conn: psycopg.Connection) -> set[int]:
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass('public.schema_migrations') IS NOT NULL")
        if not cur.fetchone()[0]:
            return set()
        cur.execute("SELECT version FROM schema_migrations")
        return {int(r[0]) for r in cur.fetchall()}


def assert_schema(conn: psycopg.Connection) -> None:
    # 比對整個集合而不只 max()：紀錄有缺洞、或被手動插入最高版號時，max 會誤判為最新
    have, want = applied_schema_versions(conn), expected_schema_versions()
    if have != want:
        raise SchemaMismatch(
            f"db={sorted(have)} expected={sorted(want)}，執行 memory migrate"
            + ("（db 多出未知版本）" if have - want else "")
        )


def extensions(conn: psycopg.Connection) -> dict[str, str]:
    with conn.cursor() as cur:
        cur.execute("SELECT extname, extversion FROM pg_extension")
        return {name: ver for name, ver in cur.fetchall()}


def fts_backend(conn: psycopg.Connection) -> str:
    """'pgroonga' 或 'ilike'（退路）。兩者都不可用的情況由呼叫端決定要不要拒絕。"""
    return "pgroonga" if "pgroonga" in extensions(conn) else "ilike"
