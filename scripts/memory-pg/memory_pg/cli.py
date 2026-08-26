"""CLI 入口。子命令逐 Task 加；每個子命令都經同一個 _run 包裝，exit code 契約集中在此。"""

from __future__ import annotations

import argparse
import os
import sys
import traceback
from pathlib import Path

import psycopg
from psycopg import conninfo

from . import __version__, config, db, frontmatter as fm, migrate
from .errors import EXIT_OK, EXIT_UNDETERMINED, EXIT_USAGE, MemoryError_, UsageError


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
        switching = bool(args.set_model)
        if switching:
            model, dim, dprefix = args.set_model, args.dim, (args.doc_prefix or "")
        else:
            model, dim, dprefix = row

        if args.smoke:
            return _embed_smoke(conn, cfg, model, dim)

        # 選要算的列。切換模型（--set-model）等同 --all：新模型的所有 active 都要重算。
        with conn.cursor() as cur:
            cur.execute("SELECT name, description, body, embedding_src_hash, embedding_model FROM memories WHERE status='active'")
            rows = cur.fetchall()
        todo = []
        for name, desc, body, old_hash, old_model in rows:
            text = embedmod.build_embed_text(name, desc, body, doc_prefix=dprefix)
            h = embedmod.src_hash(text)
            if args.all or switching or old_hash != h or old_model != model:
                todo.append((name, text, h))

        vecs = embedmod.embed_texts(cfg, model, [t for _, t, _ in todo], timeout=120.0) if todo else []
        # 維度不符與「算不出來」是同一類失敗，必須在下面的原子性檢查【之前】就併進 fail。
        # 放到寫入迴圈裡才判的話，--set-model 遇到維度不符仍會切換 embedding_config，留下
        # 「新設定 + 舊模型向量」——search 判模型不一致就整體 fail-closed，比缺 embedding 更糟。
        for _i, _v in enumerate(vecs):
            if _v is not None and len(_v) != dim:
                print(f"WARN -: embed_dim_mismatch {todo[_i][0]} 回 {len(_v)} 維、設定為 {dim} 維，視同算不出來",
                      file=sys.stderr)
                vecs[_i] = None
        fail = sum(1 for v in vecs if v is None)

        # 原子性（R2/收斂問句）：切換模型時，若不是全部成功就【不切換設定】——
        # 舊模型的向量必須維持可搜尋，直到新模型的所有 active 都寫入。避免「設定已換、
        # 文件仍是舊模型」讓 search 因模型不一致 fail-closed。
        if switching and fail and not args.force:
            print(f"WARN -: embed_incomplete 切換 {model} 失敗 {fail}/{len(todo)} 列，維持舊設定不切換。"
                  f"排除 ollama 問題後重跑，或 --force 強制切換（會有列缺 embedding）", file=sys.stderr)
            return 1

        with db.top_level_transaction(conn):
            with conn.cursor() as cur:
                if switching:
                    cur.execute("DELETE FROM embedding_config")
                    cur.execute(
                        "INSERT INTO embedding_config(model,dim,query_prefix,doc_prefix,tau) VALUES (%s,%s,%s,%s,%s)",
                        (model, dim, args.query_prefix or "", dprefix, args.tau),
                    )
                ok = 0
                for (name, _t, h), v in zip(todo, vecs):
                    if v is None:
                        # 切換模型時的失敗列：清掉舊模型的 embedding（否則設定已是新模型、此列仍是
                        # 舊模型 → search 判 mismatch 而整體 fail-closed）。清成 NULL 後變「缺 embedding」，
                        # search 只略過+警示。--force 的語意就是「切換並容忍缺列」。
                        if switching:
                            cur.execute("UPDATE memories SET embedding=NULL, embedding_model=NULL, "
                                        "embedding_dim=NULL, embedding_src_hash=NULL, embedded_at=NULL "
                                        "WHERE name=%s", (name,))
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


