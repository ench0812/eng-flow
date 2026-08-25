"""search 的 golden set 與行為測試（fts 模式；hybrid 於 Task 3 embedding 上線後再加向量斷言）。

golden 針對「現行實測失敗的 9 個查詢」，目標記憶必須進 top-k。以隔離 home + 測試 DB 跑，
記憶內容用最小 fixture 建（只放 golden 需要的欄位），不依賴會變動的真實 bank。
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from conftest import write_memory  # noqa: E402

from memory_pg import config, importer, search as S  # noqa: E402


def _seed(conn, home: Path):
    g = home / "memory"
    ip = home / "projects" / "D--Projects-IntelliPark" / "memory"
    nav = home / "projects" / "D--Projects-pcpms-car-navigator" / "memory"
    write_memory(g, "gh-auth-workflow-scope",
                 "gh token 缺 workflow scope 會擋含 .github/workflows 的 push",
                 body="\n症狀：refusing to allow OAuth App... 補授權 gh auth refresh -s workflow 走 device flow，"
                      "必須在一般終端機跑。\n")
    write_memory(ip, "pgs-deployment-reality", "PGS 四類環境定位；rose 是第一台正式生產機",
                 body="\nrose 正式生產機＝三重玫瑰。testbed 202.5.255.35。部署主機位址見別處。\n")
    write_memory(ip, "pgs-native-deploy-procedure", "PGS native 部署實際跑法",
                 body="\n部署要在 WSL 跑，三個路徑變數都要覆寫。rose 三重玫瑰。\n")
    write_memory(ip, "pgs-workspace-layout", "IntelliPark 是 PGS 6-repo 工作區",
                 body="\n根目錄非 git；AGENTS.md 是權威。\n")
    write_memory(ip, "rose-map-import-baseline", "三重玫瑰地圖匯入基線",
                 body="\n樓層 9；device_cameras 133。rose 部署後匯入。\n")
    write_memory(nav, "nav-jetson-field-access", "Jetson 尋車機 SSH 別名與量測方法",
                 body="\npgs-spt 是尋車機。CDP、framebuffer。\n")
    write_memory(nav, "nav-perf-ceiling-2026-08", "Jetson 效能已量測、不需優化",
                 body="\n1x 56.9 FPS。預熱方向否決。\n")
    write_memory(nav, "nav-noise", "與 Jetson 無關的雜訊記憶", body="\n無關內容。\n")
    importer.run(conn, config.load(use_test_db=True), dry_run=False)
    conn.commit()
    # workspace root：讓 pgs-* 子目錄 cwd 解析到 IntelliPark
    with conn.cursor() as cur:
        cur.execute("UPDATE projects SET is_workspace_root=true WHERE slug='D--Projects-IntelliPark'")
    conn.commit()


def _names(conn, home, query, cwd, **kw):
    res = S.search(conn, config.load(use_test_db=True), query, cwd=cwd, mode="fts", **kw)
    return [h.name for h in res.hits]


GOLDEN = [
    ("gh auth workflow scope", "D--Projects-IntelliPark/pgs-admin", "gh-auth-workflow-scope"),
    ("device flow 授權", "D--Projects-IntelliPark", "gh-auth-workflow-scope"),
    ("workflow scope push", "D--Projects-IntelliPark/pgs-admin", "gh-auth-workflow-scope"),
    ("rose 玫瑰 部署", "D--Projects-IntelliPark", "pgs-deployment-reality"),
    ("rose 玫瑰 部署", "D--Projects-IntelliPark", "rose-map-import-baseline"),
    ("部署 主機 位址 rose 三重玫瑰", "D--Projects-IntelliPark/pgs-main", "pgs-deployment-reality"),
    ("Jetson", "D--Projects-pcpms-car-navigator", "nav-jetson-field-access"),
    ("Jetson", "D--Projects-pcpms-car-navigator", "nav-perf-ceiling-2026-08"),
]


@pytest.mark.parametrize("query,rel,expected", GOLDEN)
def test_golden_top3(conn, home: Path, query, rel, expected):
    _seed(conn, home)
    cwd = str((Path(str(home)).drive + "\\") if False else Path("D:/Projects") / rel.split("/", 1)[1]) \
        if rel.startswith("D--Projects-IntelliPark/") else None
    # cwd 以真實 D:\Projects 路徑表示，讓 workspace-root 前綴比對生效
    if rel == "D--Projects-IntelliPark":
        cwd = r"D:\Projects\IntelliPark"
    elif rel.startswith("D--Projects-IntelliPark/"):
        cwd = r"D:\Projects\IntelliPark\\" + rel.split("/", 1)[1]
    elif rel == "D--Projects-pcpms-car-navigator":
        cwd = r"D:\Projects\pcpms-car-navigator"
    names = _names(conn, home, query, cwd)
    assert expected in names[:3], f"{query!r} → {names[:3]}"


def test_id_exact_rank_one(conn, home: Path):
    _seed(conn, home)
    names = _names(conn, home, "pgs-workspace-layout", r"D:\Projects\IntelliPark")
    assert names[0] == "pgs-workspace-layout"


def test_negative_zero_hits(conn, home: Path):
    _seed(conn, home)
    res = S.search(conn, config.load(use_test_db=True), "React useEffect 藍牙 發票統編",
                   cwd=r"D:\Projects\IntelliPark", mode="fts")
    assert res.hits == []


def test_scope_isolation(conn, home: Path):
    _seed(conn, home)
    # 在 car-navigator 下查 Jetson：只該有 nav-*，不該有 pgs-*
    names = _names(conn, home, "Jetson", r"D:\Projects\pcpms-car-navigator")
    assert names and all(n.startswith("nav-") for n in names)
    # --all 打破 scope
    res = S.search(conn, config.load(use_test_db=True), "部署", cwd=r"D:\Projects\pcpms-car-navigator",
                   mode="fts", scope="all")
    assert any(n.startswith("pgs-") for n in res.hits and [h.name for h in res.hits])


def test_explicit_scope_project_key(conn, home: Path):
    # R1 回歸：--scope <project_key> 的 SQL 不能 reference 未 join 的 p.slug
    _seed(conn, home)
    res = S.search(conn, config.load(use_test_db=True), "部署", cwd=None,
                   mode="fts", scope="D--Projects-IntelliPark")
    names = [h.name for h in res.hits]
    assert names and all(not n.startswith("nav-") for n in names)   # 只該有 IntelliPark + global


def test_global_always_visible(conn, home: Path):
    _seed(conn, home)
    # 在 car-navigator 下也查得到 global 的 gh-auth
    names = _names(conn, home, "workflow scope", r"D:\Projects\pcpms-car-navigator")
    assert "gh-auth-workflow-scope" in names


def test_superseded_excluded(conn, home: Path):
    _seed(conn, home)
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM memories WHERE name='rose-map-import-baseline'")
        old = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO memories(name,description,body,file_path,scope,home_project_id) "
            "SELECT 'rose-map-v2','新版基線','\n新\n',replace(file_path,'baseline','v2'),scope,home_project_id "
            "FROM memories WHERE name='rose-map-import-baseline' RETURNING id")
        new = cur.fetchone()[0]
        cur.execute("INSERT INTO memory_links(source_id,target_name,target_id,kind) VALUES (%s,'rose-map-import-baseline',%s,'supersedes')", (new, old))
    conn.commit()
    names = _names(conn, home, "基線 rose", r"D:\Projects\IntelliPark", include_superseded=False)
    assert "rose-map-import-baseline" not in names
    names_all = _names(conn, home, "基線 rose", r"D:\Projects\IntelliPark", include_superseded=True)
    assert "rose-map-import-baseline" in names_all


def test_tsv_contract(conn, home: Path):
    _seed(conn, home)
    res = S.search(conn, config.load(use_test_db=True), "Jetson", cwd=r"D:\Projects\pcpms-car-navigator", mode="fts")
    h = res.hits[0]
    assert h.file_path.startswith("/") and "\\" not in h.file_path      # git-bash 風格
    assert h.name and h.description


def test_degrade_hybrid_without_embedder_falls_to_fts(conn, home: Path):
    _seed(conn, home)
    # 沒有 embedding_config + embed_fn=None → hybrid 自動降 fts，有結果就 OK
    res = S.search(conn, config.load(use_test_db=True), "Jetson", cwd=r"D:\Projects\pcpms-car-navigator",
                   mode="hybrid", degrade_ok=True)
    assert res.mode == "fts" and res.hits
