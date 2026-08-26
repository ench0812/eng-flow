-- 0002：memory_scope 由二值擴為四值，並把連結判準抽成共用函式。
--
-- 用 RENAME 而不是 ADD VALUE：'user' 與 'workspace' 從未使用（實測 0 列），改名可在同一個
-- 交易內立即使用（ADD VALUE 的新值不能在同交易使用），順便清掉死值。
-- 副作用一：enum 排序變成 global < machine < work < project。**那只是定義順序，沒有語意，
-- 不得依賴**（現況也無任何程式碼 ORDER BY scope）。
-- 副作用二：使用舊 label 的既有列會跟著改名——現況是 0 列，但測試要在隔離 schema 裡塞
-- fixture 驗證這個語義，不可靠「碰巧沒有」帶過。

ALTER TYPE memory_scope RENAME VALUE 'user'      TO 'machine';
ALTER TYPE memory_scope RENAME VALUE 'workspace' TO 'work';

-- 連結是否允許：判準是「持有來源 repo 的人是否必然也持有目標 repo」。
-- 通用 repo（global）是所有人都有的基底；本機與工作彼此獨立。
-- 抽成函式是因為有三個呼叫點：連結列插入、scope 改動後的重驗、以及 Python 端的 resolver。
CREATE FUNCTION link_allowed(s_scope memory_scope, s_home uuid,
                             t_scope memory_scope, t_home uuid,
                             k link_kind) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN k = 'supersedes' THEN s_scope = t_scope AND s_home IS NOT DISTINCT FROM t_home
    WHEN t_scope = 'global'  THEN true
    WHEN t_scope = 'machine' THEN s_scope = 'machine'
    WHEN t_scope = 'work'    THEN s_scope IN ('work', 'project')
    WHEN t_scope = 'project' THEN (s_scope = 'work')
                                  OR (s_scope = 'project' AND s_home = t_home)
    ELSE false
  END
$$;

-- 既有的連結守門改用共用函式；錯誤碼維持可分辨（呼叫端與測試都在比對字串）。
CREATE OR REPLACE FUNCTION trg_link_scope() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s memories%ROWTYPE; t memories%ROWTYPE;
BEGIN
  IF NEW.target_id IS NULL THEN RETURN NEW; END IF;    -- dangling 交給 audit 報
  SELECT * INTO s FROM memories WHERE id = NEW.source_id;
  SELECT * INTO t FROM memories WHERE id = NEW.target_id;
  IF link_allowed(s.scope, s.home_project_id, t.scope, t.home_project_id, NEW.kind) THEN
    RETURN NEW;
  END IF;
  IF NEW.kind = 'supersedes' THEN
    RAISE EXCEPTION 'cross_bank_supersede: % (%) -> % (%)', s.name, s.scope, t.name, t.scope;
  ELSIF s.scope = 'project' AND t.scope = 'project' THEN
    RAISE EXCEPTION 'cross_project_link: % (%) -> % (%)', s.name, s.scope, t.name, t.scope;
  ELSE
    RAISE EXCEPTION 'cross_repo_link: % (%) -> % (%)', s.name, s.scope, t.name, t.scope;
  END IF;
END $$;

-- 不變量 1：只有 global / work 能持有 tag。
-- 現行只有註解說 tag 屬於 global，沒有任何約束擋住；move-scope 會動 tag，缺約束就會留殘列。
CREATE FUNCTION trg_tag_scope() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s memory_scope; n text;
BEGIN
  SELECT scope, name INTO s, n FROM memories WHERE id = NEW.memory_id;
  IF s NOT IN ('global', 'work') THEN
    RAISE EXCEPTION 'tag_scope_forbidden: % 的 scope 是 %，不得持有 tag', n, s;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER memory_projects_scope
  BEFORE INSERT OR UPDATE ON memory_projects
  FOR EACH ROW EXECUTE FUNCTION trg_tag_scope();

-- 不變量 2+3：記憶的 scope / home 改動後，重驗它既有的 tags 與所有進出連結。
-- trg_link_scope 只在 memory_links INSERT 觸發，攔不住直接 UPDATE memories.scope。
--
-- DEFERRABLE INITIALLY DEFERRED：move-scope 要在同一交易內先清 tag、重建 link，最後才驗
-- 最終狀態；immediate 會被中間狀態擋下來。
-- **必須重讀當前列，不可用 NEW**：事件裡的 NEW 是【該次 UPDATE 當下】的值，不會自動變成
-- 交易末的值。同一交易內改兩次時，較早那次事件會拿中間狀態去判，把最終合法的結果誤擋下來。
CREATE FUNCTION trg_scope_revalidate() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cur_scope memory_scope; cur_name text; n int; r record;
BEGIN
  SELECT scope, name INTO cur_scope, cur_name FROM memories WHERE id = NEW.id;
  IF NOT FOUND THEN RETURN NULL; END IF;        -- 同交易內已被刪除，無須驗證
  IF cur_scope NOT IN ('global', 'work') THEN
    SELECT count(*) INTO n FROM memory_projects WHERE memory_id = NEW.id;
    IF n > 0 THEN
      RAISE EXCEPTION 'tag_scope_forbidden_after_move: % 的 scope 是 %，卻仍有 % 個 tag',
        cur_name, cur_scope, n;
    END IF;
  END IF;
  FOR r IN
    SELECT l.kind, s.name AS sname, s.scope AS sscope, s.home_project_id AS shome,
           t.name AS tname, t.scope AS tscope, t.home_project_id AS thome
    FROM memory_links l
    JOIN memories s ON s.id = l.source_id
    JOIN memories t ON t.id = l.target_id
    WHERE l.source_id = NEW.id OR l.target_id = NEW.id
  LOOP
    IF NOT link_allowed(r.sscope, r.shome, r.tscope, r.thome, r.kind) THEN
      RAISE EXCEPTION 'cross_repo_link_after_move: % (%) -> % (%)',
        r.sname, r.sscope, r.tname, r.tscope;
    END IF;
  END LOOP;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER memories_scope_revalidate
  AFTER UPDATE OF scope, home_project_id ON memories
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION trg_scope_revalidate();
