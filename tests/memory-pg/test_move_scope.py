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


# ---------- Task 7B：狀態機與續跑 ----------

PHASES = ["staged", "db_committed", "installed", "old_parked", "indexes_written"]


def _fail_after(phase: str):
    """在指定 phase 的 checkpoint【之後】拋錯——journal 已記到該 phase。回傳還原函式。

    **不用 monkeypatch.setattr + undo()**：`monkeypatch.undo()` 會撤銷該測試的【所有】
    monkeypatch，包含 conftest 的 `conn`/`home` fixture 釘住的 CLAUDE_HOME 與 DSN。
    實測 2026-08-26：續跑因此寫進【真實的】~/.claude/memory-work，而測試還「通過」——
    因為它在真實 home 裡找到了那個檔案。假通過比失敗更糟。
    """
    from memory_pg import move_state
    real = move_state._checkpoint

    def hook(jp, state):
        real(jp, state)
        if state["phase"] == phase:
            raise RuntimeError(f"模擬中斷於 {phase} 之後")
    move_state._checkpoint = hook
    return lambda: setattr(move_state, "_checkpoint", real)


def _fail_before(phase: str):
    """副作用已完成、journal 尚未更新時中斷——最容易被漏掉的形態。回傳還原函式。

    此時 journal 的 phase 落後一格，續跑若照 phase 盲目重做就會出事
    （例如再 rename 一次已經不存在的舊檔）。
    """
    from memory_pg import move_state
    real = move_state._checkpoint

    def hook(jp, state):
        if state["phase"] == phase:
            raise RuntimeError(f"模擬中斷於 {phase} 的 checkpoint 之前")
        real(jp, state)
    move_state._checkpoint = hook
    return lambda: setattr(move_state, "_checkpoint", real)


@pytest.mark.parametrize("phase", PHASES)
@pytest.mark.parametrize("mode", ["after", "before"])
def test_move_resumes_from_each_interrupt(conn, home: Path, phase, mode):
    """每個中斷點都要能續跑收斂，且連跑兩次冪等。"""
    seed_banks(home)
    n = f"mv-{phase}-{mode}"
    mutate.write(conn, _cfg(), name=n, scope="global", description="要搬的", body="\nb\n")
    conn.commit()
    from memory_pg import exporter
    exporter.run(conn, _cfg(), verify_dir=None)      # 讓舊檔真的存在，貼近 CLI 的實際流程
    restore = (_fail_after if mode == "after" else _fail_before)(phase)
    try:
        with pytest.raises(RuntimeError):
            move.run(conn, _cfg(), n, to_scope="work", project=None, clear_tags=False,
                     reason="測試")
    finally:
        restore()
    move.run(conn, _cfg(), n, to_scope="work", project=None, clear_tags=False, reason="測試")
    move.run(conn, _cfg(), n, to_scope="work", project=None, clear_tags=False, reason="測試")
    assert (home / "memory-work" / f"{n}.md").exists()
    assert not (home / "memory" / f"{n}.md").exists()
    assert not list((home / "memory").glob("*.move-old"))
    assert not list((home / "cache" / "move-scope").glob("*.json"))
    with conn.cursor() as cur:
        cur.execute("SELECT scope::text, file_path FROM memories WHERE name=%s", (n,))
        sc, fp = cur.fetchone()
    assert sc == "work" and str(home / "memory-work") in fp


def test_stale_staging_is_regenerated(conn, home: Path):
    """`.new` 的 hash 與現況不符時必須重產，不可沿用。"""
    from memory_pg import move_state
    seed_banks(home)
    mutate.write(conn, _cfg(), name="stale", scope="global", description="要搬的", body="\nb\n")
    conn.commit()
    (home / "memory-work" / "stale.md.new").write_text("過期內容", encoding="utf-8")
    jp = move_state.journal_path(_cfg(), "stale")
    jp.parent.mkdir(parents=True, exist_ok=True)
    jp.write_text(json.dumps({
        "name": "stale", "phase": "staged", "content_sha256": "0" * 64,
        "old_path": str(home / "memory" / "stale.md"),
        "new_path": str(home / "memory-work" / "stale.md"),
        "old_scope": "global", "new_scope": "work", "old_tags": [], "new_tags": [],
        "old_slug": None, "new_slug": None, "affected_banks": []}), encoding="utf-8")
    move.run(conn, _cfg(), "stale", to_scope="work", project=None, clear_tags=False, reason="x")
    assert "過期內容" not in (home / "memory-work" / "stale.md").read_text(encoding="utf-8")


def test_inconsistent_file_state_is_reported_not_guessed(conn, home: Path):
    """舊檔與 .move-old 同時存在 → 明確報錯，不猜測。"""
    from memory_pg import move_state
    seed_banks(home)
    mutate.write(conn, _cfg(), name="incon", scope="global", description="x", body="\nb\n")
    conn.commit()
    from memory_pg import exporter
    exporter.run(conn, _cfg(), verify_dir=None)          # 讓舊檔真的存在
    (home / "memory" / ("incon.md" + move_state.PARKED_SUFFIX)).write_text("另一份", encoding="utf-8")
    with pytest.raises(move.MoveError, match="inconsistent_state"):
        move.run(conn, _cfg(), "incon", to_scope="work", project=None,
                 clear_tags=False, reason="x")


