-- 0003：夢境衰減——記憶的召回強度、休眠狀態與豁免旗標。
--
-- 用獨立欄位而不是擴充 memory_status enum：status 是「這則記憶還成不成立」的真偽軸
-- （active / superseded / deprecated / invalid），休眠是「還記不記得」的正交軸，兩者正交。
-- 現實理由同樣硬：原始碼有 31 處 `status='active'` 散在 8 個檔案，加 enum 值就得逐一判斷
-- 每一處該不該含 dormant，漏一處是靜默行為改變（例如 embed 漏掉，甦醒後那則會搜不到）。
-- 獨立欄位讓那 31 處全部不必動，0001 的 CHECK ((status='active') = (valid_until IS NULL))
-- 也不必動。
--
-- 歷史 access log 的 cutoff **不寫在這裡，也不寫成程式常數**：
-- schema_migrations.applied_at 就是本支 migration 的實際套用時刻（0001 已定義該欄位，
-- NOT NULL DEFAULT now()），decay.py 直接讀
--   SELECT applied_at FROM schema_migrations WHERE version = 3
-- 早於它的 memory_access_log.memory_ids 是 array_agg 的 DB 掃描順序、**不是命中排名**，
-- 只能當「有無命中」用；晚於它的才由改寫過的 log_access 依 hits 順序寫入，陣列 index 即 rank。
-- 寫成常數的話，換一台機器或重建 DB 就會把新資料誤判成歷史資料（或反過來）。

ALTER TABLE memories
  ADD COLUMN recall_strength real    NOT NULL DEFAULT 30,   -- S，天。spacing effect 的記憶強度
  ADD COLUMN recall_score    real    NOT NULL DEFAULT 1.0,  -- R = exp(-t/S)，0~1
  ADD COLUMN dormant_since   date,                          -- NULL = 清醒
  ADD COLUMN decay_exempt    boolean NOT NULL DEFAULT false;

-- S 必須為正（除以它算 R）；R 是機率，值域固定。兩條都是「算錯了要當場炸」而不是靜默失真。
ALTER TABLE memories
  ADD CONSTRAINT recall_strength_positive CHECK (recall_strength > 0),
  ADD CONSTRAINT recall_score_range       CHECK (recall_score >= 0 AND recall_score <= 1);

-- 休眠列是少數，部分索引即可；帶 status 條件與既有的 memories_pinned_active 一致。
CREATE INDEX memories_dormant ON memories (dormant_since) WHERE status = 'active';