def _cmd_purge(args, cfg, conn) -> int:
    """卸載後清理：刪掉某個已卸載分割區在 DB 的殘留列。

    **presence 必須是 not_installed 才允許**。bank 仍 installed 時只刪 DB，下一次 import
    會從 md 把它復活；若順手連 bank 一起刪，等於刪掉仍受版控的檔案——不可逆範圍變得不清楚。
    真有「同時清 DB 與 bank」的需求，另設語義明確的破壞性命令，不沿用 purge。
    unavailable / damaged_install 一律禁止（狀態未知時不做不可逆操作，安全鐵律 4）。
    """
    where, params, label = [], [], []
    for sc in (args.purge_scope or []):
        st = cfg.bank_presence(sc)
        if st != "not_installed":
            print(f"WARN -: purge_refused {sc} 的 bank 狀態是 {st}，只有 not_installed 才允許 purge。"
                  f"要清 DB 請先卸載該 repo", file=sys.stderr)
            return EXIT_USAGE
        where.append("scope = %s"); params.append(sc); label.append(sc)
    slugs = list(args.purge_project or [])
    if args.purge_all_projects:
        where.append("scope = 'project'"); label.append("所有專案")
    elif slugs:
        where.append("home_project_id IN (SELECT id FROM projects WHERE slug = ANY(%s))")
        params.append(slugs); label.append(",".join(slugs))
    cond = " OR ".join(where)
    with conn.cursor() as cur:
        cur.execute(f"SELECT name FROM memories WHERE {cond} ORDER BY name", params)
        names = [r[0] for r in cur.fetchall()]
    print(f"purge 將刪除 {len(names)} 則（{'; '.join(label)}）：")
    for n in names:
        print(f"  {n}")
    if not args.yes:
        print("WARN -: purge_needs_yes 這是不可逆操作，確認清單無誤後加 --yes 執行",
              file=sys.stderr)
        return EXIT_USAGE
    with db.top_level_transaction(conn):
        with conn.cursor() as cur:
            cur.execute(f"DELETE FROM memories WHERE {cond}", params)
            n = cur.rowcount
    print(f"purge deleted={n}")
    return EXIT_OK


def _cmd_import(args: argparse.Namespace) -> int:
    from . import exporter, importer

    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        if args.purge_scope or args.purge_project or args.purge_all_projects:
            return _cmd_purge(args, cfg, conn)
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
        # 與 _auto_export 用同一個判定，不可一處看回傳值、一處只等 exception。
        # skipped（not_installed）不算失敗——單 repo 機器是合法安裝。
        print(f"export banks={rep.banks} files={rep.written}"
              + (f" skipped={len(rep.skipped_banks)}" if rep.skipped_banks else "")
              + (f" partial={len(rep.partial_banks)}" if rep.partial_banks else "")
              + (f" failed={len(rep.failed_banks)}" if rep.failed_banks else ""))
        return EXIT_OK if rep.ok else EXIT_UNDETERMINED
    finally:
        conn.close()


def _read_input(args) -> str:
    if getattr(args, "file", None):
        return Path(args.file).read_text(encoding="utf-8")
    if not sys.stdin.isatty():
        return sys.stdin.read()
    return ""


def _review_by_arg(value: str | None):
    """--review-by 的參數翻譯：未傳 → KEEP（不動）；'none' → None（清除）；其餘要是合法日期。

    不驗的話 `--review-by 2026-13-45` 會一路送到 PG，由 psycopg 的 handler 接成 exit 1
    「無法判定正確性」——但這是**用法錯**，契約上該是 exit 2。
    """
    from . import mutate
    if value is None:
        return mutate.KEEP
    if value.lower() == "none":
        return None
    if not fm.date_ok(value):
        raise UsageError(f"--review-by 不是合法日期（{value}），格式 YYYY-MM-DD", code="bad_date")
    return value


