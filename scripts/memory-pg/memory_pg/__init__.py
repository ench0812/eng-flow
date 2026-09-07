"""memory_pg — eng-flow 記憶系統的 PostgreSQL 後端。

資料本體在 PostgreSQL（PGroonga + pgvector），Markdown bank 是匯出/冷儲存。
CLI 契約（沿用 memory.sh）：exit 0 成功（含查無）、1 無法判定正確性（stdout 零輸出）、2 用法/設定錯誤。
"""

__version__ = "0.1.0"
