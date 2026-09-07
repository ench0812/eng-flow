# claude-memory-pg：PGroonga（CJK 全文檢索）+ pgvector（向量）同一個 PostgreSQL 18。
#
# 為什麼自建：沒有任何現成 image 同時含兩者——pgvector/pgvector 只有 pgvector + contrib，
# groonga/pgroonga 只有 PGroonga。PGroonga 的 debian image 內建 PGDG apt 源，
# postgresql-18-pgvector 直接 apt 得到（2026-08-25 實測 apt-cache search 有列）。
FROM groonga/pgroonga:4.0.8-debian-18

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18-pgvector \
 && rm -rf /var/lib/apt/lists/*

# 只在資料目錄第一次初始化時執行：建 memory 與 claude_memory_test 兩個 database 的擴充。
COPY init/00-extensions.sql /docker-entrypoint-initdb.d/00-extensions.sql
