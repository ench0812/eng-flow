from __future__ import annotations

import io
import shutil
import sys

from pathlib import Path

import pytest

from conftest import seed_banks, write_memory  # noqa: E402

from memory_pg import config, exporter, importer  # noqa: E402


def _cfg():
    return config.load(use_test_db=True)


def test_import_then_verify_is_lossless(conn, home: Path):
    g = home / "memory"
    p1 = home / "projects" / "D--Projects-X" / "memory"
    write_memory(g, "g-one", "全域一", pin="true", review_by="2026-12-31", node_type="memory",
                 modified="2026-08-24T03:20:00.000Z")
    write_memory(p1, "a-one", "專案 A 一", body="\n連到 [[g-one]] 與 [[a-two]]。\n\n第二段。\n", type="project")
    write_memory(p1, "a-two", "專案 A 二", body="\n[[nope]] dangling。\n")
    # CRLF 檔也要原樣回寫
    crlf = write_memory(p1, "a-crlf", "CRLF 檔")
    crlf.write_bytes(crlf.read_bytes().replace(b"\n", b"\r\n"))

    cfg = _cfg()
    rep = importer.run(conn, cfg, dry_run=False)
    conn.commit()
    assert rep.memories == 4 and rep.projects == 1

    with conn.cursor() as cur:
        cur.execute("SELECT name, scope::text, pinned, review_by::text, para_count FROM memories ORDER BY name")
        rows = cur.fetchall()
    assert ("g-one", "global", True, "2026-12-31", 1) in rows
    assert ("a-one", "project", False, None, 2) in rows
    with conn.cursor() as cur:
        cur.execute("SELECT target_name, target_id IS NOT NULL FROM memory_links WHERE kind='wikilink' ORDER BY target_name")
        links = cur.fetchall()
    assert links == [("a-two", True), ("g-one", True), ("nope", False)]

    vrep = exporter.run(conn, cfg, verify_dir=home / "cache" / "verify")
    statuses = {d.path.name: d.status for d in vrep.diffs if d.path.name != "MEMORY.md"}
    assert statuses == {"g-one.md": "same", "a-one.md": "same", "a-two.md": "same", "a-crlf.md": "same"}
    assert not vrep.memory_mismatches


def test_import_persists_across_connections(conn, home: Path, test_dsn: str):
    """回歸：寫入必須是頂層交易並 commit。同一連線內的驗證看得到、換連線就消失，正是實際踩過的坑。"""
    import psycopg

    write_memory(home / "memory", "persist-me", "要留下來")
    cfg = _cfg()
    # 先做一次讀取，製造「隱式交易已開啟」的前置狀態（模擬 CLI 的 assert_schema）
    with conn.cursor() as cur:
        cur.execute("SELECT 1")
    importer.run(conn, cfg, dry_run=False)
    conn.close()                       # 刻意不 commit
    with psycopg.connect(test_dsn) as c2, c2.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='persist-me'")
        assert cur.fetchone()[0] == 1


def test_import_aborts_on_malformed(conn, home: Path):
    write_memory(home / "memory", "ok-one", "好的")
    (home / "memory" / "bad-one.md").write_text("---\nname: bad-one\ndescription: d\npin: true\n---\n", encoding="utf-8")
    with pytest.raises(importer.ImportAborted) as e:
        importer.run(conn, _cfg(), dry_run=False)
    assert "misplaced_key:pin" in str(e.value)
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories")
        assert cur.fetchone()[0] == 0     # 零寫入


def test_duplicate_name_across_banks_aborts(conn, home: Path):
    # id 全域唯一：兩個 project bank 各有同名檔 → 碰撞，fail-closed 拒絕、零寫入
    write_memory(home / "projects" / "D--Projects-A" / "memory", "dup", "A 的 dup")
    write_memory(home / "projects" / "D--Projects-B" / "memory", "dup", "B 的 dup")
    with pytest.raises(importer.ImportAborted) as e:
        importer.run(conn, _cfg(), dry_run=False)
    assert "duplicate_name dup" in str(e.value)
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories")
        assert cur.fetchone()[0] == 0


