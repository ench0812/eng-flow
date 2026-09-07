-- 0006：把「可信證據」與「總證據」分開存。
--
-- 0005 用單一 `source` 欄位擋 LLM 自填的證據升 act，但那擋不住**順序**：
--   1. LLM 以 (kind, pattern, meaning) 寫入 evidence=99、跨三個月的日期，source='llm'
--   2. 之後一次真實的 auto 訊號同鍵衝突 → source 升級成 'auto'
--   3. evidence_count 裡那 99 筆 LLM 自填的數字，現在掛在一列 source='auto' 上
--   4. promote() 拿它升 act
-- 「先 llm、後 auto」就繞過去了，而第一版只測了反向順序（auto 列被 llm 灌）。
--
-- 單一計數器 + 單一來源標記在結構上做不到這件事：來源是列的屬性，證據卻是逐次累加的，
-- 兩者的粒度不同。分成兩個計數器才對得起來——
--   evidence_count   總數（顯示、一致率的分子）
--   evidence_trusted 只有 auto/human 寫入的那部分（promote 的門檻只看它）

ALTER TABLE habits
  ADD COLUMN evidence_trusted int NOT NULL DEFAULT 0,
  ADD CONSTRAINT habits_trusted_le_total CHECK (evidence_trusted <= evidence_count);

-- 既有列的回填：0005 已把 kind='choice' 標成 auto，那是唯一機械統計的來源。
-- 其餘（llm 判讀）的可信證據一律 0——這正是它們不該自動升 act 的理由。
UPDATE habits SET evidence_trusted = evidence_count WHERE source IN ('auto', 'human');