def _auto_embed(conn, cfg, names: list[str]) -> None:
    """mutating 子命令後同步補算受影響記憶的 embedding（設計 A5：寫入時算）。

    不做的話新寫/改的記憶在有人手動跑 embed 之前完全不進向量路，search 每次都印「缺 embedding」
    並整體降級成全文單路——最需要被找到的（剛寫下的）反而召回最差。
    失敗一律不致命：ollama 不在或回非有限值就留 NULL + 警示，由 `memory embed --pending` 補。
    """
    from . import embed as embedmod
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT model, dim, doc_prefix FROM embedding_config LIMIT 1")
            row = cur.fetchone()
        if not row:
            return                       # 尚未設定模型，不是這條路徑該解的問題
        model, dim, dprefix = row
        todo = []
        with conn.cursor() as cur:
            for nm in names:
                cur.execute("SELECT name, description, body, embedding_src_hash, embedding_model "
                            "FROM memories WHERE name=%s AND status='active'", (nm,))
                r = cur.fetchone()
                if not r:
                    continue
                text = embedmod.build_embed_text(r[0], r[1], r[2], doc_prefix=dprefix)
                h = embedmod.src_hash(text)
                # 設計 A5 的重算判定。少了它，`edit x --pin` 這種內容沒變的治理型編輯也會打一次
                # ollama；ollama 卡住時一個 pin 切換要等滿 timeout。
                if r[3] == h and r[4] == model:
                    continue
                todo.append((r[0], text, h))
        if not todo:
            return
        try:
            # timeout 是【每次 HTTP 嘗試】的上限，不是總時長：embed_texts 整批失敗後會逐筆重試，
            # 所以單則 write/edit 最壞會阻塞約 2×timeout。互動式 CLI 不該卡到一分鐘。
            vecs = embedmod.embed_texts(cfg, model, [t for _, t, _ in todo], timeout=15.0)
        except Exception as e:  # noqa: BLE001
            # embed_texts 只吞 httpx.HTTPError / RetrievalUnavailable，其餘（ollama 回非 JSON、
            # 結構不符、空陣列取 [0]）會往外拋。這裡必須降級成「全部算不出來」走下面的清除分支，
            # 不能讓例外冒到函式外層——那樣只會印一行 WARN，而內容已改、舊向量還留著。
            print(f"WARN -: embed_after_write 呼叫失敗（{type(e).__name__}: {e}）", file=sys.stderr)
            vecs = [None] * len(todo)
        with db.top_level_transaction(conn):
            with conn.cursor() as cur:
                # 讀內容 → 呼叫 ollama → 寫回向量分屬不同交易，中間可能有另一個 edit 改過同一則，
                # 或有人跑了 embed --set-model。舊請求最後寫入的話，新正文會配上舊內容的向量、
                # 或舊模型的向量重新落地；而 search 只看 IS NULL 與 model，不比對 src_hash，
                # 兩種都察覺不到。以下用「寫入前重讀 + 條件成立才寫」把這個競態關掉。
                cur.execute("SELECT model FROM embedding_config LIMIT 1")
                live = cur.fetchone()
                model_changed = not live or live[0] != model
                if model_changed:
                    print("WARN -: embed_after_write 期間 embedding 模型已變更，本次不寫入"
                          "（稍後 memory embed --pending 補算）", file=sys.stderr)
                pairs = [] if model_changed else list(zip(todo, vecs))
                for (nm, _t, h), v in pairs:
                    cur.execute("SELECT description, body FROM memories WHERE name=%s AND status='active' "
                                "FOR UPDATE", (nm,))
                    live_row = cur.fetchone()
                    if not live_row:
                        continue
                    live_h = embedmod.src_hash(
                        embedmod.build_embed_text(nm, live_row[0], live_row[1], doc_prefix=dprefix))
                    if live_h != h:
                        # 期間又被改過：這一輪的向量已經對不上現況，寫下去反而製造過期向量。
                        # 那次 edit 自己的 _auto_embed 會處理，這裡什麼都不動。
                        print(f"WARN -: embed_after_write {nm} 期間內容又被改過，本次不寫入"
                              f"（稍後 memory embed --pending 補算）", file=sys.stderr)
                        continue
                    if v is not None and len(v) != dim:
                        # 同名模型改版後輸出維度變了會走到這裡。embedding 欄位不帶維度，混維度
                        # 寫得進去，但 hybrid search 一跑 `<=>` 就整體失敗——當成算不出來處理。
                        print(f"WARN -: embed_dim_mismatch {nm} 回 {len(v)} 維、設定為 {dim} 維，不寫入",
                              file=sys.stderr)
                        v = None
                    if v is None:
                        # 算不出來時**必須清掉舊向量**：內容已經改了，舊向量是過期的，而
                        # embedding_model 仍等於現行模型 → search 的檢查（只看 IS NULL 與 model
                        # 是否一致）看不出異常，會拿舊內容的語意去召回新記憶，且完全不警示。
                        # 清成 NULL 就退化成 search 會警示的「缺 embedding」，與 _cmd_embed 切換
                        # 模型失敗時的處置一致。
                        cur.execute("UPDATE memories SET embedding=NULL, embedding_model=NULL, "
                                    "embedding_dim=NULL, embedding_src_hash=NULL, embedded_at=NULL "
                                    "WHERE name=%s", (nm,))
                        continue
                    cur.execute("UPDATE memories SET embedding=%s, embedding_model=%s, embedding_dim=%s, "
                                "embedding_src_hash=%s, embedded_at=now() WHERE name=%s",
                                (str(v), model, dim, h, nm))
        miss = sum(1 for v in vecs if v is None)
        if miss:
            print(f"WARN -: embed_after_write {miss}/{len(todo)} 列未算成（已清成缺 embedding，"
                  f"稍後 memory embed --pending 補算）", file=sys.stderr)
    except Exception as e:  # noqa: BLE001
        print(f"WARN -: embed_after_write 失敗（DB 已更新，稍後 memory embed --pending）: {e}", file=sys.stderr)