def test_import_is_full_sync_deletes_absent(conn, home: Path):
    g = home / "memory"
    f_keep = write_memory(g, "keep", "留著")
    f_gone = write_memory(g, "gone", "會被刪")
    cfg = _cfg()
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories")
        assert cur.fetchone()[0] == 2
    # 刪掉一個檔案再匯入 → DB 內對應列必須消失（否則 export 會把它寫回 bank）
    f_gone.unlink()
    rep = importer.run(conn, cfg, dry_run=False)
    conn.commit()
    assert rep.deleted == 1
    with conn.cursor() as cur:
        cur.execute("SELECT name FROM memories")
        assert [r[0] for r in cur.fetchall()] == ["keep"]
    assert f_keep.exists()


def test_dry_run_reports_real_stats(conn, home: Path):
    g = home / "memory"
    write_memory(g, "d1", "一")
    write_memory(g, "d2", "二", body="\n[[d1]]\n")
    rep = importer.run(conn, _cfg(), dry_run=True)
    assert rep.dry_run and rep.memories == 2 and rep.links == 1 and rep.projects >= 0
    with conn.cursor() as cur:      # rollback：DB 仍空
        cur.execute("SELECT count(*) FROM memories")
        assert cur.fetchone()[0] == 0


def test_import_aborts_on_hidden_file(conn, home: Path):
    write_memory(home / "memory", "ok-one", "好的")
    (home / "memory" / ".sneaky.md").write_text("x")
    with pytest.raises(importer.ImportAborted) as e:
        importer.run(conn, _cfg(), dry_run=False)
    assert "hidden_file" in str(e.value)


def test_supersede_roundtrip_and_mismatch(conn, home: Path):
    g = home / "memory"
    write_memory(g, "old-fact", "舊事實", superseded_by="new-fact")
    write_memory(g, "new-fact", "新事實", supersedes="[old-fact]")
    cfg = _cfg()
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT name, status::text FROM memories ORDER BY name")
        assert cur.fetchall() == [("new-fact", "active"), ("old-fact", "superseded")]
    vrep = exporter.run(conn, cfg, verify_dir=home / "cache" / "verify")
    assert not vrep.memory_mismatches
    # 索引：已取代者不進 TOPICS
    idx = (home / "cache" / "verify" / "memory" / "MEMORY.md").read_text(encoding="utf-8")
    assert "old-fact.md" not in idx and "new-fact.md" in idx

    # 單邊宣告 → relation_mismatch → abort
    write_memory(g, "lonely", "只寫了 superseded_by", superseded_by="new-fact")
    with pytest.raises(importer.ImportAborted) as e:
        importer.run(conn, cfg, dry_run=False)
    assert "relation_mismatch missing_reverse supersedes on new-fact" in str(e.value)


def test_cross_project_wikilink_is_dangling_not_resolved(conn, home: Path):
    pa = home / "projects" / "D--Projects-A" / "memory"
    pb = home / "projects" / "D--Projects-B" / "memory"
    write_memory(pa, "a-mem", "A", body="\n[[b-mem]]\n")
    write_memory(pb, "b-mem", "B")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT target_id IS NULL FROM memory_links WHERE target_name='b-mem'")
        assert cur.fetchone()[0] is True


