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


def _cmd_audit(args: argparse.Namespace) -> int:
    from . import audit as auditmod

    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        rep = auditmod.run(conn, cfg)
        for f in rep.findings:
            print(f.line(), file=sys.stderr if f.level == "WARN" else sys.stdout)
        return 1 if rep.has_warn else EXIT_OK
    finally:
        conn.close()


def _cmd_index(args: argparse.Namespace) -> int:
    # 相容別名：--check ＝ export --verify；--write ＝ export
    args.verify = args.check
    args.canonical = False
    return _cmd_export(args)


def _cmd_search(args: argparse.Namespace) -> int:
    import json as _json
    import os as _os

    from . import search as searchmod

    from . import embed as embedmod

    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        embed_fn = None
        if args.mode == "hybrid":
            with conn.cursor() as cur:
                cur.execute("SELECT model, query_prefix FROM embedding_config LIMIT 1")
                row = cur.fetchone()
            if row:
                to = float(_os.environ.get("MEMORY_EMBED_TIMEOUT", "3"))
                embed_fn = embedmod.make_query_embedder(row[0], row[1] or "", timeout=to)
        res = searchmod.search(
            conn, cfg, args.query,
            cwd=_os.getcwd(),
            scope=("all" if args.all else args.scope),
            k=args.k,
            include_superseded=args.all_status,
            mode=args.mode,
            degrade_ok=args.degrade,
            embed_fn=embed_fn,
        )
        for w in res.warnings:
            print(f"WARN -: {w}", file=sys.stderr)
        if res.degraded:
            print(f"WARN -: degraded={res.degraded} backend={res.backend} mode={res.mode}", file=sys.stderr)
        elif res.backend != "pgroonga":
            print(f"WARN -: backend={res.backend}", file=sys.stderr)
        searchmod.log_access(conn, event="search", cwd=_os.getcwd(), keyword=args.query,
                             hits=res.hits, mode=res.mode)
        if args.json:
            print(_json.dumps({
                "ok": True, "degraded": res.degraded, "backend": res.backend, "mode": res.mode,
                "model": res.model,
                "results": [
                    {"id": h.name, "path": h.file_path, "description": h.description,
                     "scope": h.scope, "project_key": h.project_key, "kind": h.kind,
                     "status": h.status, "pinned": h.pinned, "stale": h.stale,
                     "rank": i + 1, "score": round(h.rrf, 6),
                     "matched": {"id": h.id_hit, "fts": h.fts_rank is not None,
                                 "vec": h.vec_rank is not None, "sim": h.sim}}
                    for i, h in enumerate(res.hits)
                ],
            }, ensure_ascii=False))
        else:
            # TSV 契約：<git-bash 絕對路徑>\t<id>\t<description>
            for h in res.hits:
                print(f"{h.file_path}\t{h.name}\t{h.description}")
        return EXIT_OK
    finally:
        conn.close()


def _cmd_eval(args: argparse.Namespace) -> int:
    from . import eval_models

    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        results = []
        for model in args.models:
            print(f"# 評測 {model} …", file=sys.stderr)
            results.append(eval_models.evaluate(conn, cfg, model))
        hdr = ["model", "top3", "mrr", "embed20ms", "coldms", "nan", "tau", "negSim", "gMinSim"]
        print("\t".join(hdr))
        for r in results:
            print("\t".join(str(x) for x in [
                r.model, f"{r.top3:.2f}", f"{r.mrr:.3f}", f"{r.embed_20_ms:.0f}",
                f"{r.cold_ms:.0f}", r.nan_count, r.tau_suggest, f"{r.neg_max_sim:.3f}", f"{r.golden_min_sim:.3f}"]))
            for n in r.notes:
                print(f"  - {n}")
        winner, log = eval_models.choose(results)
        for line in log:
            print(f"# {line}", file=sys.stderr)
        if winner:
            print(f"\n建議：--set-model {winner.model} --dim 1024 --tau {winner.tau_suggest}")
        return EXIT_OK
    finally:
        conn.close()


