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

from . import projects as projmod
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
    # bank 分類。skipped 是 not_installed——單 repo 機器（只 clone 通用 repo）是合法安裝，
    # 把它算成失敗會讓 export 永遠 exit 1，所以 skipped 不進 ok 的判定。
    written_banks: list[Path] = field(default_factory=list)
    skipped_banks: list[Path] = field(default_factory=list)
    partial_banks: list[Path] = field(default_factory=list)
    failed_banks: list[Path] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.partial_banks and not self.failed_banks

    @property
    def memory_mismatches(self) -> list[FileDiff]:
        return [d for d in self.diffs if d.status in ("differ", "missing_in_bank", "unmanaged")]


# 計畫與 codex 討論時用的名字；同一個型別，保留別名避免兩套稱呼。
ExportResult = ExportReport


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


def render_index(pinned: list[dict], topics: list[dict], *, with_pinned: bool = True) -> str:
    """with_pinned=False 用於 memory-work/MEMORY.md。

    工作庫不產 PINNED 區：沒有任何常駐 include 會載入它（通用 CLAUDE.md 不得相依工作 repo），
    產了只會讓人誤以為已常駐。要常駐就給 tag，由該專案的 MEMORY.md 載入。
    """
    out = ["# Memory Index", ""]
    if with_pinned:
        out.append("<!-- PINNED:BEGIN -->")
        for r in sorted(pinned, key=lambda r: r["name"].encode()):
            body = r["body"]
            if not body.endswith(chr(10)):
                body += chr(10)
            out.append(f"<!-- PINNED:ITEM {r['name']} -->")
            out.append(body.rstrip(chr(10)))
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


def _indexable(r: dict) -> bool:
    """這一列該不該進 MEMORY.md 的 PINNED 區。

    休眠（久未被想起而淡出）的記憶**不進索引，但 `.md` 照常匯出**。這個不對稱是刻意的：
    索引是被 autoMemory 全文載入的常駐成本，bank 裡的 `.md` 只在被 Read 時才有成本。
    **絕對不可以改成「跳過寫檔」**——`known` 集合（見 run() 的未認領檔案檢查）是從同一批
    rows 建的，跳過寫檔會讓那個 `.md` 落在 known 之外，下一次 export 直接 ExportAborted，
    整個匯出停擺。deprecated / superseded 現行也是「寫檔但不進索引」，這裡沿用同一條路。
    """
    return bool(r["pinned"]) and r["status"] == "active" and r["dormant_since"] is None