def _auto_export(conn, cfg) -> bool:
    """mutating 子命令後自動 export（產 md，不 commit）。回傳是否成功。

    **失敗要讓命令 exit 1**——DB 已更新而 Markdown/repo 尚未同步，回 0 會讓自動化誤以為
    三個 repo 已一致。失敗有兩種形態，都要接：拋例外、以及正常回傳但 result.ok 為 False
    （某個 bank partial/failed）。只捕例外會漏掉後者。
    """
    from . import exporter
    try:
        result = exporter.run(conn, cfg, verify_dir=None)
    except Exception as e:  # noqa: BLE001
        print(f"WARN -: export_after_write DB 已更新、Markdown/repo 尚未同步（{e}）；"
              f"排除問題後跑 memory export", file=sys.stderr)
        return False
    if not result.ok:
        print(f"WARN -: export_after_write DB 已更新、Markdown/repo 尚未同步"
              f"（partial={[str(b) for b in result.partial_banks]} "
              f"failed={[str(b) for b in result.failed_banks]}）", file=sys.stderr)
        return False
    return True


def _resolve_project(conn, args) -> str | None:
    """project scope 省略 --project 時，從 cwd 推 slug（實作 help 宣稱的行為）。"""
    if args.project:
        return args.project
    if args.scope == "project":
        import os as _os
        from . import search as _s
        return _s.resolve_project_key(conn, _os.getcwd())
    return None


def _cmd_write(args: argparse.Namespace) -> int:
    from . import mutate
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        name, desc, body = mutate._parse_input(args.name, _read_input(args))
        desc = args.description or desc
        with db.top_level_transaction(conn):
            mutate.write(conn, cfg, name=name, scope=args.scope, description=desc, body=body,
                         kind=args.kind, pin=args.pin, review_by=args.review_by,
                         project_slug=_resolve_project(conn, args), tags=args.tag or [])
        _auto_embed(conn, cfg, [name])
        ok = _auto_export(conn, cfg)
        print(f"write {name}")
        return EXIT_OK if ok else EXIT_UNDETERMINED
    finally:
        conn.close()