def _cmd_embed(args: argparse.Namespace) -> int:
    from . import embed as embedmod

    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        with conn.cursor() as cur:
            cur.execute("SELECT model, dim, doc_prefix FROM embedding_config LIMIT 1")
            row = cur.fetchone()
        if not row and not args.set_model:
            print("WARN -: config_missing 尚未設定 embedding 模型，用 --set-model <name> --dim <n>", file=sys.stderr)
            return 2
        if args.set_model:
            model, dim, dprefix = args.set_model, args.dim, (args.doc_prefix or "")
            with db.top_level_transaction(conn):
                with conn.cursor() as cur:
                    cur.execute("DELETE FROM embedding_config")
                    cur.execute(
                        "INSERT INTO embedding_config(model,dim,query_prefix,doc_prefix,tau) VALUES (%s,%s,%s,%s,%s)",
                        (model, dim, args.query_prefix or "", dprefix, args.tau),
                    )
        else:
            model, dim, dprefix = row

        if args.smoke:
            return _embed_smoke(conn, cfg, model, dim)

        # 選要算的列：--all 全部；否則只算 pending（無 embedding 或 hash/model 不符）
        with conn.cursor() as cur:
            cur.execute("SELECT name, description, body, embedding_src_hash, embedding_model FROM memories WHERE status='active'")
            rows = cur.fetchall()
        todo = []
        for name, desc, body, old_hash, old_model in rows:
            text = embedmod.build_embed_text(name, desc, body, doc_prefix=dprefix)
            h = embedmod.src_hash(text)
            if args.all or old_hash != h or old_model != model:
                todo.append((name, text, h))
        if not todo:
            print("embed: 無待算項")
            return EXIT_OK
        vecs = embedmod.embed_texts(cfg, model, [t for _, t, _ in todo], timeout=120.0)
        ok = fail = 0
        with db.top_level_transaction(conn):
            with conn.cursor() as cur:
                for (name, _t, h), v in zip(todo, vecs):
                    if v is None:
                        fail += 1
                        print(f"WARN -: embed_failed {name}（ollama 回非有限值，留 NULL）", file=sys.stderr)
                        continue
                    cur.execute(
                        "UPDATE memories SET embedding=%s, embedding_model=%s, embedding_dim=%s, "
                        "embedding_src_hash=%s, embedded_at=now() WHERE name=%s",
                        (str(v), model, dim, h, name),
                    )
                    ok += 1
        print(f"embed model={model} ok={ok} failed={fail} total={len(todo)}")
        return 1 if fail else EXIT_OK
    finally:
        conn.close()


def _embed_smoke(conn, cfg, model, dim) -> int:
    from . import embed as embedmod

    with conn.cursor() as cur:
        cur.execute("SELECT name, description, body FROM memories WHERE status='active'")
        rows = cur.fetchall()
    texts = [embedmod.build_embed_text(n, d, b) for n, d, b in rows]
    vecs = embedmod.embed_texts(cfg, model, texts, timeout=120.0)
    bad = [rows[i][0] for i, v in enumerate(vecs) if v is None or len(v) != dim]
    print(f"embed --smoke model={model} dim={dim} n={len(rows)} bad={len(bad)}",
          file=sys.stderr if bad else sys.stdout)
    for name in bad:
        print(f"WARN -: embed_smoke_bad {name}", file=sys.stderr)
    return 1 if bad else EXIT_OK


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

    a = sub.add_parser("audit", help="記憶庫健全性檢查（WARN→stderr+exit1；SUGGEST/INFO→stdout）")
    a.set_defaults(fn=_cmd_audit)

    ix = sub.add_parser("index", help="相容別名：--check=export --verify；--write=export")
    ixg = ix.add_mutually_exclusive_group()
    ixg.add_argument("--check", action="store_true")
    ixg.add_argument("--write", action="store_true")
    ix.set_defaults(fn=_cmd_index)

    s = sub.add_parser("search", help="hybrid 檢索（沿用 TSV 三欄契約）")
    s.add_argument("query")
    s.add_argument("--scope", help="global | <project_key>；預設為目前專案 + global")
    s.add_argument("--all", action="store_true", help="所有 scope（不限目前專案）")
    s.add_argument("--all-status", action="store_true", help="含已取代/deprecated")
    s.add_argument("--mode", choices=["hybrid", "fts"], default="hybrid")
    s.add_argument("--degrade", action="store_true", help="向量路不可用時降為 fts，不 fail-closed")
    s.add_argument("--k", type=int, default=10)
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=_cmd_search)

    ev = sub.add_parser("eval", help="評測候選 embedding 模型並建議選擇")
    ev.add_argument("models", nargs="+")
    ev.set_defaults(fn=_cmd_eval)

    em = sub.add_parser("embed", help="用本機 ollama 算 embedding")
    em.add_argument("--all", action="store_true", help="全部重算（換模型時）")
    em.add_argument("--smoke", action="store_true", help="全部嵌一次檢查 finite/維度，不寫入")
    em.add_argument("--set-model", help="設定現行 embedding 模型")
    em.add_argument("--dim", type=int, default=1024)
    em.add_argument("--query-prefix", default="")
    em.add_argument("--doc-prefix", default="")
    em.add_argument("--tau", type=float, default=0.5)
    em.set_defaults(fn=_cmd_embed)

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
