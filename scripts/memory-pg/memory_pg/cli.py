"""CLI 入口。子命令逐 Task 加；每個子命令都經同一個 _run 包裝，exit code 契約集中在此。"""

from __future__ import annotations

import argparse
import os
import sys
import traceback

import psycopg
from psycopg import conninfo

from . import __version__, config, db, migrate
from .errors import EXIT_OK, EXIT_UNDETERMINED, MemoryError_


def _cmd_doctor(args: argparse.Namespace) -> int:
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        ext = db.extensions(conn)
        have, want = migrate.status(conn)
        with conn.cursor() as cur:
            cur.execute("SELECT version()")
            pgver = cur.fetchone()[0].split(",")[0]
        ci = conninfo.conninfo_to_dict(cfg.dsn)
        report = [
            f"target     {ci.get('host', '?')}:{ci.get('port', '?')}/{ci.get('dbname', '?')}",
            f"postgres   {pgver}",
            f"pgroonga   {ext.get('pgroonga', '缺')}",
            f"vector     {ext.get('vector', '缺')}",
            f"pg_trgm    {ext.get('pg_trgm', '缺')}",
            f"fts        {db.fts_backend(conn)}",
            f"schema     db={have} expected={want}{'' if have == want else '  ← 執行 memory migrate'}",
        ]
        problems = []
        if "vector" not in ext:
            problems.append("vector 擴充缺，向量路無法運作")
        if "pgroonga" not in ext:
            problems.append("pgroonga 缺，全文路將走 ILIKE 退路")
        if have != want:
            problems.append("schema 版本不符")
        # 契約：exit≠0 時 stdout 零輸出——診斷報告在失敗時整份改走 stderr
        out = sys.stderr if problems else sys.stdout
        for line in report:
            print(line, file=out)
        for p in problems:
            print(f"WARN -: doctor {p}", file=sys.stderr)
        return 1 if problems else EXIT_OK
    finally:
        conn.close()


def _cmd_migrate(args: argparse.Namespace) -> int:
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        if args.status:
            have, want = migrate.status(conn)
            ok = have == want
            print(f"schema db={have} expected={want}", file=sys.stdout if ok else sys.stderr)
            if not ok and set(have) - set(want):
                print("WARN -: schema_mismatch db 有未知版本", file=sys.stderr)
            return EXIT_OK if ok else 1
        applied = migrate.apply(conn, dry_run=args.dry_run)
        if not applied:
            print("schema 已是最新")
        for name in applied:
            print(("(dry-run) " if args.dry_run else "applied ") + name)
        return EXIT_OK
    finally:
        conn.close()


def _cmd_import(args: argparse.Namespace) -> int:
    from . import exporter, importer

    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        rep = importer.run(conn, cfg, dry_run=args.dry_run)
        for w in rep.warnings:
            print(f"WARN -: {w}", file=sys.stderr)
        tag = "(dry-run) " if rep.dry_run else ""
        summary = (f"{tag}import banks={rep.banks} memories={rep.memories} "
                   f"projects={rep.projects} links={rep.links} deleted={rep.deleted}")
        if rep.dry_run or args.no_verify:
            print(summary)
            return EXIT_OK
        vdir = cfg.home / "cache" / "memory-export-verify"
        vrep = exporter.run(conn, cfg, verify_dir=vdir)
        rc = _print_verify(vrep, vdir)
        print(summary, file=sys.stdout if rc == EXIT_OK else sys.stderr)
        return rc
    finally:
        conn.close()


def _print_verify(vrep, vdir) -> int:
    from collections import Counter

    c = Counter(d.status for d in vrep.diffs)
    bad = vrep.memory_mismatches
    failed = bool(bad or c.get("index_pinned_differ"))
    out = sys.stderr if failed else sys.stdout        # 契約：exit≠0 時 stdout 零輸出
    print(f"verify written={vrep.written} " + " ".join(f"{k}={v}" for k, v in sorted(c.items())) + f"  → {vdir}", file=out)
    for w in vrep.warnings:
        print(f"WARN -: {w}", file=sys.stderr)
    for d in bad:
        print(f"  {d.status:16} {d.path}", file=out)
    for d in vrep.diffs:
        if d.status == "index_pinned_differ":
            print(f"  {d.status:16} {d.path}", file=out)
    if failed:
        print("WARN -: export_drift 匯出結果與 bank 不一致（見上）", file=sys.stderr)
        return 1
    return EXIT_OK


def _cmd_export(args: argparse.Namespace) -> int:
    from . import exporter

    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        if args.verify:
            vdir = cfg.home / "cache" / "memory-export-verify"
            return _print_verify(exporter.run(conn, cfg, verify_dir=vdir, canonical=args.canonical), vdir)
        rep = exporter.run(conn, cfg, verify_dir=None, canonical=args.canonical)
        for w in rep.warnings:
            print(f"WARN -: {w}", file=sys.stderr)
        print(f"export banks={rep.banks} files={rep.written}")
        return EXIT_OK
    finally:
        conn.close()