def test_index_render_pinned_and_tags(conn, home: Path):
    g = home / "memory"
    p1 = home / "projects" / "D--Projects-X" / "memory"
    write_memory(g, "g-pin", "全域 pin", pin="true")
    write_memory(p1, "x-pin", "X pin", pin="true")
    write_memory(p1, "x-plain", "X 普通——後半")
    cfg = _cfg()
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    # 把 g-pin 標到專案 X → 應只出現在 X 的索引、不在全域索引
    with conn.cursor() as cur:
        cur.execute("INSERT INTO memory_projects SELECT m.id, p.id FROM memories m, projects p WHERE m.name='g-pin' AND p.slug='D--Projects-X'")
    conn.commit()
    exporter.run(conn, cfg, verify_dir=home / "cache" / "verify")
    gidx = (home / "cache" / "verify" / "memory" / "MEMORY.md").read_text(encoding="utf-8")
    xidx = (home / "cache" / "verify" / "projects" / "D--Projects-X" / "memory" / "MEMORY.md").read_text(encoding="utf-8")
    assert "PINNED:ITEM g-pin" not in gidx and "PINNED:ITEM g-pin" in xidx
    assert "PINNED:ITEM x-pin" in xidx
    assert "- [X 普通](x-plain.md) — 後半" in xidx
    assert xidx.index("PINNED:ITEM g-pin") < xidx.index("PINNED:ITEM x-pin")   # name 排序


def test_export_refuses_unmanaged_file(conn, home: Path):
    g = home / "memory"
    write_memory(g, "known", "已知")
    cfg = _cfg()
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    (g / "stranger.md").write_text("---\nname: stranger\ndescription: 沒 import 過\n---\n", encoding="utf-8")
    with pytest.raises(exporter.ExportAborted):
        exporter.run(conn, cfg, verify_dir=None)
    assert (g / "stranger.md").exists()          # 沒被刪


@pytest.mark.parametrize("desc,expect_title,expect_hook", [
    # 括號外有分隔符 → 切成「標題 — 提要」
    ("gh token 缺 scope 會擋下 push——補授權要在一般終端機跑",
     "gh token 缺 scope 會擋下 push", "補授權要在一般終端機跑"),
    # 分隔符只出現在**全形**括號內 → 不可切。舊版硬切第 60 字，實測產出 "→ erro" / "r 5）"
    ("codex 在這台 Windows 上讀不了檔（WindowsApps 版 pwsh + 受限 token → error 5），review 只看得到 diff",
     "codex 在這台 Windows 上讀不了檔（WindowsApps 版 pwsh + 受限 token → error 5），review 只看得到 diff", None),
    # **半形**括號同樣要算深度（_OPEN/_CLOSE 兩種都涵蓋，之前零覆蓋）
    ("build fails on CI (missing env, see run 5), retry does not help and never will ever",
     "build fails on CI (missing env, see run 5), retry does not help and never will ever", None),
    # 括號外的「：」先出現 → 從那裡切，括號內的「、」不參與
    ("三重玫瑰案場的檔案資產：9 樓層、目錄樹（地圖包、專案檔、原始 CAD）",
     "三重玫瑰案場的檔案資產", "9 樓層、目錄樹（地圖包、專案檔、原始 CAD）"),
    # 邊界：分隔符落在 index 60（可切）與 61（不可切），這是 _split_at 唯一的 magic number
    ("x" * 60 + "，tail", "x" * 60, "tail"),
    ("x" * 61 + "，tail", "x" * 61 + "，tail", None),
    # 不平衡的右括號不可讓 depth 變負而吃掉後面的分隔符
    ("abc），def", "abc）", "def"),
    # 不平衡的左括號 → 整句當標題（找不到安全斷點）
    ("a（b，c", "a（b，c", None),
])
def test_topic_line_split_boundaries(desc, expect_title, expect_hook):
    line = exporter._topic_line("some-name", desc)
    head, sep, hook = line.partition(" — ")
    assert head.startswith("- [") and head.endswith("](some-name.md)")
    title = head[3:-len("](some-name.md)")]
    # 斷言用獨立算出的期望值，不是拿實作的輸出反推
    assert title == expect_title
    assert (hook if sep else None) == expect_hook
    if sep:
        # 真正要釘住的性質：切點不可落在**還沒閉合的**左括號之內（全形與半形都算）。
        # 不是「標題括號成對」——輸入本身就可能不平衡（如 `abc），def`），那時整句照登才對。
        assert title.count("（") - title.count("）") <= 0
        assert title.count("(") - title.count(")") <= 0
        # 標題 + 分隔符 + 提要要能還原出原句，不可掉字
        assert desc.startswith(title) and desc.endswith(hook)
        assert len(desc) - len(title) - len(hook) in (1, 2)   # 單字元或「——」


