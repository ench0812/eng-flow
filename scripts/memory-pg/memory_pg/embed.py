"""embedding 管線 — 本機 ollama /api/embed。

embed 文字組成（見 plan A5）：name 去連字號 + description + body（去 frontmatter 記號、
[[x]]→x、去強調/標題記號、保留 code block）+ doc_prefix；硬截 6000 字元。
重算判定：embedding_src_hash 或 embedding_model 變了。
Windows ollama 對某些中文/markdown 有 500/NaN 的 open issue → 每次檢查 finite/norm，
失敗重試一次改用「淨化」文字，仍失敗則留 NULL（寫入端）或 raise（查詢端）。
"""

from __future__ import annotations

import hashlib
import math
import re

import httpx

from .config import Config
from .errors import RetrievalUnavailable

MAX_CHARS = 6000
_WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")
_EMPHASIS = re.compile(r"[*_`]+")
_HEADING = re.compile(r"^#{1,6}\s+", re.MULTILINE)
_SANITIZE = re.compile(r"['\"`*|]")


def build_embed_text(name: str, description: str, body: str, *, doc_prefix: str = "") -> str:
    b = _WIKILINK.sub(r"\1", body)
    b = _HEADING.sub("", b)
    b = _EMPHASIS.sub("", b)
    b = re.sub(r"[ \t]+", " ", b)
    text = f"{name.replace('-', ' ')}\n{description}\n{b}".strip()
    return (doc_prefix + text)[:MAX_CHARS]


def src_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _finite_vec(v) -> bool:
    return isinstance(v, list) and len(v) > 0 and all(isinstance(x, (int, float)) and math.isfinite(x) for x in v) \
        and any(x != 0 for x in v)


def _post(url: str, model: str, inputs: list[str], timeout: float) -> list[list[float]]:
    r = httpx.post(f"{url}/api/embed", json={"model": model, "input": inputs,
                                             "truncate": True, "keep_alive": "1h"}, timeout=timeout)
    r.raise_for_status()
    data = r.json()
    embs = data.get("embeddings")
    if not embs or len(embs) != len(inputs):
        raise RetrievalUnavailable(f"ollama 回傳 embeddings 數量不符（{len(embs) if embs else 0}/{len(inputs)}）")
    return embs


def embed_texts(cfg: Config, model: str, texts: list[str], *, timeout: float = 60.0) -> list[list[float]]:
    """批次嵌入，逐筆檢查 finite；壞的那筆用淨化文字重試一次。回傳與 texts 等長（壞到底的為 None）。"""
    out: list[list[float] | None] = [None] * len(texts)
    BATCH = 16
    for i in range(0, len(texts), BATCH):
        chunk = texts[i:i + BATCH]
        try:
            embs = _post(cfg.ollama_url, model, chunk, timeout)
        except (httpx.HTTPError, RetrievalUnavailable):
            embs = [None] * len(chunk)   # 整批壞 → 逐筆重試
        for j, (t, e) in enumerate(zip(chunk, embs if embs else [None] * len(chunk))):
            idx = i + j
            if e is not None and _finite_vec(e):
                out[idx] = e
                continue
            # 重試一次：淨化文字（去引號/反引號/*/|——Windows ollama 已知會 500/NaN）
            try:
                e2 = _post(cfg.ollama_url, model, [_SANITIZE.sub(" ", t)], timeout)[0]
                if _finite_vec(e2):
                    out[idx] = e2
            except (httpx.HTTPError, RetrievalUnavailable):
                pass
    return out  # type: ignore[return-value]


def embed_query(cfg: Config, text: str, *, timeout: float = 3.0) -> list[float]:
    """給 search 用的 embed_fn：cfg 內含 model/prefix 由呼叫端先讀好並綁定，這裡走設定表。"""
    from . import db
    import psycopg

    conn = psycopg.connect(cfg.dsn, connect_timeout=3)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT model, query_prefix FROM embedding_config LIMIT 1")
            row = cur.fetchone()
        if not row:
            raise RetrievalUnavailable("無 embedding_config")
        model, qprefix = row
    finally:
        conn.close()
    embs = _post(cfg.ollama_url, model, [(qprefix or "") + text], timeout)
    v = embs[0]
    if not _finite_vec(v):
        raise RetrievalUnavailable("query embedding 非有限值（ollama 中文 bug？）")
    return v


def make_query_embedder(model: str, qprefix: str, timeout: float = 3.0):
    """回傳一個 (cfg, text)->vec 的閉包，避免 search 每次都連 DB 讀設定。"""
    def _fn(cfg: Config, text: str) -> list[float]:
        embs = _post(cfg.ollama_url, model, [(qprefix or "") + text], timeout)
        v = embs[0]
        if not _finite_vec(v):
            raise RetrievalUnavailable("query embedding 非有限值")
        return v
    return _fn
