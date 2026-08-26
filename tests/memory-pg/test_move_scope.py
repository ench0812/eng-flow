"""move-scope 的規劃、狀態機與 CLI。

搬 scope 等同搬 repo：DB、兩側檔案、受影響的索引都要一起動，而且每個中斷點都要能續跑。
"""

from __future__ import annotations

import io
import json
import shutil
import sys
from pathlib import Path

import pytest

from conftest import seed_banks, write_memory  # noqa: E402

from memory_pg import config, importer, move, mutate  # noqa: E402


def _cfg():
    return config.load(use_test_db=True)


def _seed_projects(conn, home: Path):
    for slug in ("D--Projects-IntelliPark", "D--Projects-pcpms-car-navigator"):
        (home / "projects" / slug / "memory").mkdir(parents=True, exist_ok=True)
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()


TAG_CASES = [
    ("global",  "machine", False, []),
    ("global",  "project", False, []),
    ("global",  "work",    False, ["D--Projects-IntelliPark"]),
    ("work",    "global",  False, ["D--Projects-IntelliPark"]),
    ("project", "work",    False, ["D--Projects-IntelliPark"]),
    ("project", "global",  False, ["D--Projects-IntelliPark"]),
    ("project", "work",    True,  []),
]


@pytest.mark.parametrize("frm,to,clear,expect", TAG_CASES)
def test_plan_tag_rules(conn, home: Path, frm, to, clear, expect):
    _seed_projects(conn, home)
    seed_banks(home)
    kw = {"project_slug": "D--Projects-IntelliPark"} if frm == "project" else {}
    tags = [] if frm in ("machine", "project") else ["D--Projects-IntelliPark"]
    mutate.write(conn, _cfg(), name="t1", scope=frm, description="測 tag 規則",
                 body="\nb\n", tags=tags, **kw)
    conn.commit()
    p = move.plan(conn, _cfg(), "t1", to_scope=to,
                  project=("D--Projects-IntelliPark" if to == "project" else None),
                  clear_tags=clear)
    assert p.blockers == [], p.blockers
    assert sorted(p.new_tags) == sorted(expect)


def test_plan_computes_paths(conn, home: Path):
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mv1", scope="global", description="要搬的", body="\nb\n")
    conn.commit()
    p = move.plan(conn, _cfg(), "mv1", to_scope="machine", project=None, clear_tags=False)
    assert (p.old_scope, p.new_scope) == ("global", "machine")
    assert Path(p.new_path).parent == home / "memory-machine"
    assert Path(p.old_path).parent == home / "memory"
    assert p.is_noop is False


def test_plan_lists_blocking_links_and_writes_nothing(conn, home: Path):
    """inbound blocker 要列出，且 plan 不得有任何寫入。"""
    seed_banks(home)
    mutate.write(conn, _cfg(), name="tgt", scope="global", description="目標", body="\nb\n")
    for i in (1, 2):
        mutate.write(conn, _cfg(), name=f"src{i}", scope="global", description=f"來源{i}",
                     body="\n見 [[tgt]]。\n")
    conn.commit()
    p = move.plan(conn, _cfg(), "tgt", to_scope="machine", project=None, clear_tags=False)
    assert any("src1" in b for b in p.blockers)
    assert any("src2" in b for b in p.blockers)          # 逐條列出，不是只報第一條
    with conn.cursor() as cur:
        cur.execute("SELECT scope::text FROM memories WHERE name='tgt'")
        assert cur.fetchone()[0] == "global"


def test_plan_lists_outbound_blocker(conn, home: Path):
    """outbound 也要看：搬動同時改變「它連出去」的判定。"""
    _seed_projects(conn, home)
    seed_banks(home)
    mutate.write(conn, _cfg(), name="w-t", scope="work", description="工作目標", body="\nb\n")
    mutate.write(conn, _cfg(), name="p-s", scope="project", description="專案來源",
                 body="\n見 [[w-t]]。\n", project_slug="D--Projects-IntelliPark")
    conn.commit()
    # project → work 允許；改成 machine 之後 machine → work 禁止
    p = move.plan(conn, _cfg(), "p-s", to_scope="machine", project=None, clear_tags=False)
    assert any("outbound" in b and "w-t" in b for b in p.blockers), p.blockers


@pytest.mark.parametrize("to,project,frag", [
    ("project", None, "--project"),
    ("machine", "D--Projects-IntelliPark", "不得給"),
    ("nonsense", None, "未知的目標 scope"),
])
def test_plan_project_arg_rules(conn, home: Path, to, project, frag):
    _seed_projects(conn, home)
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mv2", scope="global", description="x", body="\nb\n")
    conn.commit()
    p = move.plan(conn, _cfg(), "mv2", to_scope=to, project=project, clear_tags=False)
    assert any(frag in b for b in p.blockers), p.blockers


def test_plan_noop_same_scope(conn, home: Path):
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mv3", scope="global", description="x", body="\nb\n")
    conn.commit()
    p = move.plan(conn, _cfg(), "mv3", to_scope="global", project=None, clear_tags=False)
    assert p.is_noop is True and p.blockers == []


def test_plan_blocks_when_target_bank_not_installed(conn, home: Path):
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mv4", scope="global", description="x", body="\nb\n")
    conn.commit()
    shutil.rmtree(home / "memory-work")
    p = move.plan(conn, _cfg(), "mv4", to_scope="work", project=None, clear_tags=False)
    assert any("not_installed" in b for b in p.blockers), p.blockers


def test_plan_blocks_on_existing_different_target_file(conn, home: Path):
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mv5", scope="global", description="x", body="\nb\n")
    conn.commit()
    (home / "memory-work" / "mv5.md").write_text("不同的內容", encoding="utf-8")
    p = move.plan(conn, _cfg(), "mv5", to_scope="work", project=None, clear_tags=False)
    assert any("目標路徑已存在" in b for b in p.blockers), p.blockers


def test_plan_missing_memory(conn, home: Path):
    p = move.plan(conn, _cfg(), "nope", to_scope="work", project=None, clear_tags=False)
    assert any("找不到" in b for b in p.blockers)


def test_plan_affected_banks_include_tag_changes(conn, home: Path):
    """tag 有變動的專案 bank 也要重產索引，否則常駐注入會與 DB 不一致。"""
    _seed_projects(conn, home)
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mv6", scope="project", description="專案的", body="\nb\n",
                 project_slug="D--Projects-IntelliPark")
    conn.commit()
    p = move.plan(conn, _cfg(), "mv6", to_scope="work", project=None, clear_tags=False)
    assert home / "memory-work" in p.affected_banks
    assert (home / "projects" / "D--Projects-IntelliPark" / "memory") in p.affected_banks
