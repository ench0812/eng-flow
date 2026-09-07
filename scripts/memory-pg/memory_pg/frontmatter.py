"""frontmatter parser — memory-model.awk 的逐條移植。

契約：對同一個檔案，本 parser 產生的 errs 集合必須與 awk 完全相同（tests 有差分測試釘住）。
原則同 awk：只接受宣告的行導向子集；不符形狀一律記 errs，**絕不猜測**。
未列出的既有欄位（node_type / originSessionId / modified 等）原樣接受並保留在 extra，
否則遷移會把既有記憶全部打成錯誤。

與 awk 的兩個刻意差異（不影響 errs）：
  * 額外保留 frontmatter_raw 與 body_raw 的原始文字（含 \\r），讓 export 能 byte-for-byte 還原。
  * 額外保留 root/metadata 的未知 key（awk 讀過即丟）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

ID_RE = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")
ROOT_KEY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
META_KEY_RE = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_]*):")
CONTROL_RE = re.compile(r"[\x01-\x1f]")
LINK_CONTROL_RE = re.compile(r"[\x01-\x08\x0b-\x1f]")
WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
RESERVED_RE = re.compile(r"<!-- (PINNED:(BEGIN|END|ITEM )|TOPICS:(BEGIN|END))")
GOVERNANCE_KEYS = {"pin", "supersedes", "superseded_by", "review_by", "type"}


@dataclass
class Parsed:
    stem: str
    name: str = ""
    description: str = ""
    type_: str = ""
    pin: str = "false"
    review_by: str = ""
    supersedes_raw: str = ""
    superseded_by: str = ""
    nbytes: int = 0
    paras: int = 1
    body_start: int = 1          # 1-based 行號，與 awk 同
    errs: list[str] = field(default_factory=list)
    links: list[str] = field(default_factory=list)
    # 以下為 awk 沒有的保留欄位
    root_extra: dict[str, str] = field(default_factory=dict)
    meta_extra: dict[str, str] = field(default_factory=dict)
    frontmatter_raw: str = ""    # 從第一個 --- 到結尾 --- 含換行，原樣
    body_raw: str = ""           # 結尾 --- 之後的全部，原樣

    @property
    def ok(self) -> bool:
        return not self.errs

    @property
    def supersedes(self) -> list[str]:
        """已通過 array_expected / empty_array_element 檢查後的元素清單。"""
        v = self.supersedes_raw.strip()
        if not (v.startswith("[") and v.endswith("]")):
            return []
        inner = v[1:-1].strip()
        return [x.strip() for x in inner.split(",")] if inner else []


def date_ok(d: str) -> bool:
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", d):
        return False
    y, m, dd = int(d[0:4]), int(d[5:7]), int(d[8:10])
    if m < 1 or m > 12 or dd < 1 or dd > 31:
        return False
    if m == 2:
        leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)
        if dd > (29 if leap else 28):
            return False
    elif m in (4, 6, 9, 11) and dd > 30:
        return False
    return True


def _check_value(p: Parsed, v: str, k: str) -> bool:
    if CONTROL_RE.search(v):
        p.errs.append(f"control_char:{k}"); return False
    if v.startswith(('"', "'")):
        p.errs.append(f"quoted_value:{k}"); return False
    if v in ("|", ">"):
        p.errs.append(f"multiline_value:{k}"); return False
    if v.startswith("[") and not v.endswith("]"):
        p.errs.append(f"unterminated_array:{k}"); return False
    return True


def parse(stem: str, data: bytes) -> Parsed:
    """stem = 檔名去 .md；data = 檔案原始 bytes。"""
    p = Parsed(stem=stem, nbytes=len(data))
    if len(data) == 0:
        # awk：零位元組檔一行都沒有，由 END 補上這組固定錯誤
        p.errs = ["empty_file", "missing_name", "missing_description"]
        return p

    text = data.decode("utf-8", errors="surrogateescape")
    # awk RS="\n"：最後一行沒有換行仍是一筆記錄
    raw_lines = text.split("\n")
    if raw_lines and raw_lines[-1] == "" and text.endswith("\n"):
        raw_lines.pop()

    state = "pre"
    in_meta = False
    seen: set[str] = set()
    blank = False
    has_reserved = False
    body_start = 0
    fm_end_idx = -1   # raw_lines 索引：結尾 --- 那一行

    def dupkey(k: str) -> bool:
        if k in seen:
            p.errs.append("duplicate_key:" + k[2:]); return True
        seen.add(k); return False

    for i, raw in enumerate(raw_lines):
        fnr = i + 1
        line = raw[:-1] if raw.endswith("\r") else raw   # CRLF 正規化，排在所有規則之前

        if fnr == 1:
            if line.startswith("﻿"):
                p.errs.append("bom_not_allowed"); state = "skip"; continue
            if line != "---":
                p.errs.append("missing_frontmatter"); state = "skip"; continue
            state = "fm"; continue

        if state == "skip":
            continue

        if state == "fm":
            if line == "---":
                state = "body"; body_start = fnr + 1; fm_end_idx = i; continue
            if line.strip() == "":
                p.errs.append("blank_line_in_frontmatter"); continue
            m = META_KEY_RE.match(line)
            if m:
                if not in_meta:
                    p.errs.append("indented_key_outside_metadata"); continue
                k = m.group(1)
                v = re.sub(r"^  [A-Za-z_][A-Za-z0-9_]*:[ \t\f\v]*", "", line)
                if not _check_value(p, v, k):
                    continue
                if dupkey("m:" + k):
                    continue
                if k == "supersedes" and not re.fullmatch(r"\[.*\]", v):
                    p.errs.append("array_expected:supersedes"); continue
                if k == "supersedes" and (
                    re.search(r",\s*,", v) or re.search(r"\[\s*,", v) or re.search(r",\s*\]", v)
                ):
                    p.errs.append("empty_array_element:supersedes"); continue
                if k == "type":
                    p.type_ = v
                elif k == "pin":
                    if v not in ("true", "false"):
                        p.errs.append("bad_pin:" + v); continue
                    p.pin = v
                elif k == "review_by":
                    p.review_by = v
                elif k == "supersedes":
                    p.supersedes_raw = v
                elif k == "superseded_by":
                    p.superseded_by = v
                else:
                    p.meta_extra[k] = v
                continue
            if re.match(r"^\s+", line):
                p.errs.append("bad_indent"); continue
            m = ROOT_KEY_RE.match(line)
            if m:
                k = m.group(1)
                v = re.sub(r"^[A-Za-z_][A-Za-z0-9_]*:[ \t\f\v]*", "", line)
                in_meta = k == "metadata"
                if in_meta:
                    if dupkey("r:metadata"):
                        continue
                    if v != "":
                        p.errs.append("metadata_must_be_mapping")
                    continue
                if not _check_value(p, v, k):
                    continue
                if dupkey("r:" + k):
                    continue
                if k in GOVERNANCE_KEYS:
                    p.errs.append("misplaced_key:" + k); continue
                if k == "name":
                    p.name = v
                elif k == "description":
                    p.description = v
                else:
                    p.root_extra[k] = v
                continue
            p.errs.append("unparsable_line")
            continue

        # state == "body"
        if line.strip() == "":
            blank = True
        elif blank:
            p.paras += 1; blank = False
        if RESERVED_RE.search(line):
            has_reserved = True
        for lm in WIKILINK_RE.finditer(line):
            lid = lm.group(1)
            if LINK_CONTROL_RE.search(lid):
                p.errs.append("control_char:link")
            else:
                p.links.append(lid)

    # flush()
    if state == "pre":
        p.errs.append("empty_file")
    elif state == "fm":
        p.errs.append("unterminated_frontmatter")
    if p.name == "":
        p.errs.append("missing_name")
    if p.description == "":
        p.errs.append("missing_description")
    if not ID_RE.match(stem):
        p.errs.append("bad_id")
    if p.name != "" and p.name != stem:
        p.errs.append("name_stem_mismatch")
    if p.review_by != "" and not date_ok(p.review_by):
        p.errs.append("bad_review_by")
    if has_reserved:
        p.errs.append("reserved_marker")
    p.body_start = body_start if body_start else 1

    # 原樣切片（給 export 用）：結尾 --- 行含其換行之前是 frontmatter_raw，之後是 body_raw
    if fm_end_idx >= 0:
        cut = sum(len(l) + 1 for l in raw_lines[: fm_end_idx + 1])
        # 若檔案最後一行沒有換行且那一行就是 ---，cut 會多 1
        cut = min(cut, len(text))
        p.frontmatter_raw = text[:cut]
        p.body_raw = text[cut:]
    else:
        p.frontmatter_raw = ""
        p.body_raw = text
    return p


def errs_key(p: Parsed) -> str:
    """給差分測試用：與 awk 的 errs 欄同格式（逗號串，順序即發現順序）。"""
    return ",".join(p.errs)
