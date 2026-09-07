from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "scripts" / "memory-pg"))

from memory_pg import bank, projects  # noqa: E402


def test_scan_rejections(tmp_path: Path):
    b = tmp_path / "memory"
    b.mkdir()
    (b / "MEMORY.md").write_text("# idx\n")
    (b / "good.md").write_text("---\nname: good\ndescription: d\n---\n")
    (b / ".hidden.md").write_text("x")
    (b / ".MEMORY.md.new.abc").write_text("x")   # 交易暫存，靜默略過
    (b / "dir.md").mkdir()                       # 名字像記憶的目錄
    expected = ["hidden_file", "not_regular_file"]
    # 大小寫變體只在大小寫敏感的檔案系統上構造得出來；Windows/macOS 預設下 memory.md 就是
    # MEMORY.md 同一個檔（寫入會覆蓋索引本身），所以要先探測
    probe = b / "probe.md"; probe.write_text("p")
    case_sensitive = not (b / "PROBE.md").exists()
    probe.unlink()
    if case_sensitive:
        (b / "memory.md").write_text("x")
        expected.append("reserved_filename")
    s = bank.scan(b)
    assert [f.name for f in s.files] == ["good.md"]
    assert sorted(c for c, _ in s.rejected) == sorted(expected)


@pytest.mark.skipif(os.name != "nt", reason="symlink 建立在 Windows 需權限；在 Linux 另測")
def test_scan_symlink_rejected(tmp_path: Path):
    b = tmp_path / "memory"
    b.mkdir()
    target = tmp_path / "real.md"
    target.write_text("---\nname: real\ndescription: d\n---\n")
    try:
        os.symlink(target, b / "link.md")
    except OSError:
        pytest.skip("無 symlink 權限")
    s = bank.scan(b)
    assert ("symlinked_memory", str(b / "link.md")) in s.rejected


def test_discover_layout(tmp_path: Path):
    (tmp_path / "memory").mkdir()
    (tmp_path / "projects" / "D--Projects-X" / "memory").mkdir(parents=True)
    (tmp_path / "projects" / "empty").mkdir()
    banks, rejected = bank.discover(tmp_path)
    assert banks == [tmp_path / "memory", tmp_path / "projects" / "D--Projects-X" / "memory"]
    assert rejected == []


def test_slug_roundtrip():
    assert projects.slug_from_path(r"D:\Projects\IntelliPark") == "D--Projects-IntelliPark"
    assert projects.slug_from_path(r"D:\Projects\pcpms-car-locator") == "D--Projects-pcpms-car-locator"
    assert projects.slug_from_bank(Path(r"C:\u\.claude\projects\D--Projects-X\memory")) == "D--Projects-X"
    assert projects.slug_from_bank(Path(r"C:\u\.claude\memory")) is None


@pytest.mark.skipif(os.name != "nt", reason="反推需要 Windows 磁碟機")
def test_path_from_slug_resolves_hyphenated_dirs(tmp_path: Path):
    # 用 tmp 建一個含連字號目錄的樹，驗證 DFS 貪婪合併
    drive = tmp_path.drive  # e.g. 'C:'
    if not drive:
        pytest.skip("tmp 無磁碟機")
    d = tmp_path / "a-b" / "c"
    d.mkdir(parents=True)
    slug = projects.slug_from_path(d)
    assert projects.path_from_slug(slug) == d
