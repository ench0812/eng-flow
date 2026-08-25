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

        # dangling_ref（WARN）
        cur.execute(
            """SELECT s.file_path, s.name, l.kind::text, l.target_name
               FROM memory_links l JOIN memories s ON s.id = l.source_id
               WHERE l.target_id IS NULL ORDER BY s.name, l.target_name"""
        )
        for fp, name, kind, tgt in cur.fetchall():
            detail = f"[[{tgt}]] in {name}" if kind == "wikilink" else f"{kind}={tgt} in {name}"
            rep.findings.append(Finding("WARN", fp, "dangling_ref", detail))

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

    # claude_md_dangling
    _claude_md(conn, cfg, rep)
    return rep


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
