"""migrations：按版本號依序套用 memory_pg/migrations/NNNN_*.sql，每支一個交易。

沒有 psql（本機沒裝），所以 SQL 由 psycopg 執行。migration 檔內不可用 psql meta-command（\\c 等）。
"""

from __future__ import annotations

from importlib import resources

import psycopg

from .db import applied_schema_versions, top_level_transaction


def _migration_files() -> list[tuple[int, str, str]]:
    files = resources.files("memory_pg").joinpath("migrations")
    out = []
    for p in files.iterdir():
        if p.name.endswith(".sql"):
            out.append((int(p.name.split("_", 1)[0]), p.name, p.read_text(encoding="utf-8")))
    return sorted(out)


def status(conn: psycopg.Connection) -> tuple[list[int], list[int]]:
    """回傳 (已套用版本集合, 期望版本集合)，皆排序。用完整集合而非 max()：
    DB 有 {2} 缺 {1} 時 max 會誤報正常，而修復命令也要據此補上缺的那支。"""
    return sorted(applied_schema_versions(conn)), sorted(v for v, _, _ in _migration_files())


def apply(conn: psycopg.Connection, *, dry_run: bool = False) -> list[str]:
    """套用所有「期望有、DB 沒有」的 migration（依版本序）。回傳套用（或將套用）的檔名。"""
    # 收掉 current_schema_version 之類的 SELECT 開的隱式交易，讓每支 migration 各自頂層 commit
    # （2026-08-25 實測：不收的話印了 applied 卻 db=0——SAVEPOINT 在連線關閉時整批 rollback）。
    conn.commit()
    # session-level advisory lock：序列化並行的 migrate，連線關閉自動釋放。
    with conn.cursor() as cur:
        cur.execute("SELECT pg_advisory_lock(hashtext('memory_pg_migrate'))")
    conn.commit()
    have = applied_schema_versions(conn)   # 拿到鎖之後重讀
    conn.commit()
    applied: list[str] = []
    for version, name, sql in _migration_files():
        if version in have:               # 用集合成員判定，不用 <= max（補得了缺洞）
            continue
        applied.append(name)
        if dry_run:
            continue
        with top_level_transaction(conn):
            with conn.cursor() as cur:
                cur.execute(sql)
                cur.execute(
                    "INSERT INTO schema_migrations(version) VALUES (%s)", (version,)
                )
    return applied
