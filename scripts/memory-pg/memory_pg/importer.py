"""import — 把 Markdown bank 匯入 PostgreSQL（單一交易，任何來源錯誤整批 abort、零寫入）。

流程：discover banks → scan（拒收規則）→ parse（awk 移植）→ 記憶體內建 model 並解析 link
→ 驗證取代關係（宣告值 vs 推導值）→ 交易寫入 → 呼叫端再跑 export --verify。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from importlib import resources
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb

from . import bank as bankmod
from . import db
from . import frontmatter as fm
from . import projects as projmod
from .config import Config
from .errors import MemoryError_


class ImportAborted(MemoryError_):
    code = "import_aborted"


@dataclass
class Item:
    bank: Path
    scope: str                  # 'global' | 'project'
    slug: str | None
    path: Path
    parsed: fm.Parsed
    kind: str | None = None
    # 解析後的關係
    wikilinks: list[tuple[str, str | None]] = field(default_factory=list)   # (target_name, resolved_name|None)
    supersedes: list[tuple[str, str | None]] = field(default_factory=list)


@dataclass
class ImportReport:
    banks: int = 0
    memories: int = 0
    projects: int = 0
    links: int = 0
    deleted: int = 0
    dry_run: bool = False
    warnings: list[str] = field(default_factory=list)


def _kinds() -> dict[str, str]:
    out: dict[str, str] = {}
    txt = resources.files("memory_pg").joinpath("kinds.tsv").read_text(encoding="utf-8")
    for line in txt.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        name, kind = line.split("\t", 1)
        out[name.strip()] = kind.strip()
    return out


def _parse_modified(v: str | None) -> datetime | None:
    if not v:
        return None
    try:
        s = v.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.fromisoformat(s)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def build_model(cfg: Config) -> tuple[list[Item], list[str]]:
    """回傳 (items, fatal_problems)。fatal 非空 → 呼叫端 abort。"""
    problems: list[str] = []
    banks, rejected = bankmod.discover(cfg.home)
    for code, path in rejected:
        problems.append(f"{code} {path}")
    kinds = _kinds()
    items: list[Item] = []
    seen_name: dict[str, Path] = {}
    for b in banks:
        s = bankmod.scan(b)
        for code, path in s.rejected:
            problems.append(f"{code} {path}")
        slug = projmod.slug_from_bank(b)
        scope = "global" if b == cfg.bank_global else "project"
        for f in s.files:
            # id 全域唯一（PG 為本體後，id 是 TSV/MCP/ wikilink 的鍵）。兩個 bank 同名不是
            # 「同一則記憶的兩份」而是碰撞——靜默 upsert 會讓後者覆寫前者的 scope/路徑/內容，
            # 兩個 key 指向同一 id。fail-closed 拒絕，不猜。
            if f.stem in seen_name:
                problems.append(f"duplicate_name {f.stem}: {seen_name[f.stem]} 與 {f}")
            seen_name[f.stem] = f
            p = fm.parse(f.stem, f.read_bytes())
            if p.errs:
                problems.append(f"malformed_frontmatter {f} [{','.join(p.errs)}]")
            items.append(Item(bank=b, scope=scope, slug=slug, path=f, parsed=p, kind=kinds.get(f.stem)))
    if problems:
        return items, problems

    # 名稱索引：(bank, name) → item；全域另建一份
    by_bank: dict[tuple[Path, str], Item] = {(it.bank, it.parsed.stem): it for it in items}
    global_bank = cfg.bank_global

    def resolve(it: Item, name: str) -> str | None:
        """同庫 → 全域庫；禁跨專案（與 memory-checks.awk resolve() 相同）。"""
        if (it.bank, name) in by_bank:
            return name
        if it.bank != global_bank and (global_bank, name) in by_bank:
            return name
        return None

    derived_supby: dict[tuple[Path, str], list[str]] = {}
    for it in items:
        for lid in it.parsed.links:
            it.wikilinks.append((lid, resolve(it, lid)))
        for old in it.parsed.supersedes:
            # 取代關係必須同庫（cross_bank 是 relation_mismatch，不是 dangling）
            if (it.bank, old) in by_bank:
                it.supersedes.append((old, old))
                derived_supby.setdefault((it.bank, old), []).append(it.parsed.stem)
            elif resolve(it, old):
                problems.append(f"relation_mismatch cross_bank {it.parsed.stem} supersedes {old}")
            else:
                problems.append(f"dangling_ref supersedes={old} in {it.parsed.stem}")
            if old == it.parsed.stem:
                problems.append(f"relation_mismatch self_supersede {it.parsed.stem}")

    # 宣告的 superseded_by 必須等於推導值（唯一的取代者）
    for it in items:
        declared = it.parsed.superseded_by
        derived = derived_supby.get((it.bank, it.parsed.stem), [])
        if len(derived) > 1:
            problems.append(f"relation_mismatch multiple_superseders {it.parsed.stem} <- {','.join(derived)}")
        elif declared and not derived:
            if resolve(it, declared) is None:
                problems.append(f"dangling_ref superseded_by={declared} in {it.parsed.stem}")
            else:
                problems.append(f"relation_mismatch missing_reverse supersedes on {declared} (declared by {it.parsed.stem})")
        elif derived and declared != derived[0]:
            problems.append(f"relation_mismatch missing_reverse superseded_by on {it.parsed.stem} (expected {derived[0]}, got '{declared}')")
    return items, problems


def _project_row(cfg: Config, slug: str) -> tuple[str, str, str]:
    root = projmod.path_from_slug(slug)
    root_s = str(root) if root else slug          # 反推不到就先放 slug，warning 交呼叫端
    return slug, root_s, str(projmod.bank_path_for_slug(cfg.home, slug))


def write(conn: psycopg.Connection, cfg: Config, items: list[Item], *, dry_run: bool,
          _report_out: dict | None = None) -> ImportReport:
    rep = ImportReport(dry_run=dry_run)
    if _report_out is not None:
        _report_out["rep"] = rep     # dry-run rollback 前把統計交出去
    banks_seen = {it.bank for it in items}
    rep.banks = len(banks_seen)
    # 也要為空的專案 bank 建 project 列（hook 對應用）
    all_banks, _ = bankmod.discover(cfg.home)
    with db.top_level_transaction(conn):
        with conn.cursor() as cur:
            proj_id: dict[str, str] = {}
            for b in all_banks:
                slug = projmod.slug_from_bank(b)
                if not slug:
                    continue
                s, root, bank_path = _project_row(cfg, slug)
                if root == slug:
                    rep.warnings.append(f"project {slug}: 反推不到 root_path，先以 slug 佔位，用 memory project set 修正")
                cur.execute(
                    """INSERT INTO projects(slug, root_path, bank_path) VALUES (%s, %s, %s)
                       ON CONFLICT (slug) DO UPDATE SET bank_path = EXCLUDED.bank_path
                       RETURNING id""",
                    (s, root, bank_path),
                )
                proj_id[s] = cur.fetchone()[0]
            rep.projects = len(proj_id)

            mem_id: dict[tuple[Path, str], str] = {}
            for it in items:
                p = it.parsed
                modified = _parse_modified(p.meta_extra.get("modified"))
                extra = {
                    "root": {k: v for k, v in p.root_extra.items()},
                    "metadata": {k: v for k, v in p.meta_extra.items()
                                 if k not in ("node_type", "originSessionId", "modified")},
                }
                cur.execute(
                    """INSERT INTO memories(
                         name, description, body, file_path, scope, home_project_id, kind, legacy_type,
                         pinned, review_by, valid_from, importance, confidence,
                         source_type, source_id, origin_session_id, node_type,
                         frontmatter_raw, extra_frontmatter, para_count, updated_at)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s, %s,%s,%s,%s,'high', 'import',%s,%s,%s, %s,%s,%s,%s)
                       ON CONFLICT (name) DO UPDATE SET
                         description = EXCLUDED.description, body = EXCLUDED.body,
                         file_path = EXCLUDED.file_path, scope = EXCLUDED.scope,
                         home_project_id = EXCLUDED.home_project_id,
                         kind = COALESCE(EXCLUDED.kind, memories.kind),
                         legacy_type = EXCLUDED.legacy_type, pinned = EXCLUDED.pinned,
                         review_by = EXCLUDED.review_by, origin_session_id = EXCLUDED.origin_session_id,
                         node_type = EXCLUDED.node_type, frontmatter_raw = EXCLUDED.frontmatter_raw,
                         extra_frontmatter = EXCLUDED.extra_frontmatter, para_count = EXCLUDED.para_count,
                         updated_at = EXCLUDED.updated_at
                       RETURNING id""",
                    (
                        p.stem, p.description, p.body_raw, str(it.path), it.scope,
                        proj_id.get(it.slug) if it.slug else None, it.kind, p.type_ or None,
                        p.pin == "true", p.review_by or None, modified or datetime.now(timezone.utc),
                        4 if p.pin == "true" else 3,
                        str(it.path), p.meta_extra.get("originSessionId"), p.meta_extra.get("node_type"),
                        p.frontmatter_raw, Jsonb(extra), p.paras, modified or datetime.now(timezone.utc),
                    ),
                )
                mem_id[(it.bank, p.stem)] = cur.fetchone()[0]
                # sources：重匯入時先清再寫，避免累積重複列
                cur.execute("DELETE FROM memory_sources WHERE memory_id = %s", (mem_id[(it.bank, p.stem)],))
                cur.execute(
                    "INSERT INTO memory_sources(memory_id, kind, ref, available) VALUES (%s,'import',%s,true)",
                    (mem_id[(it.bank, p.stem)], str(it.path)),
                )
                sid = p.meta_extra.get("originSessionId")
                if sid and it.slug:
                    tp = cfg.projects_dir / it.slug / f"{sid}.jsonl"
                    cur.execute(
                        "INSERT INTO memory_sources(memory_id, kind, ref, available) VALUES (%s,'session',%s,%s)",
                        (mem_id[(it.bank, p.stem)], str(tp), tp.exists()),
                    )
            rep.memories = len(mem_id)

            # links：先刪本批記憶的舊連結（觸發器會把被取代者還原），再依序重建
            ids = list(mem_id.values())
            cur.execute("DELETE FROM memory_links WHERE source_id = ANY(%s)", (ids,))
            global_bank = cfg.bank_global
            n = 0
            for it in items:
                src = mem_id[(it.bank, it.parsed.stem)]
                for tname, resolved in it.wikilinks:
                    tid = None
                    if resolved:
                        tid = mem_id.get((it.bank, resolved)) or mem_id.get((global_bank, resolved))
                    cur.execute(
                        """INSERT INTO memory_links(source_id, target_name, target_id, kind)
                           VALUES (%s,%s,%s,'wikilink') ON CONFLICT DO NOTHING""",
                        (src, tname, tid),
                    )
                    n += 1
                for tname, resolved in it.supersedes:
                    tid = mem_id.get((it.bank, resolved)) if resolved else None
                    cur.execute(
                        """INSERT INTO memory_links(source_id, target_name, target_id, kind)
                           VALUES (%s,%s,%s,'supersedes')""",
                        (src, tname, tid),
                    )
                    n += 1
            rep.links = n

            # 完整同步：import 是 bank→DB 的權威同步，不是只 upsert。已從 bank 刪除的記憶
            # （DB 有、這批沒有）必須在同一交易內刪掉，否則 export 會把它重新寫回 bank。
            # 前提成立：discover/scan 的任一拒收都已讓 build_model abort（problems 非空），
            # 走到這裡代表 bank 集合是完整的，delete-absent 才安全。
            kept = list(mem_id.values())
            cur.execute("DELETE FROM memories WHERE id <> ALL(%s)", (kept,))
            rep.deleted = cur.rowcount
        if dry_run:
            raise _DryRun()
    return rep


class _DryRun(Exception):
    pass


def run(conn: psycopg.Connection, cfg: Config, *, dry_run: bool) -> ImportReport:
    items, problems = build_model(cfg)
    if problems:
        raise ImportAborted("來源資料有誤，未寫入任何列:\n  " + "\n  ".join(problems))
    holder: dict[str, ImportReport] = {}
    try:
        return write(conn, cfg, items, dry_run=dry_run, _report_out=holder)
    except _DryRun:
        # dry-run 的統計要真實（含 projects/links/deleted），不能回一個空殼
        rep = holder.get("rep") or ImportReport()
        rep.dry_run = True
        return rep
