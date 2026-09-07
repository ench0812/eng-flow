"""專案 slug ↔ 路徑。

Claude Code 的 slug 規則：把絕對路徑中的 `:` 與路徑分隔符換成 `-`（`D:\\Projects\\IntelliPark`
→ `D--Projects-IntelliPark`）。反向是有損的（目錄名本身可含 `-`），所以反推時用檔案系統驗證：
在每一層嘗試把連續 token 以 `-` 接回去，取實際存在的那條路徑。找不到就回 None，由呼叫端決定。
"""

from __future__ import annotations

import os
from pathlib import Path, PureWindowsPath


def slug_from_path(p: str | Path) -> str:
    s = str(p)
    return s.replace(":", "-").replace("\\", "-").replace("/", "-")


def path_from_slug(slug: str) -> Path | None:
    if "--" not in slug:
        return None
    drive, rest = slug.split("--", 1)
    if len(drive) != 1 or not drive.isalpha():
        return None
    tokens = rest.split("-") if rest else []
    root = Path(f"{drive}:\\")
    if os.name != "nt":
        # WSL/Linux 上沒有磁碟機根；只回推路徑字串，不驗證存在
        return PureWindowsPath(f"{drive}:\\" + "\\".join(tokens))  # type: ignore[return-value]

    def dfs(cur: Path, i: int) -> Path | None:
        if i == len(tokens):
            return cur
        # 貪婪：先試最長的合併（含較多 '-'），找不到再縮短
        for j in range(len(tokens), i, -1):
            cand = cur / "-".join(tokens[i:j])
            if cand.is_dir():
                r = dfs(cand, j)
                if r is not None:
                    return r
        return None

    return dfs(root, 0)


def bank_path_for_slug(home: Path, slug: str) -> Path:
    return home / "projects" / slug / "memory"


def slug_from_bank(bank: Path) -> str | None:
    """`<home>/projects/<slug>/memory` → slug；全域庫回 None。"""
    if bank.name != "memory":
        return None
    parent = bank.parent
    if parent.parent.name == "projects":
        return parent.name
    return None
