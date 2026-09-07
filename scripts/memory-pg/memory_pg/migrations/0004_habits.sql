-- 0004：習慣（habits）——夢境從實際對話學到的「這個人怎麼用、怎麼答」。
--
-- **為什麼不塞進 memories**：memories 的語義是「一則成立的事實」，habits 是「一個行為模式
-- 加上它的統計證據」。後者需要正反例計數、首見/末見、自主層級，而且它的生命週期由「還會不會
-- 再出現」決定，不是由「還成不成立」決定。硬塞會讓 memories 的每個消費端（search 排名、
-- export 索引、audit）都得判斷「這列是事實還是習慣」。
--
-- **信心是算出來的，不存欄位**：evidence / (evidence + counter)。存一份就會與計數漂移。

CREATE TYPE habit_kind AS ENUM (
  'term',        -- 簡語 → 動作。「推」= git push
  'choice',      -- 選項偏好。「有推薦項時傾向選它」「偏離時偏向做完整」
  'directive',   -- 明講的規則。「以後一律走 warpgate」
  'correction',  -- 反覆出現的糾正。「文字要白底黑框」
  'workflow'     -- 慣用流程。「部署完要跑 QC」
);

-- suggest = 只拿來排序選項與補完意圖；act = 高信心，可直接執行（仍受可逆性把關）
CREATE TYPE habit_autonomy AS ENUM ('suggest', 'act');

CREATE TABLE habits (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind            habit_kind NOT NULL,
  pattern         text NOT NULL,          -- 觸發樣態（要能被人一眼看懂何時適用）
  meaning         text NOT NULL,          -- 它代表什麼／該怎麼做
  scope           memory_scope NOT NULL DEFAULT 'global',
  home_project_id uuid REFERENCES projects(id),
  evidence_count  int NOT NULL DEFAULT 1, -- 支持的實例數
  counter_count   int NOT NULL DEFAULT 0, -- 反例數。只增不減，證據不可被「洗白」
  examples        jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{when, where, quote}]
  first_seen      date NOT NULL DEFAULT current_date,
  last_seen       date NOT NULL DEFAULT current_date,
  autonomy        habit_autonomy NOT NULL DEFAULT 'suggest',
  status          text NOT NULL DEFAULT 'active',
  retired_reason  text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT habits_pattern_nonempty CHECK (pattern <> '' AND meaning <> ''),
  CONSTRAINT habits_counts_sane      CHECK (evidence_count >= 0 AND counter_count >= 0),
  CONSTRAINT habits_status_values    CHECK (status IN ('active', 'retired')),
  -- retired 必須說明原因：一個習慣被收掉而沒有理由，下次掃描又會把它學回來
  CONSTRAINT habits_retired_has_reason CHECK ((status = 'retired') = (retired_reason IS NOT NULL)),
  CONSTRAINT habits_scope_project    CHECK (
    (scope = 'project' AND home_project_id IS NOT NULL) OR
    (scope <> 'project' AND home_project_id IS NULL)),
  -- 唯一鍵含 meaning：同一個簡語可能對到不同動作（「推」多半是 git push，偶爾是別的）。
  -- **不可以只用 (kind, pattern)**——那樣每次掃描都得決定「這次的意義蓋不蓋掉上次的」，
  -- 而單晚的樣本很小，meaning 會在兩個動作之間跳來跳去。分列存下來，一致率由
  -- 各列的 evidence 比出來，那才是實際觀察到的分佈。
  CONSTRAINT habits_unique_pattern   UNIQUE (kind, pattern, meaning)
);

CREATE INDEX habits_active ON habits (kind, autonomy) WHERE status = 'active';
CREATE INDEX habits_pattern ON habits (kind, pattern) WHERE status = 'active';
CREATE INDEX habits_last_seen ON habits (last_seen) WHERE status = 'active';

-- 掃描過的 transcript 位置。重跑不得重複累加證據——
-- 沒有這張表的話，夢境每晚重掃同一批檔案會讓 evidence_count 一路灌水，
-- 於是「看過 3 次」變成「看過 30 次」，信心門檻就失去意義。
CREATE TABLE habit_scan_marks (
  path        text PRIMARY KEY,
  scanned_at  timestamptz NOT NULL DEFAULT now(),
  mtime_ns    bigint NOT NULL,     -- 檔案變動就重掃（transcript 會被續寫）
  size_bytes  bigint NOT NULL,
  offset_line int NOT NULL DEFAULT 0   -- 已消化到第幾行，續寫只掃新增的部分
);
