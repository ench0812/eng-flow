"""bank 掃描 — memory.sh build_banks / build_model 的拒收規則移植。

任何一項拒收都會讓整批操作 fail closed（rejected 非空 → import/export 不得進行）：
跳掉的那則在下游等於不存在，而 export 會照著這份少了東西的 model 重寫 bank。
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path

CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")
INDEX_NAME = "MEMORY.md"


@dataclass
class BankScan:
    bank: Path
    files: list[Path] = field(default_factory=list)      # 合法來源
    rejected: list[tuple[str, str]] = field(default_factory=list)   # (code, path)


def _has_symlink_component(bank: Path, home: Path) -> bool:
    """路徑上任何一段是 symlink 就整個 bank 不收（逐段檢查，同 bank_is_safe）。"""
    p = bank
    while True:
        if p.is_symlink():
            return True
        if p == home or p.parent == p:
            return False
        p = p.parent


def discover(home: Path) -> tuple[list[Path], list[tuple[str, str]]]:
    """回傳 (banks, rejected)。順序：全域庫、各專案庫（依路徑排序）。"""
    banks: list[Path] = []
    rejected: list[tuple[str, str]] = []
    g = home / "memory"
    if g.is_dir():
        banks.append(g)
    projects = home / "projects"
    if projects.exists() and not projects.is_dir():
        rejected.append(("unreadable_bank", str(projects)))
    elif projects.is_dir():
        try:
            entries = sorted(projects.iterdir(), key=lambda x: str(x).encode())
        except OSError:
            rejected.append(("unreadable_bank", str(projects)))
            entries = []
        for d in entries:
            if not d.is_dir():
                continue
            if not os.access(d, os.R_OK | os.X_OK):
                rejected.append(("unreadable_bank", str(d)))
                continue
            b = d / "memory"
            if b.is_dir():
                banks.append(b)
    out: list[Path] = []
    for b in banks:
        if CONTROL_RE.search(str(b)):
            rejected.append(("control_char_in_path", str(b))); continue
        if _has_symlink_component(b, home):
            rejected.append(("symlinked_bank", str(b))); continue
        out.append(b)
    return out, rejected


def scan(bank: Path) -> BankScan:
    s = BankScan(bank=bank)
    if not os.access(bank, os.R_OK | os.X_OK):
        s.rejected.append(("unreadable_bank", str(bank)))
        return s
    try:
        entries = sorted(bank.iterdir(), key=lambda x: x.name.encode())
    except OSError:
        s.rejected.append(("unreadable_bank", str(bank)))
        return s
    for f in entries:
        base = f.name
        if not base.endswith(".md"):
            continue
        # 順序與 memory.sh 相同：symlink 先於 -f（壞掉的 symlink 既不是 -f 也不是 -e）
        if f.is_symlink():
            s.rejected.append(("symlinked_memory", str(f))); continue
        if not f.is_file():
            s.rejected.append(("not_regular_file", str(f))); continue
        if base == INDEX_NAME:
            continue                                  # 索引不是來源
        if base.lower() == INDEX_NAME.lower():
            s.rejected.append(("reserved_filename", str(f))); continue
        if base.startswith(".MEMORY.md."):
            continue                                  # 交易暫存/備份
        if base.startswith("."):
            s.rejected.append(("hidden_file", str(f))); continue
        if CONTROL_RE.search(base):
            s.rejected.append(("control_char_in_path", str(f))); continue
        s.files.append(f)
    return s
