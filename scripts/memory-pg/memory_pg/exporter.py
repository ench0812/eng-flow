"""export — 從 PostgreSQL 產生 Markdown bank（記憶檔 + MEMORY.md）。單向、可重跑、冪等。

記憶檔：frontmatter_raw 非 NULL → 原樣回寫（byte-for-byte）；否則 canonical。
MEMORY.md：PINNED 區塊格式與 memory.sh 的 render_index 相同；TOPICS 改為依 kind 自動產生。
--verify：寫到暫存目錄並與實際 bank 逐檔比對，不碰 bank。
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import psycopg

from .config import Config
from .errors import MemoryError_

KIND_ZH = {
    "environment": "環境現況",
    "decision": "裁定",
    "procedural": "程序",
    "episodic": "事件",
    "semantic": "事實",
    None: "（尚未分類）",
}
KIND_ORDER = ["decision", "procedural", "environment", "episodic", "semantic", None]
INDEX_BUDGET_LINES = 180
INDEX_BUDGET_BYTES = 22 * 1024


class ExportAborted(MemoryError_):
    code = "export_aborted"


@dataclass
class FileDiff:
    path: Path
    status: str       # same | differ | missing_in_bank | unmanaged | index_pinned_same | index_pinned_differ


@dataclass
class ExportReport:
    written: int = 0
    banks: int = 0
    diffs: list[FileDiff] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def memory_mismatches(self) -> list[FileDiff]:
        return [d for d in self.diffs if d.status in ("differ", "missing_in_bank", "unmanaged")]


def canonical_frontmatter(row: dict) -> str:
    """name, description, metadata:{node_type, type, originSessionId, modified, pin, review_by,
    supersedes, superseded_by} + extra。"""
    lines = ["---", f"name: {row['name']}", f"description: {row['description']}", "metadata: "]
    meta: list[tuple[str, str]] = []
    if row.get("node_type"):
        meta.append(("node_type", row["node_type"]))
    if row.get("legacy_type"):
        meta.append(("type", row["legacy_type"]))
    if row.get("origin_session_id"):
        meta.append(("originSessionId", row["origin_session_id"]))
    ts = row["updated_at"]
    meta.append(("modified", ts.strftime("%Y-%m-%dT%H:%M:%S.") + f"{ts.microsecond // 1000:03d}Z"))
    meta.append(("pin", "true" if row["pinned"] else "false"))
    if row.get("review_by"):
        meta.append(("review_by", row["review_by"].isoformat()))
    if row.get("supersedes"):
        meta.append(("supersedes", "[" + ", ".join(row["supersedes"]) + "]"))
    if row.get("superseded_by"):
        meta.append(("superseded_by", row["superseded_by"]))
    extra_meta = (row.get("extra_frontmatter") or {}).get("metadata") or {}
    for k, v in extra_meta.items():
        meta.append((k, v))
    for k, v in meta:
        lines.append(f"  {k}: {v}")
    extra_root = (row.get("extra_frontmatter") or {}).get("root") or {}
    for k, v in extra_root.items():
        lines.append(f"{k}: {v}")
    lines.append("---")
    return "\n".join(lines) + "\n"


def render_memory(row: dict, *, canonical: bool = False) -> str:
    fmr = row.get("frontmatter_raw")
    if fmr and not canonical:
        return fmr + row["body"]
    body = row["body"]
    if not body.startswith("\n") and body:
        body = "\n" + body
    return canonical_frontmatter(row) + body


_OPEN, _CLOSE = "（(", "）)"


def _split_at(d: str) -> tuple[int, int] | None:
    """回傳「標題／提要」的斷點索引；找不到安全斷點回 None。

    只認**括號外**的分隔符。舊版是「前 60 字內找分隔符，找不到就硬切第 60 字」，兩條路都會
    在括號中間斷開，索引行變成 `… → erro` ／ `r 5），review …` 這種讀不懂的東西（實測
    2026-08-26 的 codex-windowsapps-pwsh-blocked 與 site-rose-assets）。索引是每個 session
    都會載入的東西，寧可標題長一點，不要產生壞掉的尾巴。
    """
    depth = 0
    for i, ch in enumerate(d):
        if ch in _OPEN:
            depth += 1
        elif ch in _CLOSE:
            depth = max(0, depth - 1)
        elif depth == 0 and i > 0 and i <= 60:
            for sep in ("——", "—", "；", "：", "，"):
                if d.startswith(sep, i):
                    return i, len(sep)      # 長度一起回，呼叫端不必再認一次哪個是雙字元
        if i > 60:
            break
    return None


def _topic_line(name: str, description: str) -> str:
    d = description.strip()
    hit = _split_at(d)
    if hit is None:
        return f"- [{d}]({name}.md)"
    i, sep_len = hit
    return f"- [{d[:i]}]({name}.md) — {d[i + sep_len:].strip()}"


def render_index(pinned: list[dict], topics: list[dict]) -> str:
    out = ["# Memory Index", "", "<!-- PINNED:BEGIN -->"]
    for r in sorted(pinned, key=lambda r: r["name"].encode()):
        body = r["body"]
        if not body.endswith("\n"):
            body += "\n"
        out.append(f"<!-- PINNED:ITEM {r['name']} -->")
        out.append(body.rstrip("\n"))
    out.append("<!-- PINNED:END -->")
    out.append("")
    out.append("<!-- TOPICS:BEGIN -->")
    if not topics:
        out.append("主題：（尚未分類）")
    else:
        groups: dict[str | None, list[dict]] = {}
        for r in topics:
            groups.setdefault(r.get("kind"), []).append(r)
        for k in KIND_ORDER:
            if k not in groups:
                continue
            out.append(f"主題：{KIND_ZH[k]}")
            for r in sorted(groups[k], key=lambda r: r["name"].encode()):
                out.append(_topic_line(r["name"], r["description"]))
    out.append("<!-- TOPICS:END -->")
    out.append("")
    out.append('搜尋：`~/.claude/scripts/memory search "<關鍵字>"`')
    out.append("稽核：`~/.claude/scripts/memory audit`")
    return "\n".join(out) + "\n"


def _pinned_block(text: str) -> str:
    a = text.find("<!-- PINNED:BEGIN -->")
    b = text.find("<!-- PINNED:END -->")
    return text[a:b] if a >= 0 and b > a else ""


def _load(conn: psycopg.Connection) -> tuple[list[dict], dict[str, dict]]:
    with conn.cursor() as cur:
        cur.execute(
            """SELECT m.id, m.name, m.description, m.body, m.file_path, m.scope, m.home_project_id,
                      m.kind::text, m.legacy_type, m.status::text, m.pinned, m.review_by, m.origin_session_id,
                      m.node_type, m.frontmatter_raw, m.extra_frontmatter, m.updated_at,
                      p.slug, p.bank_path,
                      (SELECT array_agg(l.target_name ORDER BY l.target_name) FROM memory_links l
                        WHERE l.source_id = m.id AND l.kind = 'supersedes') AS supersedes,
                      (SELECT s.name FROM memory_links l JOIN memories s ON s.id = l.source_id
                        WHERE l.target_id = m.id AND l.kind = 'supersedes' LIMIT 1) AS superseded_by,
                      (SELECT array_agg(p2.slug) FROM memory_projects mp JOIN projects p2 ON p2.id = mp.project_id
                        WHERE mp.memory_id = m.id) AS tags
               FROM memories m LEFT JOIN projects p ON p.id = m.home_project_id
               ORDER BY m.name"""
        )
        cols = [d.name for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        cur.execute("SELECT id, slug, bank_path FROM projects ORDER BY slug")
        projects = {r[0]: {"id": r[0], "slug": r[1], "bank_path": r[2]} for r in cur.fetchall()}
    return rows, projects


def _atomic_write(path: Path, data: bytes) -> None:
    # 同目錄、唯一且排他建立的暫存檔（O_EXCL）。不用可推導的 .name.new.<pid>：能寫入 bank 的
    # 同帳號競爭者可預建成 symlink，讓寫入跟隨連結落到別處。mkstemp 以 O_CREAT|O_EXCL 開，
    # 命中既有 symlink 會直接失敗而非跟隨。
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.new.")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def run(conn: psycopg.Connection, cfg: Config, *, verify_dir: Path | None, canonical: bool = False) -> ExportReport:
    rep = ExportReport()
    rows, projects = _load(conn)

    def target_root(bank: Path) -> Path:
        if verify_dir is None:
            return bank
        rel = bank.relative_to(cfg.home)
        return verify_dir / rel

    # 分 bank
    by_bank: dict[Path, list[dict]] = {}
    for r in rows:
        bank = Path(r["bank_path"]) if r["bank_path"] else cfg.bank_global
        by_bank.setdefault(bank, []).append(r)
    # 沒有記憶但有 project 列的 bank 也要處理（產生空索引與否交由 scan 的「安靜」原則：不產生）
    all_banks = set(by_bank)
    all_banks.add(cfg.bank_global)
    rep.banks = len(by_bank)

    # 未認領檔案檢查（bank 內存在、DB 沒有）— 只對真正的 bank
    for bank, rs in by_bank.items():
        known = {r["name"] + ".md" for r in rs}
        if bank.is_dir():
            for f in bank.glob("*.md"):
                if f.name == "MEMORY.md" or f.name.startswith("."):
                    continue
                if f.name not in known:
                    rep.diffs.append(FileDiff(f, "unmanaged"))
    if verify_dir is None and any(d.status == "unmanaged" for d in rep.diffs):
        names = ", ".join(str(d.path) for d in rep.diffs if d.status == "unmanaged")
        raise ExportAborted(f"bank 內有未認領的檔案（未經 import）: {names}。先 memory import 認領，或移走它們。")

    # 全域 pinned 且有標籤 → 只進被標的專案索引；無標籤 → 進全域索引
    global_rows = by_bank.get(cfg.bank_global, [])
    global_pinned_untagged = [r for r in global_rows if r["pinned"] and r["status"] == "active" and not r["tags"]]
    global_pinned_tagged: dict[str, list[dict]] = {}
    for r in global_rows:
        if r["pinned"] and r["status"] == "active" and r["tags"]:
            for slug in r["tags"]:
                global_pinned_tagged.setdefault(slug, []).append(r)

    for bank, rs in by_bank.items():
        root = target_root(bank)
        root.mkdir(parents=True, exist_ok=True)
        for r in rs:
            data = render_memory(r, canonical=canonical).encode("utf-8", errors="surrogateescape")
            out = root / f"{r['name']}.md"
            if verify_dir is None:
                _atomic_write(out, data)
            else:
                out.write_bytes(data)
                actual = bank / f"{r['name']}.md"
                if not actual.exists():
                    rep.diffs.append(FileDiff(actual, "missing_in_bank"))
                else:
                    rep.diffs.append(FileDiff(actual, "same" if actual.read_bytes() == data else "differ"))
            rep.written += 1
        # index
        slug = rs[0]["slug"] if rs and rs[0]["slug"] else None
        pinned = [r for r in rs if r["pinned"] and r["status"] == "active"]
        if slug:
            pinned = pinned + global_pinned_tagged.get(slug, [])
        elif bank == cfg.bank_global:
            pinned = global_pinned_untagged
        topics = [r for r in rs if r["status"] == "active" and not r["pinned"]]
        idx = render_index(pinned, topics)
        blk = _pinned_block(idx)
        if len(blk.splitlines()) > INDEX_BUDGET_LINES or len(blk.encode()) > INDEX_BUDGET_BYTES:
            rep.warnings.append(f"index_over_budget {bank}: PINNED 區 {len(blk.splitlines())} 行 / {len(blk.encode())} bytes")
        idx_b = idx.encode("utf-8")
        out = root / "MEMORY.md"
        if verify_dir is None:
            _atomic_write(out, idx_b)
        else:
            out.write_bytes(idx_b)
            actual = bank / "MEMORY.md"
            if actual.exists():
                same = _pinned_block(actual.read_text(encoding="utf-8", errors="surrogateescape")) == blk
                rep.diffs.append(FileDiff(actual, "index_pinned_same" if same else "index_pinned_differ"))
            else:
                # 索引缺席是 index 狀態，不算記憶檔不一致（export 會補產生）
                rep.diffs.append(FileDiff(actual, "index_missing"))
    return rep