def _cmd_project(args: argparse.Namespace) -> int:
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        with conn.cursor() as cur:
            if args.action == "list":
                cur.execute(
                    """SELECT p.slug, p.family, p.root_path, p.is_workspace_root,
                              (SELECT count(*) FROM memories m WHERE m.home_project_id = p.id) AS n
                       FROM projects p ORDER BY p.slug"""
                )
                for slug, fam, root, ws, n in cur.fetchall():
                    print(f"{slug}\t{fam or '-'}\t{root}\t{'workspace' if ws else '-'}\t{n}")
                return EXIT_OK
            if args.action == "set":
                sets, vals = [], []
                if args.root is not None:
                    sets.append("root_path = %s"); vals.append(args.root)
                if args.family is not None:
                    sets.append("family = %s"); vals.append(args.family)
                if args.workspace_root is not None:
                    sets.append("is_workspace_root = %s"); vals.append(args.workspace_root == "true")
                if not sets:
                    print("WARN -: usage 沒有要更新的欄位", file=sys.stderr); return 2
                vals.append(args.slug)
                cur.execute(f"UPDATE projects SET {', '.join(sets)} WHERE slug = %s", vals)
                if cur.rowcount == 0:
                    print(f"WARN -: usage 找不到 project {args.slug}", file=sys.stderr); return 2
                conn.commit()
                print(f"updated {args.slug}")
                return EXIT_OK
        return 2
    finally:
        conn.close()


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="memory", description="eng-flow 記憶系統（PostgreSQL 後端）")
    p.add_argument("--version", action="version", version=f"memory-pg {__version__}")
    p.add_argument("--test-db", action="store_true", help="改用 MEMORY_PG_TEST_DSN（測試用）")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("doctor", help="檢查連線、擴充、schema 版本")
    d.set_defaults(fn=_cmd_doctor)

    m = sub.add_parser("migrate", help="套用 migrations")
    m.add_argument("--status", action="store_true")
    m.add_argument("--dry-run", action="store_true")
    m.set_defaults(fn=_cmd_migrate)

    i = sub.add_parser("import", help="把 Markdown bank 匯入 PG（單一交易；來源有誤整批不寫）")
    i.add_argument("--dry-run", action="store_true", help="只驗證與統計，rollback 不寫入")
    i.add_argument("--no-verify", action="store_true", help="匯入後不跑 export --verify")
    i.set_defaults(fn=_cmd_import)

    e = sub.add_parser("export", help="從 PG 產生 Markdown bank（記憶檔 + MEMORY.md）")
    e.add_argument("--verify", action="store_true", help="寫到 cache/memory-export-verify 並與 bank 比對，不碰 bank")
    e.add_argument("--canonical", action="store_true", help="frontmatter 全部改用 canonical 順序（不用原樣回寫）")
    e.set_defaults(fn=_cmd_export)

    pr = sub.add_parser("project", help="專案登錄")
    prs = pr.add_subparsers(dest="action", required=True)
    prs.add_parser("list")
    ps = prs.add_parser("set")
    ps.add_argument("slug")
    ps.add_argument("--root")
    ps.add_argument("--family")
    ps.add_argument("--workspace-root", choices=["true", "false"])
    pr.set_defaults(fn=_cmd_project)
    return p


def main(argv: list[str] | None = None) -> int:
    # 輸出一律 UTF-8：TSV 契約是 UTF-8，且 Windows console 預設 code page 會把中文 stderr 打成亂碼。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:  # argparse 自己 exit 2 / 0（--help）
        return int(e.code or 0)
    try:
        return int(args.fn(args))
    except MemoryError_ as e:
        # 契約：exit 1/2 時 stdout 零輸出。子命令在成功前不得印 stdout（各 fn 自行遵守）。
        print(e.stderr_line(), file=sys.stderr)
        return e.exit_code
    except KeyboardInterrupt:
        return 130
    except psycopg.Error as e:
        # migration SQL 錯、約束違反、觸發器 RAISE 等：同樣是「無法判定正確性」，一行 stderr，
        # 不吐 traceback（那會把 DSN/密碼一起帶出來）。MEMORY_PG_DEBUG=1 才印完整堆疊。
        msg = (str(e).strip().splitlines() or ["?"])[0]
        print(f"WARN -: backend_error {type(e).__name__}: {msg}", file=sys.stderr)
        if os.environ.get("MEMORY_PG_DEBUG"):
            traceback.print_exc()
        return EXIT_UNDETERMINED
    except Exception as e:  # noqa: BLE001 — 最後一道：任何未預期例外都不能變成 traceback + exit 1 以外的東西
        print(f"WARN -: internal_error {type(e).__name__}: {e}", file=sys.stderr)
        if os.environ.get("MEMORY_PG_DEBUG"):
            traceback.print_exc()
        return EXIT_UNDETERMINED


if __name__ == "__main__":
    sys.exit(main())
