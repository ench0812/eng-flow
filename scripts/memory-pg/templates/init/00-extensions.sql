-- 由 docker-entrypoint-initdb.d 在資料目錄首次初始化時執行（對 POSTGRES_DB）。
-- 擴充要建在每個 database 內，所以 memory 與測試用的 claude_memory_test 各做一次。
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgroonga;
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- 退路用，先裝著

CREATE DATABASE claude_memory_test;
\connect claude_memory_test
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgroonga;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