def _cmd_edit(args: argparse.Namespace) -> int:
    from . import mutate
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        # 依「有沒有拿到內容」判斷，**不可**依 stdin 是不是 tty：hook / CI / 管線下 isatty() 為 False，
        # _read_input 讀到空字串，_parse_input 回一個只有換行的 body → 純治理型 edit（只給 --kind）會把正文
        # 覆寫成一個換行、連 wikilink 列一起刪光，而且不報錯。實測 2026-08-26：
        #   echo -n '' | memory edit x --kind decision --reason y  → 正文 44 bytes 變 1 byte
        # （Windows 上 `< /dev/null` 的 isatty() 反而回 True，所以拿 /dev/null 測正好測不到。）
        raw = _read_input(args)
        if args.file and not raw.strip():
            # 明確指定了檔案卻是空的：這幾乎都是弄錯檔名，不是「請把這則記憶清空」。
            # 破壞性操作在意圖不明時一律 fail-closed（安全鐵律 5）。
            raise UsageError(f"--file 指向的檔案沒有內容（{args.file}），拒絕執行——這通常是檔名弄錯，而不是真的要把這則記憶清空",
                             code="empty_input")
        _, desc, body = mutate._parse_input(args.name, raw) if raw.strip() else (None, None, None)
        with db.top_level_transaction(conn):
            # desc 為空字串 = 輸入是純 body（無 frontmatter），代表「不改 description」，不可當成要寫入空值
            mutate.edit(conn, cfg, args.name, description=(args.description or desc or None), body=body,
                        reason=args.reason,
                        kind=(args.kind if args.kind else mutate.KEEP),
                        pin=(True if args.pin else (False if args.unpin else mutate.KEEP)),
                        review_by=_review_by_arg(args.review_by))
        _auto_embed(conn, cfg, [args.name])
        ok = _auto_export(conn, cfg)
        print(f"edit {args.name}")
        return EXIT_OK if ok else EXIT_UNDETERMINED
    finally:
        conn.close()


def _cmd_learn(args: argparse.Namespace) -> int:
    from . import mutate
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        name, desc, body = mutate._parse_input(args.name, _read_input(args))
        desc = args.description or desc
        with db.top_level_transaction(conn):
            mutate.learn(conn, cfg, supersedes=args.supersedes or [], confirms=args.confirms or [],
                         force=args.force, name=name, scope=args.scope, description=desc, body=body,
                         kind=args.kind, pin=args.pin, review_by=args.review_by,
                         project_slug=_resolve_project(conn, args), tags=args.tag or [])
        _auto_embed(conn, cfg, [name])
        ok = _auto_export(conn, cfg)
        print(f"learn {name}")
        return EXIT_OK if ok else EXIT_UNDETERMINED
    finally:
        conn.close()


def _cmd_forget(args: argparse.Namespace) -> int:
    from . import mutate
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        with db.top_level_transaction(conn):
            mutate.forget(conn, cfg, args.name, reason=args.reason, status=args.status)
        ok = _auto_export(conn, cfg)
        print(f"forget {args.name} → {args.status}")
        return EXIT_OK if ok else EXIT_UNDETERMINED
    finally:
        conn.close()


def _cmd_verify(args: argparse.Namespace) -> int:
    from . import mutate
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        with db.top_level_transaction(conn):
            mutate.verify(conn, cfg, args.name, method=args.method, extend_days=args.extend_days)
        ok = _auto_export(conn, cfg)
        print(f"verify {args.name}")
        return EXIT_OK if ok else EXIT_UNDETERMINED
    finally:
        conn.close()


def _cmd_session_context(args: argparse.Namespace) -> int:
    import os as _os
    from . import session_context
    cfg = config.load(use_test_db=args.test_db)
    try:
        conn = db.connect(cfg)
    except Exception as e:  # noqa: BLE001  hook 不可被擋：PG 不在就印一行提示、exit 0
        print(f"記憶服務未啟動（{type(e).__name__}）：cd ~/.claude/memory-pg && docker compose up -d", file=sys.stderr)
        return EXIT_OK
    try:
        # 整段（render + 遙測）都不可讓 hook 非 0：schema 未遷移、連線中斷等都要降級成 exit 0。
        text, pk, pinned = session_context.render(conn, cfg, getattr(args, "cwd", None) or _os.getcwd(),
                                                  slug=getattr(args, "slug", None))
        if text:
            sys.stdout.write(text)
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT id FROM projects WHERE slug=%s", (pk,))
                    r = cur.fetchone()
                    # 只記【本 session 實際注入】的 pinned（沿用 render 的可見性），不是全部 pinned
                    cur.execute(
                        "INSERT INTO memory_access_log(event, project_id, cwd, n, memory_ids) "
                        "VALUES ('inject',%s,%s,%s,"
                        "(SELECT coalesce(array_agg(id),'{}') FROM memories WHERE name = ANY(%s)))",
                        (r[0] if r else None, _os.getcwd(), len(pinned), pinned))
                conn.commit()
            except psycopg.Error:
                conn.rollback()
        return EXIT_OK
    except Exception as e:  # noqa: BLE001  hook 不可被擋
        print(f"記憶注入略過（{type(e).__name__}）", file=sys.stderr)
        return EXIT_OK
    finally:
        conn.close()


