"""audit — 記憶庫健全性檢查（PG 後端）。

輸出契約沿用 memory.sh：WARN → stderr 且 exit 1；SUGGEST / INFO → stdout（不影響 exit code）。
每行格式 `WARN|SUGGEST|INFO <path|-> : <code> <detail>`，讓 hook 的 grep -F "$BANK/" 仍能過濾。

檢查分兩類來源：
  * DB 內可判定的：overdue / dangling_ref / relation_mismatch / orphan / split_candidate / dup_candidate。
  * 需比對 bank 檔案的：export_drift / index_drift / index_missing / unmanaged_file / index_over_budget
    —— 借 exporter 的 verify 產物翻譯，不重寫一份比對邏輯。
  * CLAUDE.md：claude_md_dangling。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import psycopg

from . import exporter
from . import projects as projmod
from .config import Config

DUP_JACCARD = 0.35
DUP_DESC_CAP = 300
SPLIT_BYTES = 3072
SPLIT_PARAS = 4


@dataclass
class Finding:
    level: str      # WARN | SUGGEST | INFO
    path: str       # bank 路徑或 '-'
    code: str
    detail: str = ""

    def line(self) -> str:
        return f"{self.level} {self.path}: {self.code}{(' ' + self.detail) if self.detail else ''}"


@dataclass
class AuditReport:
    findings: list[Finding] = field(default_factory=list)

    @property
    def has_warn(self) -> bool:
        return any(f.level == "WARN" for f in self.findings)


def _bigrams(s: str) -> set[str]:
    s = s[:DUP_DESC_CAP]
    return {s[i:i + 2] for i in range(len(s) - 1)} if len(s) >= 2 else ({s} if s else set())


def _bank_of(file_path: str) -> str:
    return file_path.rsplit("\\", 1)[0] if "\\" in file_path else file_path.rsplit("/", 1)[0]


def run(conn: psycopg.Connection, cfg: Config) -> AuditReport:
    rep = AuditReport()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories")
        n_mem = cur.fetchone()[0]
        cur.execute("SELECT count(DISTINCT coalesce(home_project_id::text,'g')) FROM memories")
        n_banks = cur.fetchone()[0]
    rep.findings.append(Finding("INFO", "-", "banks", str(n_banks)))
    rep.findings.append(Finding("INFO", "-", "memories", str(n_mem)))

    with conn.cursor() as cur:
        # overdue（WARN）—— review_by 嚴格小於今天
        cur.execute(
            "SELECT file_path, name, review_by FROM memories "
            "WHERE status='active' AND review_by IS NOT NULL AND review_by < current_date ORDER BY name"
        )
        for fp, name, rb in cur.fetchall():
            rep.findings.append(Finding("WARN", fp, "overdue", f"{name} review_by={rb}"))

        # dangling_ref / forbidden_ref（WARN）
        #
        # 兩者在 DB 裡長得一樣（target_id IS NULL），但意思完全不同，要分開報：
        #   dangling_ref  目標**不存在**——打錯字，或引用了還沒寫的記憶
        #   forbidden_ref 目標**存在，但這個方向不允許**（跨 repo / 跨專案）
        # 非撰寫路徑（backfill、import）刻意把後者留成 dangling 而不拋錯（拋錯會讓
        # 「B 專案建不了 foo，只因為 A 專案有一條過期的 [[foo]]」這種附帶損害發生），
        # 資訊由這裡承接——責任歸在真正該改的來源記憶身上。
        cur.execute(
            """SELECT s.file_path, s.name, l.kind::text, l.target_name,
                      t.scope::text AS tscope, s.scope::text AS sscope
               FROM memory_links l
               JOIN memories s ON s.id = l.source_id
               LEFT JOIN memories t ON t.name = l.target_name AND t.status = 'active'
               WHERE l.target_id IS NULL ORDER BY s.name, l.target_name"""
        )
        for fp, name, kind, tgt, tscope, sscope in cur.fetchall():
            ref = f"[[{tgt}]]" if kind == "wikilink" else f"{kind}={tgt}"
            if tscope is None:
                rep.findings.append(Finding("WARN", fp, "dangling_ref", f"{ref} in {name}"))
            else:
                rep.findings.append(Finding(
                    "WARN", fp, "forbidden_ref",
                    f"{ref} in {name}：{tgt} 的 scope 是 {tscope}，不允許從 {sscope} 連過去"
                    f"（改成純文字提及）"))

        # relation_mismatch（WARN）—— 觸發器平時擋住，這裡是最後防線（多重取代者/自我取代殘留）
        cur.execute(
            """SELECT s.file_path, s.name FROM memory_links l JOIN memories s ON s.id=l.source_id
               WHERE l.kind='supersedes' AND l.source_id=l.target_id"""
        )
        for fp, name in cur.fetchall():
            rep.findings.append(Finding("WARN", fp, "relation_mismatch", f"self_supersede {name}"))
        # 多重取代者：部分唯一索引平時擋住，但手改 DB 仍可能出現，audit 補查
        cur.execute(
            """SELECT t.file_path, t.name, count(*) FROM memory_links l JOIN memories t ON t.id=l.target_id
               WHERE l.kind='supersedes' GROUP BY t.file_path, t.name HAVING count(*) > 1"""
        )
        for fp, name, c in cur.fetchall():
            rep.findings.append(Finding("WARN", fp, "relation_mismatch", f"multiple_superseders {name} x{c}"))

        # orphan（SUGGEST）—— 無 inbound link 且非 pin
        cur.execute(
            """SELECT m.file_path, m.name FROM memories m
               WHERE m.status='active' AND NOT m.pinned
                 AND NOT EXISTS (SELECT 1 FROM memory_links l WHERE l.target_id = m.id)
               ORDER BY m.name"""
        )
        orphans = cur.fetchall()
        for fp, name in orphans:
            rep.findings.append(Finding("SUGGEST", fp, "orphan", f"{name} no_inbound_link_and_not_pinned"))
        rep.findings.append(Finding("INFO", "-", "orphan_total", str(len(orphans))))

        # work 的 tag 規則（work 的常駐只有一條路徑：被 tag 的專案索引）
        cur.execute(
            """SELECT file_path, name, pinned FROM memories m
               WHERE m.status='active' AND m.scope='work'
                 AND NOT EXISTS (SELECT 1 FROM memory_projects mp WHERE mp.memory_id=m.id)
               ORDER BY name"""
        )
        for fp, name, pinned in cur.fetchall():
            if pinned:
                # memory-work/MEMORY.md 刻意不產 PINNED 區（沒有任何常駐 include 會載入它），
                # 所以 untagged 的 work 就算 pin 了也不會常駐——那是會誤導人的狀態。
                rep.findings.append(Finding(
                    "WARN", fp, "pinned_work_without_tag",
                    f"{name} 是 pinned 的 work 卻沒有 tag，實際不會常駐。"
                    f"要常駐就至少標一個 project，否則取消 pin"))
            else:
                rep.findings.append(Finding(
                    "SUGGEST", fp, "work_without_tag",
                    f"{name} 是 work 卻沒有 tag，通常表示它其實該放 global，或忘了標專案"))

        # split_candidate（SUGGEST）
        cur.execute(
            "SELECT file_path, name, octet_length(body) b, para_count FROM memories "
            f"WHERE status='active' AND octet_length(body) > {SPLIT_BYTES} AND para_count >= {SPLIT_PARAS} ORDER BY name"
        )
        for fp, name, b, paras in cur.fetchall():
            rep.findings.append(Finding("SUGGEST", fp, "split_candidate", f"{name} bytes={b} paras={paras}"))

        # dup_candidate（SUGGEST）—— 同 scope+home 內 description 的 2-gram Jaccard ≥ 門檻
        cur.execute(
            "SELECT file_path, name, description, scope::text, coalesce(home_project_id::text,'g') grp "
            "FROM memories WHERE status='active'"
        )
        rows = cur.fetchall()
    groups: dict[str, list[tuple]] = {}
    for fp, name, desc, scope, grp in rows:
        groups.setdefault(grp, []).append((fp, name, _bigrams(desc)))
    dup_pairs = 0
    for grp, items in groups.items():
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                a, b = items[i][2], items[j][2]
                if not a or not b:
                    continue
                jac = len(a & b) / len(a | b)
                if jac >= DUP_JACCARD:
                    dup_pairs += 1
                    rep.findings.append(Finding("SUGGEST", items[i][0], "dup_candidate",
                                                f"{items[i][1]} ~ {items[j][1]} jaccard={jac:.2f}"))
    rep.findings.append(Finding("INFO", "-", "dup_pairs", str(dup_pairs)))

    # drift 家族：借 exporter verify
    vdir = cfg.home / "cache" / "memory-audit-verify"
    try:
        vrep = exporter.run(conn, cfg, verify_dir=vdir)
        for d in vrep.diffs:
            if d.status == "differ":
                rep.findings.append(Finding("WARN", str(_bank_of(str(d.path))), "index_drift", str(d.path)))
            elif d.status == "missing_in_bank":
                rep.findings.append(Finding("WARN", str(_bank_of(str(d.path))), "index_missing", str(d.path)))
            elif d.status == "index_pinned_differ":
                rep.findings.append(Finding("WARN", str(_bank_of(str(d.path))), "index_drift", str(d.path)))
            elif d.status == "unmanaged":
                rep.findings.append(Finding("WARN", str(_bank_of(str(d.path))), "unmanaged_file", str(d.path)))
        for w in vrep.warnings:
            rep.findings.append(Finding("WARN", "-", "index_over_budget", w))
    except exporter.ExportAborted as e:
        rep.findings.append(Finding("WARN", "-", "unmanaged_file", str(e)))

    # bank 內的 wikilink 方向複驗（防手改 bank 繞過 DB 觸發器）
    _bank_link_directions(conn, cfg, rep)

    # claude_md_dangling
    _claude_md(conn, cfg, rep)
    return rep


def _bank_link_directions(conn: psycopg.Connection, cfg: Config, rep: AuditReport) -> None:
    """直接讀 bank 的 md，檢查正文裡的 wikilink 方向是否合法。

    DB 觸發器擋得住經由 CLI 的寫入，擋不住有人直接編輯 bank 檔案（Obsidian、手改）。
    那些改動要到下一次 import 才會進 DB，而 import 對禁止方向是留 dangling 不 abort
    ——所以在此之前，唯一會發聲的就是這條檢查。
    """
    from . import bank as bankmod
    from . import frontmatter as fm

    with conn.cursor() as cur:
        cur.execute("SELECT name, scope::text, home_project_id FROM memories WHERE status='active'")
        by_name = {r[0]: (r[1], r[2]) for r in cur.fetchall()}
        cur.execute("SELECT slug, id FROM projects")
        pid_of = dict(cur.fetchall())

    banks, _rej = bankmod.discover(cfg.home)
    for b in banks:
        slug = projmod.slug_from_bank(b)
        if b == cfg.bank_global:
            s_scope, s_home = "global", None
        elif b == cfg.bank_machine:
            s_scope, s_home = "machine", None
        elif b == cfg.bank_work:
            s_scope, s_home = "work", None
        else:
            s_scope, s_home = "project", pid_of.get(slug)
        for f in sorted(b.glob("*.md")):
            if f.name == "MEMORY.md" or f.name.startswith("."):
                continue
            try:
                text = f.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for m in fm.WIKILINK_RE.finditer(text):
                tgt = m.group(1)
                if tgt not in by_name or tgt == f.stem:
                    continue                      # 不存在的交給 dangling_ref 那條
                t_scope, t_home = by_name[tgt]
                with conn.cursor() as cur:
                    cur.execute("SELECT link_allowed(%s::memory_scope, %s::uuid, "
                                "%s::memory_scope, %s::uuid, 'wikilink')",
                                (s_scope, s_home, t_scope, t_home))
                    if not cur.fetchone()[0]:
                        rep.findings.append(Finding(
                            "WARN", str(f), "cross_repo_link",
                            f"[[{tgt}]] in {f.stem}：{tgt} 的 scope 是 {t_scope}，"
                            f"不允許從 {s_scope} 連過去"))


def _claude_md(conn: psycopg.Connection, cfg: Config, rep: AuditReport) -> None:
    import re

    p = cfg.home / "CLAUDE.md"
    if not p.is_file():
        return
    try:
        text = p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        rep.findings.append(Finding("WARN", str(p), "claude_md_unreadable"))
        return
    refs = set(re.findall(r"`memory\s+([A-Za-z0-9_][A-Za-z0-9._-]*)`", text))
    refs |= set(re.findall(r"memory\s+`([A-Za-z0-9_][A-Za-z0-9._-]*)`", text))
    # 排除子命令名：`memory search`、`memory write` 等是指令引用，不是「引用某則記憶」。
    SUBCOMMANDS = {"search", "write", "edit", "learn", "forget", "verify", "audit", "index",
                   "export", "import", "embed", "eval", "doctor", "migrate", "log", "project",
                   "session-context", "backup"}
    refs -= SUBCOMMANDS
    if not refs:
        return
    with conn.cursor() as cur:
        cur.execute("SELECT name FROM memories WHERE scope='global'")
        globals_ = {r[0] for r in cur.fetchall()}
    for r in sorted(refs - globals_):
        rep.findings.append(Finding("WARN", str(p), "claude_md_dangling", r))
