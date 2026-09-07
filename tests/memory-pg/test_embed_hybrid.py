"""embedding + hybrid 整合測試。需要 ollama + bge-m3；不可用時 skip（明講，不當通過）。
fail-closed 的部分不需模型，一律跑。"""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest

from conftest import write_memory  # noqa: E402

from memory_pg import config, embed, importer, search as S  # noqa: E402

MODEL = "bge-m3"


def _ollama_ok(cfg) -> bool:
    try:
        r = httpx.get(f"{cfg.ollama_url}/api/tags", timeout=3)
        names = [m["name"] for m in r.json().get("models", [])]
        return any(n.startswith(MODEL) for n in names)
    except Exception:  # noqa: BLE001
        return False


def _seed_and_embed(conn, home: Path, cfg) -> None:
    g = home / "memory"
    write_memory(g, "gh-auth-workflow-scope", "gh token 缺 workflow scope 會擋 push",
                 body="\n補授權 gh auth refresh -s workflow 走 device flow，要在終端機跑。\n")
    write_memory(g, "drive-account-topology", "G 槽掛的不是個人 Google 帳號",
                 body="\n兩個帳號都有 Code 資料夾，光看目錄會誤判。\n")
    write_memory(g, "nav-perf-noise", "與效能無關的雜訊", body="\n無關內容佔位。\n")
    importer.run(conn, cfg, dry_run=False)
    conn.commit()
    with conn.cursor() as cur:
        cur.execute("DELETE FROM embedding_config")
        cur.execute("INSERT INTO embedding_config(model,dim,tau) VALUES (%s,1024,0.35)", (MODEL,))
        cur.execute("SELECT name, description, body FROM memories WHERE status='active'")
        rows = cur.fetchall()
    texts = [embed.build_embed_text(n, d, b) for n, d, b in rows]
    vecs = embed.embed_texts(cfg, MODEL, texts, timeout=120.0)
    with conn.cursor() as cur:
        for (n, _d, _b), v in zip(rows, vecs):
            assert v is not None, f"{n} 嵌入失敗"
            cur.execute("UPDATE memories SET embedding=%s, embedding_model=%s, embedding_dim=1024, "
                        "embedding_src_hash='x', embedded_at=now() WHERE name=%s", (str(v), MODEL, n))
    conn.commit()


def test_hybrid_vector_catches_reworded(conn, home: Path):
    cfg = config.load(use_test_db=True)
    if not _ollama_ok(cfg):
        pytest.skip("ollama / bge-m3 不可用")
    _seed_and_embed(conn, home, cfg)
    fn = embed.make_query_embedder(MODEL, "")
    # 「權限不足推不上去」與 gh-auth 正文用詞不同，fts 難命中，靠向量
    res = S.search(conn, cfg, "權限不足 推不上去", cwd=None, scope="global",
                   mode="hybrid", embed_fn=fn, degrade_ok=False)
    names = [h.name for h in res.hits]
    assert res.mode == "hybrid"
    assert "gh-auth-workflow-scope" in names[:3], names
    assert any(h.name == "gh-auth-workflow-scope" and h.vec_rank for h in res.hits)


def test_hybrid_failclosed_when_embedder_dies(conn, home: Path):
    cfg = config.load(use_test_db=True)
    _seed_only(conn, home, cfg)

    def dead(_cfg, _text):
        raise httpx.ConnectTimeout("dead")

    # 嚴格：向量路死 + 零全文命中的查詢 → 不可信 → raise
    from memory_pg.errors import RetrievalUnavailable
    with pytest.raises(RetrievalUnavailable):
        S.search(conn, cfg, "完全不存在的詞彙 zzz", cwd=None, scope="global",
                 mode="hybrid", embed_fn=dead, degrade_ok=False)
    # degrade：同查詢退 fts，回空但 exit 正常（mode=fts）
    res = S.search(conn, cfg, "完全不存在的詞彙 zzz", cwd=None, scope="global",
                   mode="hybrid", embed_fn=dead, degrade_ok=True)
    assert res.mode == "fts" and res.hits == []


def _seed_only(conn, home: Path, cfg) -> None:
    # 需要 embedding_config 存在才會走向量路（否則直接降 fts，測不到 fail-closed）
    write_memory(home / "memory", "only-one", "唯一一則", body="\n內容。\n")
    importer.run(conn, cfg, dry_run=False)
    with conn.cursor() as cur:
        cur.execute("DELETE FROM embedding_config")
        cur.execute("INSERT INTO embedding_config(model,dim,tau) VALUES (%s,1024,0.35)", (MODEL,))
    conn.commit()
