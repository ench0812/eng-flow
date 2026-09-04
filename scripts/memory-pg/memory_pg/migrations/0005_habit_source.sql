-- 0005：習慣的來源分級，以及「已否決」的黏著性。
--
-- 修的是 review 抓到的 critical：**三道升 act 的門檻（次數／一致率／跨天數）約束不到真正
-- 產生 act 的那條路徑。** `term`／`directive`／`correction` 三類設計上就不自動累加，只能由
-- 夢境的 LLM 用 `--add --evidence N --first-seen ... --last-seen ...` 寫入——也就是門檻的
-- 輸入由被門檻約束的 actor 自己填。一次 `--add --evidence 39` 就同時滿足三道門檻，隔天
-- `--promote` 直接升 act。實測：2026-09-04 寫入的四則 act 全部是這樣來的。
--
-- 分級之後，門檻只在「證據不是自己填的」時才有意義：
--   auto  —— 機械統計（目前只有 AskUserQuestion 採納率）。分子分母都數得出來，可升 act。
--   llm   —— 夢境判讀寫入。**封頂在 suggest**，因為它的證據數是判讀者自己給的。
--   human —— 使用者明確確認過（`--add --human`）。可升 act。
--
-- 另一條：`upsert` 的 ON CONFLICT 原本無條件 `status='active', retired_reason=NULL`，
-- 於是「使用者說別再學這個」被下一次掃描原地撤銷、理由還被抹掉，形成無限循環。
-- 改成保留 retired 狀態，並把理由留在 last_retired_reason 供報告引用。

CREATE TYPE habit_source AS ENUM ('auto', 'llm', 'human');

ALTER TABLE habits
  ADD COLUMN source habit_source NOT NULL DEFAULT 'llm',
  -- retired_reason 在復活時會被清空（狀態轉換的一部分），但理由本身要留著：
  -- 沒有它的話，同一則習慣被學回來時沒有任何線索說明它曾經被否決過、為什麼。
  ADD COLUMN last_retired_reason text,
  ADD COLUMN retired_count int NOT NULL DEFAULT 0;

-- 既有列的來源：0004 之後、0005 之前寫入的只有 choice 一條是機械統計，其餘都是判讀。
UPDATE habits SET source = 'auto' WHERE kind = 'choice';

-- 被否決過的習慣不得靠 upsert 悄悄復活成 act——復活後一律回到 suggest 重新累積。
-- 用 CHECK 而不是只靠應用層：這是「使用者的否決要黏著」的結構保證。
ALTER TABLE habits
  ADD CONSTRAINT habits_revived_not_act
    CHECK (NOT (retired_count > 0 AND autonomy = 'act' AND source <> 'human'));
