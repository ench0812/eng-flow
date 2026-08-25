-- 0001_init.sql — memory_pg 初始 schema（PostgreSQL 18）
--
-- 設計原則：
--   * 現行 frontmatter 的每個欄位都有落點（無損遷移）；未對應的 key 進 extra_frontmatter。
--   * 取代關係只有一份真相（memory_links kind=supersedes 一列），superseded_by 是推導值；
--     「雙向一致」「一則只被一則取代」「不自我取代」「不成環」全部由結構與觸發器保證，
--     不靠事後稽核。
--   * 規則放 DB 不放應用層：CLI 與 MCP 是兩個入口，各自實作一次就會漂移。
--   * embedding 欄不帶維度：換模型不必 ALTER；維度不符時 pgvector 直接報錯，那是保護不是缺陷。
--   * 本檔不用任何 psql meta-command（本機沒有 psql，由 psycopg 執行）。

CREATE TABLE IF NOT EXISTS schema_migrations (
  version    int PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE EXTENSION IF NOT EXISTS vector;
-- pgroonga 在退路 image（pgvector/pgvector）上不存在；缺了只是全文路走 ILIKE，不阻擋 migration。
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pgroonga;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pgroonga 不可用（%），全文檢索將走 ILIKE 退路', SQLERRM;
END $$;
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_trgm 不可用（%）', SQLERRM;
END $$;

-- ---------- enums ----------
CREATE TYPE memory_scope     AS ENUM ('global', 'user', 'workspace', 'project');
CREATE TYPE memory_kind      AS ENUM ('semantic', 'episodic', 'procedural', 'decision', 'environment');
CREATE TYPE memory_status    AS ENUM ('active', 'superseded', 'deprecated', 'invalid');
CREATE TYPE confidence_level AS ENUM ('high', 'medium', 'low', 'unverified');
CREATE TYPE source_kind      AS ENUM ('session', 'manual', 'import', 'consolidation');
CREATE TYPE link_kind        AS ENUM ('wikilink', 'supersedes', 'related', 'extracted_from');
CREATE TYPE access_event     AS ENUM ('search', 'inject', 'read', 'write', 'learn', 'forget', 'export', 'import');

-- ---------- projects ----------
-- slug 是 Claude Code 依 cwd 產生的目錄名（D--Projects-IntelliPark）。
-- is_workspace_root：IntelliPark 是 6 個 repo 共用一個 bank——cwd 落在 root_path 之下的 session
-- 都對應到這一列。這是路徑前綴比對，不是家族解析層。
CREATE TABLE projects (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug              text NOT NULL UNIQUE,
  family            text,
  root_path         text NOT NULL,
  bank_path         text NOT NULL UNIQUE,
  is_workspace_root boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- ---------- memories ----------
CREATE TABLE memories (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- 同 memory-model.awk 的 bad_id 規則：ID 會原樣進 <!-- PINNED:ITEM %s -->，字元集必須收緊
  name                 text NOT NULL UNIQUE CHECK (name ~ '^[A-Za-z0-9_-][A-Za-z0-9._-]*$'),
  description          text NOT NULL CHECK (description <> '' AND description !~ '[\x01-\x1f]'),
  body                 text NOT NULL DEFAULT '',       -- frontmatter 結尾 --- 之後的全部
  file_path            text NOT NULL UNIQUE,           -- 匯出目標（Windows 絕對路徑），TSV 第 1 欄的來源
  scope                memory_scope NOT NULL,
  home_project_id      uuid REFERENCES projects(id),
  kind                 memory_kind,                    -- NULL＝尚未分類
  legacy_type          text,                           -- 原 frontmatter metadata.type（project/reference）
  status               memory_status NOT NULL DEFAULT 'active',
  pinned               boolean NOT NULL DEFAULT false,
  review_by            date,                           -- NULL＝不腐爛
  valid_from           timestamptz NOT NULL DEFAULT now(),
  valid_until          timestamptz,                    -- NULL＝仍有效
  importance           smallint NOT NULL DEFAULT 3 CHECK (importance BETWEEN 1 AND 5),
  confidence           confidence_level NOT NULL DEFAULT 'medium',
  evidence_count       int NOT NULL DEFAULT 1,         -- 「三次規則」計數器
  last_verified        date,
  verification_method  text,
  expiration_condition text,
  preconditions        text[] NOT NULL DEFAULT '{}',
  source_type          source_kind NOT NULL DEFAULT 'manual',
  source_id            text,
  origin_session_id    text,                           -- frontmatter originSessionId 原樣
  node_type            text,                           -- frontmatter node_type 原樣
  frontmatter_raw      text,                           -- 匯入時的原始 frontmatter；canonicalize 後清 NULL
  extra_frontmatter    jsonb NOT NULL DEFAULT '{}'::jsonb,
  para_count           int NOT NULL DEFAULT 1,         -- 與 awk 同規則：空行分段
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz(3) NOT NULL DEFAULT now(),   -- frontmatter modified（毫秒）
  last_accessed_at     timestamptz,
  access_count         int NOT NULL DEFAULT 0,
  -- ===== 檢索層 =====
  -- id 的每一節成為獨立 token（gh-auth-workflow-scope → gh auth workflow scope）
  search_name          text GENERATED ALWAYS AS (replace(name, '-', ' ')) STORED,
  embedding            vector,                         -- 不帶維度，見檔頭
  embedding_model      text,
  embedding_dim        int,
  embedding_src_hash   text,                           -- sha256(embed_text)，決定要不要重算
  embedded_at          timestamptz,
  CONSTRAINT scope_project_consistency CHECK (
    (scope = 'project' AND home_project_id IS NOT NULL) OR
    (scope <> 'project' AND home_project_id IS NULL)
  ),
  -- active ⇔ valid_until 為 NULL。把它做成雙向等價，取代關係的觸發器才能在刪連結時安全還原
  -- （不必猜「原本有沒有到期日」）。
  CONSTRAINT active_iff_no_until CHECK ((status = 'active') = (valid_until IS NULL))
);

-- 多對多標籤：scope=global 的記憶標「與哪些專案相關」。
-- 空集合＝適用所有專案；非空＝只注入到這些專案。search 不受此限（它只是 affinity）。
CREATE TABLE memory_projects (
  memory_id  uuid NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES projects(id),
  PRIMARY KEY (memory_id, project_id)
);

-- 連結：wikilink / supersedes / related / extracted_from。
-- target_name 永遠保留（dangling 時 target_id 為 NULL，audit 據此報 dangling_ref）。
CREATE TABLE memory_links (
  id          bigserial PRIMARY KEY,
  source_id   uuid NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  target_name text NOT NULL,
  target_id   uuid REFERENCES memories(id) ON DELETE SET NULL,
  kind        link_kind NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, target_name, kind),
  CHECK (target_id IS NULL OR source_id <> target_id)    -- 不可自我取代 / 自我連結
);
-- 一則只能被一則取代（= 現行 superseded_by 是純量）
CREATE UNIQUE INDEX memory_links_one_superseder
  ON memory_links (target_id) WHERE kind = 'supersedes' AND target_id IS NOT NULL;

CREATE TABLE memory_sources (
  id         bigserial PRIMARY KEY,
  memory_id  uuid NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  kind       source_kind NOT NULL,
  ref        text NOT NULL,          -- transcript 絕對路徑 / 原 md 路徑 / session id
  locator    text,
  available  boolean,                -- 匯入當下 ref 是否存在（冷儲存指標可能已被清）
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memory_revisions (       -- edit/merge/forget 前的快照，可回滾
  id              bigserial PRIMARY KEY,
  memory_id       uuid NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  description     text NOT NULL,
  body            text NOT NULL,
  frontmatter_raw text,
  reason          text,
  changed_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memory_access_log (      -- 取代 cache/memory-usage.tsv；inject 也要填 memory_ids
  id         bigserial PRIMARY KEY,
  ts         timestamptz NOT NULL DEFAULT now(),
  event      access_event NOT NULL,
  project_id uuid REFERENCES projects(id),
  cwd        text,
  session_id text,
  keyword    text,
  n          int NOT NULL DEFAULT 0,
  memory_ids uuid[] NOT NULL DEFAULT '{}',
  mode       text                     -- fts / hybrid / vector
);

-- 現行 embedding 模型的唯一真相（單列）。search 時比對每列的 embedding_model。
CREATE TABLE embedding_config (
  singleton    boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  model        text NOT NULL,
  dim          int  NOT NULL,
  query_prefix text NOT NULL DEFAULT '',
  doc_prefix   text NOT NULL DEFAULT '',
  tau          real NOT NULL DEFAULT 0.5,   -- 向量路的相似度門檻，由 memory eval 校準
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------- 觸發器 ----------
-- (a) supersedes 連結：偵環 → 舊者 status=superseded、valid_until=now()；刪連結則還原。
--     只能取代【現行】的記憶：deprecated/invalid 已經不在流通中，再取代會把它的狀態蓋掉，
--     之後刪連結還原時就分不出原本是什麼。
CREATE FUNCTION trg_supersede() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE tstatus memory_status;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.kind = 'supersedes' AND NEW.target_id IS NOT NULL THEN
    SELECT status INTO tstatus FROM memories WHERE id = NEW.target_id;
    IF tstatus <> 'active' THEN
      RAISE EXCEPTION 'supersede_target_not_active: target % is %', NEW.target_id, tstatus;
    END IF;
    -- 沿「誰取代了 NEW.source_id」往上走；若走回 NEW.target_id 就是環
    IF EXISTS (
      WITH RECURSIVE up AS (
        SELECT l.source_id FROM memory_links l
         WHERE l.target_id = NEW.source_id AND l.kind = 'supersedes'
        UNION
        SELECT l.source_id FROM memory_links l JOIN up ON l.target_id = up.source_id
         WHERE l.kind = 'supersedes'
      )
      SELECT 1 FROM up WHERE source_id = NEW.target_id
    ) THEN
      RAISE EXCEPTION 'supersede_cycle: % -> %', NEW.source_id, NEW.target_id;
    END IF;
    UPDATE memories
       SET status = 'superseded', valid_until = COALESCE(valid_until, now())
     WHERE id = NEW.target_id;
  ELSIF TG_OP = 'DELETE' AND OLD.kind = 'supersedes' AND OLD.target_id IS NOT NULL THEN
    UPDATE memories SET status = 'active', valid_until = NULL
     WHERE id = OLD.target_id AND status = 'superseded';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER memory_links_supersede
  AFTER INSERT OR DELETE ON memory_links
  FOR EACH ROW EXECUTE FUNCTION trg_supersede();

-- (a') 連結不可變：source/target/kind 一律不得 UPDATE，要改就刪了重建。
--      否則 UPDATE 可以繞過上面的偵環與狀態同步（把一條 wikilink 改成 supersedes 就沒有任何守門）。
CREATE FUNCTION trg_links_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- 唯一放行的轉換：target 記憶被刪除時 FK 的 ON DELETE SET NULL（連結變成 dangling）。
  -- 其判準是「只有 target_id 從非 NULL 變 NULL，其他欄位全部不變」。
  IF NEW.source_id = OLD.source_id AND NEW.target_name = OLD.target_name AND NEW.kind = OLD.kind
     AND OLD.target_id IS NOT NULL AND NEW.target_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.source_id IS DISTINCT FROM OLD.source_id
     OR NEW.target_id IS DISTINCT FROM OLD.target_id
     OR NEW.target_name IS DISTINCT FROM OLD.target_name
     OR NEW.kind IS DISTINCT FROM OLD.kind THEN
    RAISE EXCEPTION 'links_immutable: memory_links 不可 UPDATE，請 DELETE 後重新 INSERT';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER memory_links_immutable
  BEFORE UPDATE ON memory_links
  FOR EACH ROW EXECUTE FUNCTION trg_links_immutable();

-- (b) scope 規則（與現行 resolve() 的「同庫 → 全域庫」一致）：
--     target 是 global 一律允許；project → 同 project 允許；project↔project、global→project 禁止。
--     supersedes 額外要求同 scope 同 home（現行 cross_bank 規則）。
CREATE FUNCTION trg_link_scope() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s memories%ROWTYPE; t memories%ROWTYPE;
BEGIN
  IF NEW.target_id IS NULL THEN RETURN NEW; END IF;    -- dangling 交給 audit 報
  SELECT * INTO s FROM memories WHERE id = NEW.source_id;
  SELECT * INTO t FROM memories WHERE id = NEW.target_id;
  IF NEW.kind = 'supersedes' THEN
    IF s.scope IS DISTINCT FROM t.scope OR s.home_project_id IS DISTINCT FROM t.home_project_id THEN
      RAISE EXCEPTION 'cross_bank_supersede: % (%) -> % (%)', s.name, s.scope, t.name, t.scope;
    END IF;
    RETURN NEW;
  END IF;
  IF t.scope = 'global' THEN RETURN NEW; END IF;
  IF s.scope = 'project' AND t.scope = 'project' AND s.home_project_id = t.home_project_id THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'cross_project_link: % (%) -> % (%)', s.name, s.scope, t.name, t.scope;
END $$;
CREATE TRIGGER memory_links_scope
  BEFORE INSERT ON memory_links
  FOR EACH ROW EXECUTE FUNCTION trg_link_scope();

-- ---------- 索引 ----------
CREATE INDEX memories_scope_status    ON memories (scope, status);
CREATE INDEX memories_home_project    ON memories (home_project_id) WHERE scope = 'project';
CREATE INDEX memories_pinned_active   ON memories (scope, home_project_id) WHERE pinned AND status = 'active';
CREATE INDEX memories_review_by       ON memories (review_by) WHERE status = 'active' AND review_by IS NOT NULL;
CREATE INDEX memory_links_target      ON memory_links (target_id);
CREATE INDEX memory_projects_project  ON memory_projects (project_id);
CREATE INDEX memory_access_log_ts     ON memory_access_log (ts);
-- embedding 不建索引：幾百～幾千則 exact scan 即可，且 recall 完美。

-- 全文索引：PGroonga 有才建；三欄各一個（PGroonga 無欄位權重，合併後 id 命中與正文提到一次分不出來）。
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgroonga') THEN
    EXECUTE 'CREATE INDEX memories_name_pgroonga ON memories USING pgroonga (search_name)';
    EXECUTE 'CREATE INDEX memories_desc_pgroonga ON memories USING pgroonga (description)';
    EXECUTE 'CREATE INDEX memories_body_pgroonga ON memories USING pgroonga (body)';
  END IF;
END $$;
