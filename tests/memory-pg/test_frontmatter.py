"""parser 單元測試 + 對 memory-model.awk 的差分測試。

差分測試的意義：Python parser 是 awk 的移植，兩者對同一輸入必須產生完全相同的 errs 集合。
awk 存在（Git Bash）就跑；不存在就 skip 並明講——不能靜默當成通過。
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "scripts" / "memory-pg"))

from memory_pg import frontmatter as fm  # noqa: E402

AWK = REPO / "scripts" / "memory-model.awk"
US = "\x1f"


def P(stem: str, text: str) -> fm.Parsed:
    return fm.parse(stem, text.encode("utf-8"))


GOOD = """---
name: good-one
description: 一句描述
metadata:
  node_type: memory
  type: project
  pin: true
  review_by: 2026-11-24
---

正文第一段，含 [[other-id]] 連結。

第二段。
"""


def test_good_parse():
    p = P("good-one", GOOD)
    assert p.ok, p.errs
    assert p.name == "good-one" and p.description == "一句描述"
    assert p.pin == "true" and p.review_by == "2026-11-24" and p.type_ == "project"
    assert p.meta_extra == {"node_type": "memory"}
    assert p.links == ["other-id"]
    # paras = 1 + 「空行→非空行」轉換次數；body 開頭的空行也算一次轉換（與 awk 同）
    assert p.paras == 3
    assert p.body_start == 10
    assert p.frontmatter_raw + p.body_raw == GOOD


def test_raw_roundtrip_crlf():
    text = GOOD.replace("\n", "\r\n")
    p = P("good-one", text)
    assert p.ok, p.errs
    assert p.frontmatter_raw + p.body_raw == text


@pytest.mark.parametrize(
    "stem,text,expected",
    [
        ("x", "", ["empty_file", "missing_name", "missing_description"]),
        ("x", "no frontmatter\n", ["missing_frontmatter", "missing_name", "missing_description"]),
        ("x", "\ufeff---\nname: x\n---\n", ["bom_not_allowed", "missing_name", "missing_description"]),
        ("x", "---\nname: x\ndescription: d\n", ["unterminated_frontmatter"]),
        ("x", "---\nname: x\ndescription: d\n\n---\n", ["blank_line_in_frontmatter"]),
        ("x", "---\nname: x\ndescription: d\n  pin: true\n---\n", ["indented_key_outside_metadata"]),
        ("x", "---\nname: x\ndescription: d\n   bad: 1\n---\n", ["bad_indent"]),
        ("x", "---\nname: x\ndescription: d\n???\n---\n", ["unparsable_line"]),
        ("x", "---\nname: x\ndescription: d\npin: true\n---\n", ["misplaced_key:pin"]),
        ("x", "---\nname: x\ndescription: d\nname: y\n---\n", ["duplicate_key:name"]),
        ("x", "---\nname: x\ndescription: \"quoted\"\n---\n", ["quoted_value:description", "missing_description"]),
        ("x", "---\nname: x\ndescription: |\n---\n", ["multiline_value:description", "missing_description"]),
        ("x", "---\nname: x\ndescription: d\nmetadata: nope\n---\n", ["metadata_must_be_mapping"]),
        ("x", "---\nname: x\ndescription: d\nmetadata:\n  pin: TRUE\n---\n", ["bad_pin:TRUE"]),
        ("x", "---\nname: x\ndescription: d\nmetadata:\n  review_by: 2026-02-30\n---\n", ["bad_review_by"]),
        ("x", "---\nname: x\ndescription: d\nmetadata:\n  supersedes: old\n---\n", ["array_expected:supersedes"]),
        ("x", "---\nname: x\ndescription: d\nmetadata:\n  supersedes: [a,,b]\n---\n", ["empty_array_element:supersedes"]),
        ("x", "---\nname: x\ndescription: d\nmetadata:\n  supersedes: [a\n---\n", ["unterminated_array:supersedes"]),
        ("x", "---\nname: x\ndescription: d\nmetadata:\n  pin: true\n  pin: false\n---\n", ["duplicate_key:pin"]),
        ("x", "---\nname: x\ndescription: d\nmetadata:\n  a: 1\nmetadata:\n  b: 2\n---\n", ["duplicate_key:metadata"]),
        ("x", "---\nname: y\ndescription: d\n---\n", ["name_stem_mismatch"]),
        ("bad id", "---\nname: bad id\ndescription: d\n---\n", ["bad_id"]),
        ("x", "---\nname: x\ndescription: d\n---\n<!-- PINNED:BEGIN -->\n", ["reserved_marker"]),
        ("x", "---\nname: x\ndescription: d\x01\n---\n", ["control_char:description", "missing_description"]),
        ("x", "---\nname: x\ndescription: d\n---\n[[a\x01b]]\n", ["control_char:link"]),
    ],
)
def test_error_codes(stem, text, expected):
    assert P(stem, text).errs == expected


def test_supersedes_list():
    p = P("x", "---\nname: x\ndescription: d\nmetadata:\n  supersedes: [a, b]\n---\n")
    assert p.ok and p.supersedes == ["a", "b"]


def test_paras_counting_matches_awk_rule():
    # awk：paras 起始 1；每次「空行→非空行」轉換 +1（開頭空行也算）
    p = P("x", "---\nname: x\ndescription: d\n---\n\n\na\n\nb\nc\n\n")
    assert p.paras == 3   # 轉換：(空→a)、(空→b)


# ---------- 差分測試 ----------

def _bash() -> str | None:
    for c in (r"C:\Program Files\Git\bin\bash.exe", "/usr/bin/bash", "bash"):
        if Path(c).exists() or c == "bash":
            return c
    return None


def _run_awk(files: list[Path], tmp: Path) -> dict[str, str]:
    """回傳 {stem: errs} —— awk 的 M 行第 15 欄。"""
    bash = _bash()
    if not bash or not AWK.exists():
        pytest.skip("找不到 bash 或 memory-model.awk，差分測試未執行")
    size = tmp / "sizes.txt"
    links = tmp / "links.txt"
    # 路徑轉成 Git Bash 形式（C:\x → /c/x），wc 與 awk 的 FILENAME 才一致
    def gb(p: Path) -> str:
        s = str(p).replace("\\", "/")
        if len(s) > 1 and s[1] == ":":
            s = "/" + s[0].lower() + s[2:]
        return s
    flist = " ".join(f"'{gb(f)}'" for f in files)
    cmd = (
        f"LC_ALL=C wc -c {flist} > '{gb(size)}'; "
        f"LC_ALL=C awk -v US=$'\\x1f' -v sizefile='{gb(size)}' -v linksfile='{gb(links)}' "
        f"-f '{gb(AWK)}' {flist}"
    )
    r = subprocess.run([bash, "-c", cmd], capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        pytest.skip(f"awk 執行失敗，差分測試未執行: {r.stderr[:200]}")
    out: dict[str, str] = {}
    for line in r.stdout.splitlines():
        cols = line.split(US)
        if cols and cols[0]:
            # awk 印 14 欄：bank id path name desc type pin review sup supby bytes paras body errs
            assert len(cols) == 14, f"awk 輸出欄數異常: {len(cols)}"
            out[cols[1]] = cols[13]
    return out


def _real_memory_files() -> list[Path]:
    home = Path(os.environ.get("CLAUDE_HOME") or Path.home() / ".claude")
    files = sorted((home / "memory").glob("*.md")) + sorted((home / "projects").glob("*/memory/*.md"))
    return [f for f in files if f.name != "MEMORY.md"]


def test_differential_real_memories(tmp_path: Path):
    files = _real_memory_files()
    if not files:
        pytest.skip("本機沒有記憶檔可比對")
    awk = _run_awk(files, tmp_path)
    mismatches = []
    for f in files:
        py = fm.errs_key(fm.parse(f.stem, f.read_bytes()))
        if py != awk.get(f.stem, "<absent>"):
            mismatches.append((f.name, py, awk.get(f.stem)))
    assert not mismatches, mismatches
    assert len(awk) == len(files)


def test_differential_synthetic(tmp_path: Path):
    cases = [
        ("s01", "---\nname: s01\ndescription: d\n"),
        ("s02", "---\nname: s02\ndescription: d\n\n---\n"),
        ("s03", "---\nname: s03\ndescription: d\n  pin: true\n---\n"),
        ("s04", "---\nname: s04\ndescription: d\n???\n---\n"),
        ("s05", "---\nname: s05\ndescription: d\npin: true\n---\n"),
        ("s06", "---\nname: s06\ndescription: d\nname: y\n---\n"),
        ("s07", "---\nname: s07\ndescription: \"q\"\n---\n"),
        ("s08", "---\nname: s08\ndescription: d\nmetadata: nope\n---\n"),
        ("s09", "---\nname: s09\ndescription: d\nmetadata:\n  pin: TRUE\n---\n"),
        ("s10", "---\nname: s10\ndescription: d\nmetadata:\n  review_by: 2026-02-30\n---\n"),
        ("s11", "---\nname: s11\ndescription: d\nmetadata:\n  supersedes: old\n---\n"),
        ("s12", "---\nname: s12\ndescription: d\nmetadata:\n  supersedes: [a,,b]\n---\n"),
        ("s13", "---\nname: zz\ndescription: d\n---\n"),
        ("s14", "---\nname: s14\ndescription: d\n---\n<!-- TOPICS:END -->\n"),
        ("s15", "---\r\nname: s15\r\ndescription: d\r\n---\r\nbody\r\n"),
        ("s16", "no fm\n"),
        ("s17", ""),
        ("s18", "---\nname: s18\ndescription: d\nmetadata:\n  a: 1\nmetadata:\n  b: 2\n---\n"),
        ("s19", "---\nname: s19\ndescription: d\n---\n\n\na\n\nb [[x]] [[y]]\n"),
        ("s20", "---\nname: s20\ndescription: d\nmetadata:\n  supersedes: [a\n---\n"),
    ]
    d = tmp_path / "bank"
    d.mkdir()
    files = []
    for stem, text in cases:
        f = d / f"{stem}.md"
        f.write_bytes(text.encode("utf-8"))
        files.append(f)
    awk = _run_awk(files, tmp_path)
    mismatches = []
    for f in files:
        py = fm.errs_key(fm.parse(f.stem, f.read_bytes()))
        if py != awk.get(f.stem, "<absent>"):
            mismatches.append((f.name, py, awk.get(f.stem)))
    assert not mismatches, mismatches