def test_import_resolves_newly_allowed_project_to_work(conn, home: Path):
    """project → work 是 0002 新開放的方向；舊 resolve 只查「同 bank 或 global」會誤判成
    dangling。這一條釘住新規則允許的方向真的解析得到。"""
    write_memory(home / "memory-work", "w-target", "工作的")
    write_memory(home / "projects" / "D--Projects-A" / "memory", "p-src", "專案的",
                 body="\n見 [[w-target]]。\n")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT target_id IS NOT NULL FROM memory_links WHERE target_name='w-target'")
        assert cur.fetchone()[0] is True


def test_import_forbidden_direction_stays_dangling_not_abort(conn, home: Path):
    """import 是復原路徑：bank 裡一條舊的跨庫引用不可讓整批 abort。

    與來源側刻意不同——那條引用是既有資料，不是使用者此刻正在寫的；abort 會讓復原機制
    在最需要它的時候失效。資訊由 audit 的 forbidden_ref 承接。
    """
    write_memory(home / "memory-machine", "m-target", "本機的")
    write_memory(home / "memory", "g-src", "全域的", body="\n見 [[m-target]]。\n")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='g-src'")
        assert cur.fetchone()[0] == 1                       # 有落地，沒 abort
        cur.execute("SELECT target_id IS NULL FROM memory_links WHERE target_name='m-target'")
        assert cur.fetchone()[0] is True                    # 但那條是 dangling


# ---------- Task 4：匯出面四路由 + ExportResult ----------

def test_export_routes_by_scope(conn, home: Path):
    from memory_pg import mutate
    seed_banks(home)
    for scope in ("global", "machine", "work"):
        mutate.write(conn, _cfg(), name=f"e-{scope}", scope=scope, description=f"{scope}",
                     body="\nb\n", kind="semantic")
    conn.commit()
    exporter.run(conn, _cfg(), verify_dir=None)
    assert (home / "memory" / "e-global.md").exists()
    assert (home / "memory-machine" / "e-machine.md").exists()
    assert (home / "memory-work" / "e-work.md").exists()
    assert (home / "memory-machine" / "MEMORY.md").exists()
    assert (home / "memory-work" / "MEMORY.md").exists()


def test_work_index_has_no_pinned_section(conn, home: Path):
    """memory-work/MEMORY.md 不產 PINNED——沒有任何常駐 include 會載入它，
    產了只會讓人誤以為已常駐。"""
    from memory_pg import mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="w-pin", scope="work", description="工作的",
                 body="\nb\n", kind="semantic", pin=True)
    conn.commit()
    exporter.run(conn, _cfg(), verify_dir=None)
    text = (home / "memory-work" / "MEMORY.md").read_text(encoding="utf-8")
    assert "PINNED:BEGIN" not in text
    assert "TOPICS:BEGIN" in text


def test_project_index_includes_work_tagged(conn, home: Path):
    """work + pinned + tagged 要出現在該專案的 PINNED——site-rose-* 轉 work 後仍要常駐。"""
    from memory_pg import mutate
    seed_banks(home)
    (home / "projects" / "D--Projects-A" / "memory").mkdir(parents=True, exist_ok=True)
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    mutate.write(conn, _cfg(), name="w-tagged", scope="work", description="案場的",
                 body="\nb\n", kind="environment", pin=True, tags=["D--Projects-A"])
    conn.commit()
    exporter.run(conn, _cfg(), verify_dir=None)
    idx = (home / "projects" / "D--Projects-A" / "memory" / "MEMORY.md")
    assert "PINNED:ITEM w-tagged" in idx.read_text(encoding="utf-8")