def _load(conn: psycopg.Connection) -> tuple[list[dict], dict[str, dict]]:
    with conn.cursor() as cur:
        cur.execute(
            """SELECT m.id, m.name, m.description, m.body, m.file_path, m.scope::text AS scope,
                      m.home_project_id,
                      m.kind::text, m.legacy_type, m.status::text, m.pinned, m.dormant_since,
                      m.review_by, m.origin_session_id,
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
    bank_scope: dict[Path, str] = {}
    for r in rows:
        # 四路：project 看 projects.bank_path，其餘三個 scope 各有固定的 bank。
        bank = Path(r["bank_path"]) if r["scope"] == "project" else cfg.bank_for_scope(r["scope"])
        by_bank.setdefault(bank, []).append(r)
        bank_scope[bank] = r["scope"]
    # 沒有記憶但有 project 列的 bank 也要處理（產生空索引與否交由 scan 的「安靜」原則：不產生）
    all_banks = set(by_bank)
    all_banks.add(cfg.bank_global)
    rep.banks = len(by_bank)

    # preflight：not_installed 的 bank 整個跳過且**不自動 mkdir**——自動重建會讓
    # 「repo 沒 clone」看起來像「bank 是空的」，接著 import 的 delete-absent 就會把
    # 那個 scope 的記憶當成「檔案都不見了」而刪掉。
    skipped: set[Path] = set()
    if verify_dir is None:
        for sc in ("global", "machine", "work"):
            b = cfg.bank_for_scope(sc)
            st = cfg.bank_presence(sc)
            if st == "not_installed":
                skipped.add(b)
                rep.skipped_banks.append(b)
            elif st != "installed":
                rep.failed_banks.append(b)
                rep.warnings.append(f"bank_{st} {b}")
    by_bank = {b: rs for b, rs in by_bank.items() if b not in skipped}

    # 被 tag 的專案即使自己沒有記憶，也要產索引——否則 tag 到該專案的 pinned 記憶
    # （global 或 work）就沒有載入路徑，常駐會靜默落空。
    #
    # **這裡刻意不濾 dormant**（與下面的 tagged_pinned 收集不同）：這一步決定的是「哪些
    # bank 要重新產生索引」，不是「索引裡放什麼」。把休眠的記憶排除在這裡，該專案就不會
    # 進 by_bank，它的 MEMORY.md 於是完全不重寫——舊索引原封不動留著那則已休眠的記憶，
    # 淡出在檔案上等於沒有發生。實際過濾在 tagged_pinned 那一步。
    for slug in {s for r in rows if r["pinned"] and r["status"] == "active"
                 and r["scope"] in ("global", "work") for s in (r["tags"] or [])}:
        proj = next((v for v in projects.values() if v["slug"] == slug), None)
        if proj and proj["bank_path"]:
            by_bank.setdefault(Path(proj["bank_path"]), [])

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

    # 有標籤的 pinned → 只進被標的專案索引；無標籤 → 進自己的庫索引（互斥不重複）。
    # 來源由 global 擴為 (global, work)：site-rose-* 這類案場記憶轉成 work 之後仍要常駐在
    # 被標的專案，否則 2026-08-26 建立的命中率改善會退步。
    tagged_pinned: dict[str, list[dict]] = {}
    untagged_pinned: dict[Path, list[dict]] = {}
    for r in rows:
        if not (_indexable(r) and r["scope"] in ("global", "work")):
            continue
        if r["tags"]:
            for slug in r["tags"]:
                tagged_pinned.setdefault(slug, []).append(r)
        else:
            untagged_pinned.setdefault(cfg.bank_for_scope(r["scope"]), []).append(r)

    for bank, rs in by_bank.items():
        root = target_root(bank)
        root.mkdir(parents=True, exist_ok=True)
        bank_written = 0
        bank_failed: list[str] = []
        for r in rs:
            data = render_memory(r, canonical=canonical).encode("utf-8", errors="surrogateescape")
            out = root / f"{r['name']}.md"
            if verify_dir is None:
                try:
                    _atomic_write(out, data)
                except OSError as e:
                    # 現行的原子性是【逐檔 rename】，不是整個 bank 同時切換：中途失敗會留下
                    # 部分更新的 bank，所以要能回報 partial，不可宣稱整 bank 原子。
                    bank_failed.append(f"{out}: {e}")
                    continue
                bank_written += 1
            else:
                out.write_bytes(data)
                actual = bank / f"{r['name']}.md"
                if not actual.exists():
                    rep.diffs.append(FileDiff(actual, "missing_in_bank"))
                else:
                    rep.diffs.append(FileDiff(actual, "same" if actual.read_bytes() == data else "differ"))
            rep.written += 1
        if verify_dir is None:
            if bank_failed and bank_written:
                rep.partial_banks.append(bank)
                rep.warnings.append(f"bank_partial {bank}: {len(bank_failed)} 個檔寫入失敗")
            elif bank_failed:
                rep.failed_banks.append(bank)
                rep.warnings.append(f"bank_failed {bank}: {bank_failed[0]}")
            else:
                rep.written_banks.append(bank)
        # index
        slug = rs[0]["slug"] if rs and rs[0]["slug"] else projmod.slug_from_bank(bank)
        pinned = [r for r in rs if _indexable(r)]
        if slug:
            pinned = pinned + tagged_pinned.get(slug, [])
        elif bank in untagged_pinned or bank_scope.get(bank) in ("global", "work"):
            pinned = untagged_pinned.get(bank, [])
        topics = [r for r in rs if r["status"] == "active" and r["dormant_since"] is None
                  and not r["pinned"]]
        # 工作庫不產 PINNED 區（沒有常駐載入路徑，見 render_index 的說明）
        idx = render_index(pinned, topics, with_pinned=bank != cfg.bank_work)
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