def _cmd_log(args: argparse.Namespace) -> int:
    cfg = config.load(use_test_db=args.test_db)
    conn = db.connect(cfg)
    try:
        db.assert_schema(conn)
        if args.import_tsv:
            path = Path(args.import_tsv)
            if not path.is_file():
                print(f"WARN -: usage 找不到 {path}", file=sys.stderr); return 2
            n = 0
            with db.top_level_transaction(conn), conn.cursor() as cur:
                for line in path.read_text(encoding="utf-8").splitlines():
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split("\t")
                    if len(parts) < 5:
                        continue
                    ts, event, cwd, keyword, ncol = parts[:5]
                    ids = parts[5] if len(parts) > 5 else ""
                    names = [x for x in ids.split(",") if x]
                    cur.execute(
                        "INSERT INTO memory_access_log(ts, event, cwd, keyword, n, memory_ids) "
                        "VALUES (%s, %s, %s, %s, %s, "
                        "(SELECT coalesce(array_agg(id),'{}') FROM memories WHERE name = ANY(%s)))",
                        (ts, event if event in ("search", "inject") else "search", cwd, keyword or None,
                         int(ncol) if ncol.isdigit() else 0, names))
                    n += 1
            print(f"log import-tsv rows={n}")
            return EXIT_OK
        with conn.cursor() as cur:
            since = f"WHERE ts >= %s" if args.since else ""
            cur.execute(f"SELECT event, count(*), sum(CASE WHEN n=0 THEN 1 ELSE 0 END) "
                        f"FROM memory_access_log {since} GROUP BY event ORDER BY event",
                        ((args.since,) if args.since else ()))
            for event, c, zero in cur.fetchall():
                print(f"{event}\t{c}\tzero_hits={zero or 0}")
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
    # B5 契約是 embed [--pending|--all|--smoke]，三者互斥。用 group 讓矛盾組合變成 argparse
    # 的用法錯（exit 2），而不是靜默照某一個走——--pending 本身是預設行為，不加 group 的話
    # `--all --pending` 會安靜地走 --all。
    emg = em.add_mutually_exclusive_group()
    emg.add_argument("--all", action="store_true", help="全部重算（換模型時）")
    emg.add_argument("--pending", action="store_true", help="只補算缺 embedding 或內容已變的列（預設行為）")
    emg.add_argument("--smoke", action="store_true", help="全部嵌一次檢查 finite/維度，不寫入")
    em.add_argument("--set-model", help="設定現行 embedding 模型")
    em.add_argument("--dim", type=int, default=1024)
    em.add_argument("--query-prefix", default="")
    em.add_argument("--doc-prefix", default="")
    em.add_argument("--tau", type=float, default=0.5)
    em.add_argument("--force", action="store_true", help="切換模型時即使有列失敗也強制切換")
    em.set_defaults(fn=_cmd_embed)

    i = sub.add_parser("import", help="把 Markdown bank 匯入 PG（單一交易；來源有誤整批不寫）")
    i.add_argument("--dry-run", action="store_true", help="只驗證與統計，rollback 不寫入")
    i.add_argument("--no-verify", action="store_true", help="匯入後不跑 export --verify")
    i.add_argument("--purge-scope", choices=["global", "machine", "work"], action="append",
                   help="卸載後清理：刪除該 scope 在 DB 的殘留列（要求 bank 為 not_installed）")
    i.add_argument("--purge-project", action="append", metavar="SLUG",
                   help="卸載後清理單一專案（可多次）")
    i.add_argument("--purge-all-projects", action="store_true",
                   help="卸載後清理所有專案。獨立旗標而非 --purge-project 的特例值："
                        "--purge-project 是 append，不帶值會在解析階段就報缺值")
    i.add_argument("--yes", action="store_true", help="確認執行 purge（不可逆）")
    i.set_defaults(fn=_cmd_import)

    e = sub.add_parser("export", help="從 PG 產生 Markdown bank（記憶檔 + MEMORY.md）")
    e.add_argument("--verify", action="store_true", help="寫到 cache/memory-export-verify 並與 bank 比對，不碰 bank")
    e.add_argument("--canonical", action="store_true", help="frontmatter 全部改用 canonical 順序（不用原樣回寫）")
    e.set_defaults(fn=_cmd_export)

    def _common_write(sp):
        sp.add_argument("--name")
        sp.add_argument("--description")
        sp.add_argument("--scope", default="project",
                        choices=["global", "machine", "work", "project"])
        sp.add_argument("--project", help="project scope 的 slug（省略則需在已登錄專案的 cwd）")
        sp.add_argument("--kind", choices=["semantic", "episodic", "procedural", "decision", "environment"])
        sp.add_argument("--pin", action="store_true")
        sp.add_argument("--review-by")
        sp.add_argument("--tag", action="append", help="標記 global 記憶與哪些專案相關（可多次）")
        sp.add_argument("--file", help="讀 md 檔（完整 frontmatter 或純 body）；省略則讀 stdin")

    w = sub.add_parser("write", help="新增記憶")
    _common_write(w)
    w.set_defaults(fn=_cmd_write)

    ed = sub.add_parser("edit", help="改記憶內容或治理欄位（舊版進 revisions）")
    ed.add_argument("name")
    ed.add_argument("--description")
    ed.add_argument("--file")
    ed.add_argument("--kind", choices=["semantic", "episodic", "procedural", "decision", "environment"],
                    help="改分類（決定匯出索引的分組）")
    g = ed.add_mutually_exclusive_group()
    g.add_argument("--pin", action="store_true", help="設為常駐")
    g.add_argument("--unpin", action="store_true", help="取消常駐")
    ed.add_argument("--review-by", help="改到期覆核日（YYYY-MM-DD；傳 none 清除）")
    ed.add_argument("--reason", required=True)
    ed.set_defaults(fn=_cmd_edit)

    ln = sub.add_parser("learn", help="新增記憶 + 治理（supersedes/confirms/dup 偵測）")
    _common_write(ln)
    ln.add_argument("--supersedes", action="append", help="取代的舊記憶 id（可多次）")
    ln.add_argument("--confirms", action="append", help="確認的既有記憶 id，evidence_count+1（可多次）")
    ln.add_argument("--force", action="store_true", help="即使疑似重複也新增")
    ln.set_defaults(fn=_cmd_learn)

    fg = sub.add_parser("forget", help="標記記憶為 deprecated/invalid（不刪列）")
    fg.add_argument("name")
    fg.add_argument("--reason", required=True)
    fg.add_argument("--status", default="deprecated", choices=["deprecated", "invalid"])
    fg.set_defaults(fn=_cmd_forget)

    vf = sub.add_parser("verify", help="重新確認：last_verified=今天、順延 review_by")
    vf.add_argument("name")
    vf.add_argument("--method")
    vf.add_argument("--extend-days", type=int, default=90)
    vf.set_defaults(fn=_cmd_verify)

    sc = sub.add_parser("session-context", help="SessionStart hook 用（PG 不在時印提示、exit 0）")
    sc.add_argument("--cwd", help="覆寫 cwd（hook 從 stdin JSON 取，比行程 cwd 可靠）")
    sc.add_argument("--slug", help="直接指定 project slug（優先於 cwd；hook 從 transcript_path 取）")
    sc.set_defaults(fn=_cmd_session_context)

    lg = sub.add_parser("log", help="讀取/匯入存取遙測")
    lg.add_argument("--since")
    lg.add_argument("--import-tsv", help="一次性匯入舊的 memory-usage.tsv")
    lg.set_defaults(fn=_cmd_log)

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