def test_export_skipped_bank_is_not_failure(conn, home: Path, monkeypatch):
    """not_installed 是合法狀態（單 repo 機器只 clone 通用 repo），export 應 exit 0。"""
    from memory_pg import cli
    shutil.rmtree(home / "memory-work", ignore_errors=True)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["export"]) == 0


def test_export_partial_failure_exits_1(conn, home: Path, monkeypatch):
    """一個 bank 中途寫入失敗 → partial，整體 exit 1。"""
    from memory_pg import cli, mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="p-a", scope="machine", description="本機A", body="\nb\n")
    mutate.write(conn, _cfg(), name="p-b", scope="machine", description="本機B", body="\nb\n")
    conn.commit()
    real = exporter._atomic_write
    def boom(path, data):
        if path.name == "p-b.md":
            raise OSError("模擬不可寫")
        return real(path, data)
    monkeypatch.setattr(exporter, "_atomic_write", boom)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["export"]) == 1


def test_auto_export_failure_exits_1(conn, home: Path, tmp_path, monkeypatch, capsys):
    """run() 回傳失敗分類時 write 也必須 exit 1——不是只有拋例外才算失敗。

    用真實輸入檔而不是 /dev/null：Windows 上 /dev/null 可能在 exporter 之前就失敗，
    那樣測試會因為別的原因通過，根本沒觸及目標分支。
    """
    from memory_pg import cli
    seed_banks(home)
    f = tmp_path / "b.md"
    f.write_text("\n內容。\n", encoding="utf-8")
    rep = exporter.ExportReport()
    rep.failed_banks.append(Path("x"))
    monkeypatch.setattr(exporter, "run", lambda *a, **k: rep)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["write", "--name", "ae", "--scope", "global",
                     "--description", "描述", "--file", str(f)]) == 1
    assert "export_after_write" in capsys.readouterr().err
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='ae'")
        assert cur.fetchone()[0] == 1        # DB 已更新，只是 md 沒同步


# ---------- Task 5：同步分割區 ----------

def test_import_missing_optional_bank_does_not_delete(conn, home: Path):
    """work bank not_installed 時，import 不得刪除 DB 內既有的 work 列。"""
    from memory_pg import mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="w-keep", scope="work", description="工作的", body="\nb\n")
    conn.commit()
    shutil.rmtree(home / "memory-work")            # 模擬工作 repo 沒 clone
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='w-keep'")
        assert cur.fetchone()[0] == 1


def test_import_one_project_bank_does_not_delete_others(conn, home: Path):
    """刪除授權的最小單位是同步分割區：project 是 (scope, home_project_id)。

    掃到一個專案就以 scope='project' 授權刪除，會把其他未出現的專案一併掃掉。
    """
    pa = home / "projects" / "D--Projects-A" / "memory"
    pb = home / "projects" / "D--Projects-B" / "memory"
    write_memory(pa, "a-mem", "A 的")
    write_memory(pb, "b-mem", "B 的")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    shutil.rmtree(pb.parent)                        # B 專案整個目錄消失
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='b-mem'")
        assert cur.fetchone()[0] == 1


def test_import_same_partition_still_deletes(conn, home: Path):
    """同一分割區內「檔案沒了 = 記憶被刪」的語義不變。"""
    g = home / "memory"
    write_memory(g, "g-a", "A")
    write_memory(g, "g-b", "B")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    (g / "g-b.md").unlink()
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='g-b'")
        assert cur.fetchone()[0] == 0


@pytest.mark.parametrize("argv", [
    ["import", "--purge-scope", "work"],
    ["import", "--purge-scope", "work", "--yes"],
])
def test_purge_rejected_while_installed(conn, home: Path, monkeypatch, argv):
    """bank 仍 installed 時 purge 一律拒絕：只刪 DB 會被下一次 import 從 md 復活。"""
    from memory_pg import cli, mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="w-purge", scope="work", description="工作的", body="\nb\n")
    conn.commit()
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(argv) == 2
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='w-purge'")
        assert cur.fetchone()[0] == 1