def test_move_blocked_raises_with_all_blockers(conn, home: Path):
    seed_banks(home)
    mutate.write(conn, _cfg(), name="btgt", scope="global", description="目標", body="\nb\n")
    mutate.write(conn, _cfg(), name="bsrc", scope="global", description="來源",
                 body="\n見 [[btgt]]。\n")
    conn.commit()
    with pytest.raises(move.MoveError, match="bsrc"):
        move.run(conn, _cfg(), "btgt", to_scope="machine", project=None,
                 clear_tags=False, reason="x")
    with conn.cursor() as cur:
        cur.execute("SELECT scope::text FROM memories WHERE name='btgt'")
        assert cur.fetchone()[0] == "global"          # 完全沒動


# ---------- Task 7C：CLI ----------

def test_cli_move_scope_end_to_end(conn, home: Path, monkeypatch):
    from memory_pg import cli, exporter
    _seed_projects(conn, home)
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mv-cli", scope="global", description="要搬的",
                 body="\nb\n", tags=["D--Projects-IntelliPark"])
    conn.commit()
    exporter.run(conn, _cfg(), verify_dir=None)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["move-scope", "mv-cli", "--to", "machine", "--reason", "本機事實"]) == 0
    assert (home / "memory-machine" / "mv-cli.md").exists()
    assert not (home / "memory" / "mv-cli.md").exists()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memory_projects mp JOIN memories m ON m.id=mp.memory_id "
                    "WHERE m.name='mv-cli'")
        assert cur.fetchone()[0] == 0                 # machine 不得持有 tag
        cur.execute("SELECT reason FROM memory_revisions r JOIN memories m ON m.id=r.memory_id "
                    "WHERE m.name='mv-cli' ORDER BY r.id DESC LIMIT 1")
        reason = cur.fetchone()[0]
    assert "global" in reason and "D--Projects-IntelliPark" in reason   # 舊 scope 與舊 tag 都留痕


@pytest.mark.parametrize("argv,frag", [
    (["move-scope", "mv-cli", "--to", "project", "--reason", "x"], "--project"),
    (["move-scope", "mv-cli", "--to", "machine", "--project", "D--Projects-IntelliPark",
      "--reason", "x"], "不得給"),
    (["move-scope", "nonexistent", "--to", "work", "--reason", "x"], "找不到"),
])
def test_cli_move_scope_usage_errors(conn, home: Path, monkeypatch, capsys, argv, frag):
    from memory_pg import cli
    _seed_projects(conn, home)
    seed_banks(home)
    mutate.write(conn, _cfg(), name="mv-cli", scope="global", description="x", body="\nb\n")
    conn.commit()
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(argv) == 1
    assert frag in capsys.readouterr().err


def test_cli_move_scope_prints_every_blocker(conn, home: Path, monkeypatch, capsys):
    """inbound blocker 要逐條列出，不是只印第一條。"""
    from memory_pg import cli
    seed_banks(home)
    mutate.write(conn, _cfg(), name="btgt", scope="global", description="目標", body="\nb\n")
    for i in (1, 2):
        mutate.write(conn, _cfg(), name=f"bsrc{i}", scope="global", description=f"來源{i}",
                     body="\n見 [[btgt]]。\n")
    conn.commit()
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["move-scope", "btgt", "--to", "machine", "--reason", "x"]) == 1
    err = capsys.readouterr().err
    assert "bsrc1" in err and "bsrc2" in err


def test_cli_move_scope_noop_is_success(conn, home: Path, monkeypatch):
    from memory_pg import cli
    seed_banks(home)
    mutate.write(conn, _cfg(), name="same", scope="global", description="x", body="\nb\n")
    conn.commit()
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["move-scope", "same", "--to", "global", "--reason", "x"]) == 0


def test_cli_move_scope_clear_tags(conn, home: Path, monkeypatch):
    """project → work 加 --clear-tags 時不保留 affinity。"""
    from memory_pg import cli, exporter
    _seed_projects(conn, home)
    seed_banks(home)
    mutate.write(conn, _cfg(), name="ct", scope="project", description="專案的", body="\nb\n",
                 project_slug="D--Projects-IntelliPark")
    conn.commit()
    exporter.run(conn, _cfg(), verify_dir=None)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["move-scope", "ct", "--to", "work", "--clear-tags", "--reason", "x"]) == 0
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memory_projects mp JOIN memories m ON m.id=mp.memory_id "
                    "WHERE m.name='ct'")
        assert cur.fetchone()[0] == 0


def test_cli_move_project_to_work_keeps_affinity(conn, home: Path, monkeypatch):
    """不給 --clear-tags 時，原 home project 要被保留成 tag（維持常駐注入範圍）。"""
    from memory_pg import cli, exporter
    _seed_projects(conn, home)
    seed_banks(home)
    mutate.write(conn, _cfg(), name="keep", scope="project", description="專案的", body="\nb\n",
                 project_slug="D--Projects-IntelliPark")
    conn.commit()
    exporter.run(conn, _cfg(), verify_dir=None)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["move-scope", "keep", "--to", "work", "--reason", "跨專案"]) == 0
    with conn.cursor() as cur:
        cur.execute("SELECT p.slug FROM memory_projects mp JOIN memories m ON m.id=mp.memory_id "
                    "JOIN projects p ON p.id=mp.project_id WHERE m.name='keep'")
        assert [r[0] for r in cur.fetchall()] == ["D--Projects-IntelliPark"]