def test_purge_scope_after_uninstall(conn, home: Path, monkeypatch, capsys):
    from memory_pg import cli, mutate
    seed_banks(home)
    mutate.write(conn, _cfg(), name="w-purge", scope="work", description="工作的", body="\nb\n")
    conn.commit()
    shutil.rmtree(home / "memory-work")
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["import", "--purge-scope", "work"]) == 2        # 缺 --yes
    assert "w-purge" in capsys.readouterr().out                      # 但要先列出清單
    assert cli.main(["import", "--purge-scope", "work", "--yes"]) == 0
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='w-purge'")
        assert cur.fetchone()[0] == 0


def test_purge_project_and_all_projects(conn, home: Path, monkeypatch):
    from memory_pg import cli
    pa = home / "projects" / "D--Projects-A" / "memory"
    pb = home / "projects" / "D--Projects-B" / "memory"
    write_memory(pa, "a-mem", "A")
    write_memory(pb, "b-mem", "B")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    shutil.rmtree(pa.parent)
    shutil.rmtree(pb.parent)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    assert cli.main(["import", "--purge-project", "D--Projects-A", "--yes"]) == 0
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='b-mem'")
        assert cur.fetchone()[0] == 1                                # 只刪 A
    assert cli.main(["import", "--purge-all-projects", "--yes"]) == 0
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE scope='project'")
        assert cur.fetchone()[0] == 0


# ---------- Task 5：presence 四態必須窮舉 ----------

def _count_all(conn) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories")
        return cur.fetchone()[0]


def test_presence_damaged_install_aborts(conn, home: Path, monkeypatch):
    """git dir 在、bank 目錄不在 → 安裝損壞，整批 exit 1，不得當成空 bank。"""
    from memory_pg import cli
    seed_banks(home)
    write_memory(home / "memory", "g-keep", "全域的")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    shutil.rmtree(home / "memory-machine")
    (home.parent / ".claude-machine.git").mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    before = _count_all(conn)
    assert cli.main(["import"]) == 1
    assert _count_all(conn) == before                 # 零寫入零刪除


def test_presence_path_is_regular_file(conn, home: Path, monkeypatch):
    """bank 路徑存在但不是目錄 → unavailable → exit 1，零寫入零刪除。"""
    from memory_pg import cli
    seed_banks(home)
    write_memory(home / "memory", "g-keep2", "全域的")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    shutil.rmtree(home / "memory-work")
    (home / "memory-work").write_text("我是檔案不是目錄", encoding="utf-8")
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    before = _count_all(conn)
    assert cli.main(["import"]) == 1
    assert _count_all(conn) == before


def test_project_bank_absent_is_not_damaged_install(conn, home: Path, monkeypatch):
    """工作 git dir 存在，但某個 project bank 缺席 → 不得推導為 damaged_install。

    部分 clone、新專案尚未建庫都是合法的；判成失敗會讓那些機器連 import 都跑不了。
    """
    from memory_pg import cli
    seed_banks(home)
    (home.parent / ".claude-work.git").mkdir(parents=True, exist_ok=True)
    write_memory(home / "projects" / "D--Projects-A" / "memory", "a-mem", "A")
    importer.run(conn, _cfg(), dry_run=False)
    conn.commit()
    shutil.rmtree(home / "projects" / "D--Projects-A")
    monkeypatch.setattr(sys, "stdin", io.StringIO(""))
    # --no-verify：專案目錄在本機被刪掉之後，DB 仍有該專案的列，export --verify 必然報
    # missing_in_bank。那是「這台機器沒有那個目錄」的正確反映，不是 import 的問題；
    # 這一則要釘的是【import 不得刪資料，也不得判成 damaged_install】。
    assert cli.main(["import", "--no-verify"]) == 0
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM memories WHERE name='a-mem'")
        assert cur.fetchone()[0] == 1                 # 且沒被刪
