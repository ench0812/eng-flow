"""habits — 夢境從實際對話學到的「這個人怎麼用、怎麼答」。

**職責切分**：這個模組只做**機械統計**（數次數、比對工具呼叫、算一致率），語義判斷
（「這句話代表什麼規則」）留給夢境 skill 裡的 LLM。理由是同一條分工在既有架構已經成立：
audit 給訊號、skill 下判斷。把語義塞進 CLI 會得到一堆脆弱的正則，而且改不動。

因此 `scan()` 的輸出分兩類：
  * `auto`       —— 純統計就成立的，可直接寫入（簡語→動作、選項偏好的採納率）
  * `candidates` —— 要 LLM 讀原文才成立的（明講的規則、反覆的糾正）

**掃描必須是增量的**：transcript 會被續寫，重掃同一批檔案會讓 evidence_count 灌水，
「看過 3 次」變成「看過 30 次」，信心門檻就失去意義。位置記在 habit_scan_marks。
"""

from __future__ import annotations

import json
import pathlib
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field

import psycopg

# --- 門檻 -------------------------------------------------------------------
# 升到 act（可直接執行）的條件。三個都要成立，缺一不可：
ACT_MIN_EVIDENCE = 5       # 看過至少這麼多次
ACT_MIN_CONFIDENCE = 0.85  # 一致率（evidence / (evidence + counter)）
ACT_MIN_SPAN_DAYS = 7      # 首見到末見至少跨這麼多天——同一天連做五次不算習慣，那是一次工作

STALE_DAYS = 180           # 這麼久沒再出現就降回 suggest（不 retire，見 decay()）
SHORT_MSG_MAX = 20         # 「短簡語」的長度上限
MAX_ACTIONS_PER_TURN = 15  # 一輪跑超過這麼多種動作就不歸因——那是一段工作，不是一個簡語的意思
TERM_CANDIDATE_MIN = 3     # 簡語要被觀察到這麼多次才值得讓 LLM 花力氣判斷它的意思
MAX_EXAMPLES = 5           # 每則習慣保留幾個佐證

# 系統產生的偽 user 訊息。學它們等於學雜訊——這些不是使用者說的話。
NOISE_MARKERS = (
    "<local-command-caveat>", "<command-name>", "<command-message>",
    "<command-args>", "<local-command-stdout>", "Stop hook feedback:",
    "<system-reminder>", "[Request interrupted", "<user-prompt-submit-hook>",
    "Caveat: The messages below",
    # 以下是實測 328 個 transcript 後補的：它們都以 user 身分出現在 transcript 裡，
    # 但沒有一句是使用者打的字。不濾掉的話 directive 候選有一半是這些。
    "<task-notification>", "<task-id>", "<output-file>",
    "This session is being continued from a previous conversation",
    "Your task is to create a detailed summary",
)

# 明講的規則通常很短。長文多半是我派給 subagent 的 brief——那在子 agent 的 transcript 裡
# 也以 user 身分出現，內容還常含「不要規劃…」「一律…」這類詞，正好誤觸 DIRECTIVE_RE。
#
# 300 是看實際樣本訂的：使用者的規則陳述多在 100 字內（「以後可能出貨的產品都要透過
# warpgate 跳轉」45 字），而 subagent brief 都上千字。權衡也偏這一側——漏掉一條候選的
# 代價很小（下次還會再講），把 brief 當成使用者的規則則會學到錯的東西。
DIRECTIVE_MAX_LEN = 300

# 明講規則的訊號詞。抓到只是候選，要 LLM 讀原文才知道規則內容。
DIRECTIVE_RE = re.compile(r"以後|一律|每次都|習慣上|預設|記住|下次|不要再|請都")
CORRECTION_RE = re.compile(r"不對|錯了|不是這樣|應該是|應該要|改成|重來|你搞錯|反了")
RECOMMENDED_RE = re.compile(r"[（(](推薦|建議|Recommended)[）)]", re.IGNORECASE)
# AskUserQuestion 的答案格式：`"<問題>"="<選中的 label>"`，逐對解析
ANSWER_PAIR_RE = re.compile(r'"([^"]*)"\s*=\s*"([^"]*)"')


@dataclass
class Signal:
    kind: str
    pattern: str
    meaning: str
    evidence: int = 1
    counter: int = 0
    examples: list = field(default_factory=list)
    # 觀察到的日期範圍（YYYY-MM-DD）。**必須從 transcript 帶出來，不能用寫入當天**——
    # 用寫入日的話，一次匯入四個月的歷史資料會全部變成 span=0，
    # ACT_MIN_SPAN_DAYS 那條門檻於是對歷史資料永遠不成立（實測踩到）。
    first_seen: str | None = None
    last_seen: str | None = None


@dataclass
class ScanReport:
    files_seen: int = 0
    files_scanned: int = 0
    lines_consumed: int = 0
    auto: list = field(default_factory=list)         # list[Signal]
    candidates: list = field(default_factory=list)   # list[dict]


def transcript_root() -> pathlib.Path:
    return pathlib.Path.home() / ".claude" / "projects"


def _is_noise(text: str) -> bool:
    return any(m in text for m in NOISE_MARKERS)


def _user_text(msg_content) -> list[str]:
    """從一筆 user record 取出**使用者真的說的話**。

    tool_result 佔了 user record 的九成以上（實測 13969 / 14746），那是工具回傳不是發言；
    不濾掉的話統計會被工具輸出淹沒。
    """
    out = []
    if isinstance(msg_content, str):
        if not _is_noise(msg_content):
            out.append(msg_content)
    elif isinstance(msg_content, list):
        for c in msg_content:
            if isinstance(c, dict) and c.get("type") == "text":
                t = c.get("text", "")
                if t and not _is_noise(t):
                    out.append(t)
    return out


# 這些片段不是「動作」，是為了走到動作而寫的前置。實測第一版把它們當簽名，結果
# 「推」被拆成七種不同的 `cd ~/.claude`、`M=/c/...`、`echo "===`，完全學不到 git push。
#
# 分兩類，因為處理方式相反：
#   SKIP_SEG —— 這一整段都是前置（`cd /d/Projects/x` 剝掉 cd 只剩路徑，也不是動作）
#   STRIP    —— 只是修飾詞，剝掉之後**後面才是動作**（`do git push`、`sudo systemctl ...`）
_SKIP_SEG = re.compile(r"^(cd|echo|printf|export|set|local|source|\.|for|while|if|true|:|done|fi)$")
_STRIP = re.compile(r"^(do|then|else|time|sudo|nohup|exec)$")
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# 唯讀／輔助指令：**不是意圖**，是為了達成意圖而順手查看的東西。
#
# 為什麼要濾：一輪裡動輒十幾個 sed/grep/ls，把真正的動作稀釋掉。實測 328 個 transcript，
# 不濾的話「推」有 38 次觀察而最高票只佔 11%（`git add`），完全看不出它是什麼意思——
# 訊號被自己的過程淹沒。
_READONLY_HEAD = frozenset({
    "sed", "grep", "rg", "ls", "cat", "head", "tail", "wc", "awk", "find", "stat",
    "file", "which", "type", "du", "df", "ps", "env", "pwd", "date", "sleep", "test",
    "[", "jq", "sort", "uniq", "cut", "tr", "diff", "tree", "realpath", "dirname",
    "basename", "xxd", "od", "md5sum", "sha256sum", "column", "less", "more", "man",
})
_READONLY_GIT = frozenset({
    "status", "log", "diff", "show", "rev-parse", "branch", "ls-remote", "ls-files",
    "check-attr", "merge-base", "describe", "remote", "blame", "shortlog",
    "check-ignore", "rev-list", "cat-file", "ls-tree",
    # 注意 `config` 不在此列：`git config user.email x` 是寫入
})


def _is_readonly(sig: str) -> bool:
    parts = sig.split()
    if not parts:
        return True
    if parts[0] in _READONLY_HEAD:
        return True
    if parts[0] == "git" and len(parts) > 1 and parts[1] in _READONLY_GIT:
        return True
    return False


def _first_command(bash_input) -> str | None:
    """把一次 Bash 呼叫縮成一個可比對的動作簽名（前兩個詞）。

    `git push origin main` 與 `git push` 要算同一件事，`git commit` 不算。取前兩個詞是實測
    後的折衷：只取第一個詞會把所有 git 指令混成一類，取整串則因為參數不同而永遠湊不滿次數。

    **要跳過前置片段才找得到真正的動作**：實際的指令多半長成
    `cd /d/Projects/x && git push`、`B=$(mktemp); docker exec ...`——第一段是 `cd` 或變數
    賦值。只看第一段會把所有指令都學成 `cd <某路徑>`，那是純噪音（實測 328 個 transcript
    的第一版輸出幾乎全是這種）。
    """
    if not isinstance(bash_input, dict):
        return None
    cmd = (bash_input.get("command") or "").strip()
    if not cmd:
        return None
    for seg in re.split(r"[|&;\n]+", cmd):
        # 剝掉 subshell 括號：`( cd /d/x && git push )` 的第一段是 `( cd`，而 _SKIP_SEG 是
        # 精確比對、認不出 `(cd`，於是整段被當成動作，簽名變成 `( cd` 這種垃圾。
        parts = [p.strip("()") for p in seg.strip().split() if not p.startswith("-")]
        parts = [p for p in parts if p]
        while parts and (_ASSIGNMENT.match(parts[0]) or _STRIP.match(parts[0])):
            parts = parts[1:]              # 修飾詞：剝掉，後面才是動作
        if not parts or _SKIP_SEG.match(parts[0]):
            continue                        # 整段是前置：看下一段
        return " ".join(parts[:2])
    return None


def _iter_records(path: pathlib.Path, start_line: int):
    """逐行讀 jsonl，回傳 (行號, record)。壞行跳過——單一壞行不該讓整份 transcript 作廢。"""
    with path.open(encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if i < start_line:
                continue
            line = line.strip()
            if not line:
                continue
            try:
                yield i, json.loads(line)
            except Exception:
                continue


def _scan_file(path: pathlib.Path, start_line: int, acc: "_Accumulator") -> int:
    """掃一個 transcript，把訊號累進 acc。回傳消化到的行號。"""
    # 一句簡語之後我通常會跑好幾個指令：先 `git status` 看一下、再 `git push`。
    # 只歸因給第一個會學到「推 = git status」（實測就是這樣壞的）。改成收集這一輪的
    # **去重動作集合**，到下一句話才結算，每個動作各記一次。長期下來每次「推」都會出現的
    # 那個動作（git push）一致率最高，順手做的檢查只在部分輪次出現，自然被比下去。
    cur_short: tuple[str, str, str] | None = None   # (簡語, 出處, 日期)
    turn_actions: set[str] = set()
    askq: dict[str, dict] = {}
    askq_lines: dict[str, int] = {}     # tool_use_id -> 提問所在行，供安全續掃點回退
    last_line = start_line

    def settle():
        nonlocal cur_short, turn_actions
        if cur_short and turn_actions and len(turn_actions) <= MAX_ACTIONS_PER_TURN:
            short, where, when = cur_short
            for sig in turn_actions:
                acc.record_term(short, sig, when, where)
        cur_short, turn_actions = None, set()

    for i, r in _iter_records(path, start_line):
        last_line = i + 1
        t = r.get("type")
        msg = r.get("message") or {}
        content = msg.get("content")
        ts = (r.get("timestamp") or "")[:10]

        if t == "user":
            texts = _user_text(content)
            for txt in texts:
                s = txt.strip()
                if not s:
                    continue
                acc.real_messages += 1
                settle()          # 新的一句話進來，先結算上一句的動作
                # 問句不是指令，不該被當成「這句話代表某個動作」
                if len(s) <= SHORT_MSG_MAX and not re.search(r"[?？]", s):
                    cur_short = (s, f"{path.name}:{i}", ts)
                if len(s) > DIRECTIVE_MAX_LEN:
                    continue          # 太長的多半是 subagent brief，不是使用者在講規則
                if DIRECTIVE_RE.search(s):
                    acc.candidates.append({"kind": "directive", "when": ts,
                                           "where": f"{path.name}:{i}", "quote": s[:400]})
                elif CORRECTION_RE.search(s):
                    acc.candidates.append({"kind": "correction", "when": ts,
                                           "where": f"{path.name}:{i}", "quote": s[:400]})
            # AskUserQuestion 的答案
            if isinstance(content, list):
                for c in content:
                    if not (isinstance(c, dict) and c.get("type") == "tool_result"):
                        continue
                    q = askq.pop(c.get("tool_use_id"), None)
                    askq_lines.pop(c.get("tool_use_id"), None)
                    if not q:
                        continue
                    body = c.get("content")
                    ans = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
                    acc.record_choice(q, ans, ts, f"{path.name}:{i}")

        elif t == "assistant" and isinstance(content, list):
            for c in content:
                if not (isinstance(c, dict) and c.get("type") == "tool_use"):
                    continue
                name = c.get("name")
                if name == "AskUserQuestion":
                    inp = c.get("input") or {}
                    qs = inp.get("questions")
                    if isinstance(qs, str):
                        try:
                            qs = json.loads(qs)
                        except Exception:
                            qs = []
                    # **逐題保留選項，不要攤平成一個 pool。** 攤平的話「兩題、一題採納
                    # 一題拒絕」會被記成一次完整採納，而且兩題只算一個樣本——實測全量
                    # 332 檔：攤平算法 90/112 = 80.4%，逐題算法 148/197 = 75.1%，
                    # 樣本數少了 43%。而這是全系統唯一分子分母都機械數出來的習慣。
                    per_q = []
                    for q in (qs or []):
                        if isinstance(q, dict):
                            per_q.append({
                                "question": q.get("question") or "",
                                "labels": [o["label"] for o in (q.get("options") or [])
                                           if isinstance(o, dict) and o.get("label")],
                            })
                    if any(x["labels"] for x in per_q):
                        askq[c.get("id")] = {"questions": per_q}
                        askq_lines[c.get("id")] = i
                elif name == "Bash" and cur_short:
                    sig = _first_command(c.get("input"))
                    if sig and not _is_readonly(sig):
                        turn_actions.add(sig)
    settle()          # 檔案結束也要結算，否則最後一輪的動作全部丟失

    # **續掃點推進到底，只有未回答的 AskUserQuestion 才退回。**
    #
    # 這是一個取捨，兩邊都有代價：
    #   推進到底 —— 掃描時若某個 turn 只寫了一半（session 進行中），那個 turn 的 Bash 動作
    #               在下次掃描時歸因不到（cur_short 已隨上次掃描結束而消失）。
    #   退回中間 —— 最後一個已結算的 turn 會在下次掃描被**重算一次**，證據灌水。
    #               而防止灌水正是 habit_scan_marks 存在的唯一理由。
    #
    # 選推進到底，因為漏掉的只是 term 候選（本來就只是給 LLM 判讀的統計佐證，下次同樣的
    # 簡語還會再出現）；而灌水會直接讓 ACT_MIN_EVIDENCE 失效，那是授權門檻。
    #
    # **AskUserQuestion 是例外**：它是唯一能自動升到 act 的訊號，而一問一答本來就常落在
    # 不同的寫入批次裡。有未回答的問題就把續掃點退到提問那一行，讓它下次完整重讀。
    if askq_lines:
        return min(last_line, min(askq_lines.values()))
    return last_line


class _Accumulator:
    def __init__(self):
        self.real_messages = 0
        self.terms: dict[str, Counter] = defaultdict(Counter)
        self.term_examples: dict[str, list] = defaultdict(list)
        self.choice_taken = 0
        self.choice_total = 0
        self.choice_examples: list = []
        self.candidates: list = []
        self.dates: dict = {}

    def record_term(self, short: str, signature: str, when: str, where: str):
        self.terms[short][signature] += 1
        self.note_date("term", short, when)
        ex = self.term_examples[short]
        if len(ex) < MAX_EXAMPLES:
            ex.append({"when": when, "where": where, "quote": f"{short} → {signature}"})

    def note_date(self, kind: str, key: str, when: str):
        """記下這個訊號被觀察到的日期範圍。空字串（沒有 timestamp）忽略。"""
        if not when:
            return
        k = (kind, key)
        lo, hi = self.dates.get(k, (when, when))
        self.dates[k] = (min(lo, when), max(hi, when))

    def record_choice(self, q: dict, answer: str, when: str, where: str):
        """逐題記錄採納率。

        答案格式是 `Your questions have been answered: "問題"="選中的 label", ...`，
        可以精確解析出每題實際選了什麼，**不要對整段答案做子字串比對**——整段答案含問題
        原文，而問題常常回述選項字眼（目前這批資料剛好 0 次誤判，但機制上擋不住）。
        """
        picked = dict(ANSWER_PAIR_RE.findall(answer or ""))
        for item in q.get("questions", []):
            rec = [l for l in item["labels"] if RECOMMENDED_RE.search(l)]
            if not rec:
                continue          # 沒有推薦項的題目不計入這個統計（否則分母被灌水）
            self.choice_total += 1
            self.note_date("choice", "_", when)
            chosen = picked.get(item["question"])
            if chosen is None and len(picked) == 1 and len(q.get("questions", [])) == 1:
                chosen = next(iter(picked.values()))     # 單題時問題文字對不上也能救回
            if chosen is None:
                continue
            # **兩邊都要去掉推薦標記再比。** 實際的答案值是連標記一起回填的
            # （`"強調色要用哪一個？"="沿用青綠（建議）"`），拿去掉標記的 label 本體去比
            # 永遠不相等——第一版就是這樣，全庫 197 個樣本算出 0% 採納率。
            chosen_core = RECOMMENDED_RE.sub("", chosen).strip()
            for label in rec:
                core = RECOMMENDED_RE.sub("", label).strip()
                if core and core == chosen_core:
                    self.choice_taken += 1
                    if len(self.choice_examples) < MAX_EXAMPLES:
                        self.choice_examples.append({"when": when, "where": where,
                                                     "quote": core[:120]})
                    break


def scan(conn: psycopg.Connection, *, limit_files: int | None = None,
         reset: bool = False, commit_marks: bool = False) -> ScanReport:
    """增量掃描 transcript，產出訊號。**不寫入 habits**——寫入走 upsert()。

    **`commit_marks` 預設 False：預覽不得推進掃描位置。** 早期版本無論如何都寫 marks，
    於是 SKILL.md 教的順序（先 `--scan` 看、再 `--scan --apply` 寫）第二步必然掃到 0 行，
    輸出是 `files scanned=0 / candidates 0`，讀起來像「今晚沒有新東西」——實際上是預覽
    把位置吃掉了，證據永遠累加不到。
    """
    root = transcript_root()
    rep = ScanReport()
    if not root.is_dir():
        return rep

    marks = {}
    if not reset:
        with conn.cursor() as cur:
            cur.execute("SELECT path, mtime_ns, size_bytes, offset_line FROM habit_scan_marks")
            marks = {p: (m, s, o) for p, m, s, o in cur.fetchall()}

    acc = _Accumulator()
    # subagent 的 transcript（`agent-*.jsonl`）跳過：它們的 user 訊息是我派工的 brief，
    # 不是使用者說的話。實測 332 檔裡有 242 個是這種，貢獻 243 則訊息而 candidates/terms/
    # choice 全部為 0——純浪費掃描時間，而且是 DIRECTIVE_MAX_LEN 那條長度啟發式唯一擋著的
    # 誤判來源（一則 250 字又含「一律」的 brief 就會漏進候選）。
    files = sorted(f for f in root.rglob("*.jsonl") if not f.name.startswith("agent-"))
    if limit_files:
        # **依 mtime 取最近的，不是路徑字典序。** 檔名是隨機 UUID，字典序排出來的「最後 N 個」
        # 與「最近 N 個」交集為零（實測），使用者想快速看最近用法卻拿到一批陳年檔案。
        files = sorted(files, key=lambda f: f.stat().st_mtime)[-limit_files:]
    new_marks = []

    for f in files:
        rep.files_seen += 1
        try:
            st = f.stat()
        except OSError:
            continue
        prev = marks.get(str(f))
        start = 0
        if prev:
            pm, ps, po = prev
            if pm == st.st_mtime_ns and ps == st.st_size:
                continue                       # 完全沒動過
            start = po if st.st_size >= ps else 0   # 檔案變小＝被重寫，整份重掃
        consumed = _scan_file(f, start, acc)
        rep.files_scanned += 1
        rep.lines_consumed += max(0, consumed - start)
        new_marks.append((str(f), st.st_mtime_ns, st.st_size, consumed))

    # 簡語 → 動作：**只當候選，不自動寫入。**
    #
    # 這裡本來想用純統計自動學（「推」後面接什麼指令最多次），實測 328 個 transcript 後
    # 否決：「推」有 36 次觀察，最高票的 `git add` 只佔 14%、`git push` 11%；濾掉唯讀指令
    # 後最好的「推送」也只有 36%。門檻是 85%，差太遠。
    #
    # 原因是根本的：一句「推」之後是一整串工作（改檔、跑測試、commit、push），單一指令
    # 簽名代表不了意圖。再調參數只是硬湊一個湊不出來的數字。所以改成輸出統計佐證，
    # 由夢境的 LLM 讀上下文判斷「這個簡語是什麼意思」——與 directive/correction 同一條路。
    # 先接上掃描過程收集的候選（directive / correction），再補統計型的 term 候選。
    # **順序有意義**：早期版本在這之後才寫 `rep.candidates = acc.candidates`，把 term
    # 候選整批覆蓋掉——輸出看起來正常，只是永遠少了一類訊號。
    rep.candidates = list(acc.candidates)

    for short, sigs in acc.terms.items():
        total = sum(sigs.values())
        if total < TERM_CANDIDATE_MIN:
            continue
        lo, hi = acc.dates.get(("term", short), ("", ""))
        rep.candidates.append({
            "kind": "term", "when": f"{lo}..{hi}", "where": "(統計)",
            "quote": short,
            "observations": total,
            "top_actions": [[s, n] for s, n in sigs.most_common(5)],
        })

    if acc.choice_total:
        # meaning 是固定字串，**不可以把次數寫進去**——每晚的數字都不同，會讓唯一鍵
        # (kind, pattern, meaning) 每晚都插一列新的，統計就散掉了。次數由 evidence/counter 表達。
        lo, hi = acc.dates.get(("choice", "_"), (None, None))
        rep.auto.append(Signal(
            kind="choice",
            pattern="AskUserQuestion 有標(推薦)的選項時",
            meaning="傾向採納推薦項",
            evidence=acc.choice_taken,
            counter=acc.choice_total - acc.choice_taken,
            examples=acc.choice_examples,
            first_seen=lo, last_seen=hi))

    if new_marks and commit_marks:
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO habit_scan_marks(path, mtime_ns, size_bytes, offset_line) "
                "VALUES (%s,%s,%s,%s) ON CONFLICT (path) DO UPDATE SET "
                "mtime_ns=EXCLUDED.mtime_ns, size_bytes=EXCLUDED.size_bytes, "
                "offset_line=EXCLUDED.offset_line, scanned_at=now()", new_marks)
    return rep


def upsert(conn: psycopg.Connection, *, kind: str, pattern: str, meaning: str,
           evidence: int = 1, counter: int = 0, examples: list | None = None,
           scope: str = "global", project_id: str | None = None,
           first_seen: str | None = None, last_seen: str | None = None,
           source: str = "llm") -> str:
    """累加一則習慣的證據。同 (kind, pattern, meaning) 視為同一則，不新增列。

    `meaning` 是唯一鍵的一部分，所以同一簡語對到不同動作會各自成列——那才看得見實際的
    分佈（「推」9 次是 git push、1 次是別的）。一致率由 promote/render 跨列算。
    examples 只保留最近幾個，避免無限成長。

    **`source` 決定它能不能升到 act**（見 0005）：`auto` 是機械統計、`human` 是使用者確認過，
    兩者可升；`llm` 是夢境判讀，封頂在 suggest——因為那條路徑的證據數是判讀者自己填的，
    三道門檻對它形同虛設。

    **已被 `--retire` 的習慣不會因為再次出現而復活成原狀**：狀態留在 retired，只累加證據與
    `retired_count`。原本的無條件 `status='active', retired_reason=NULL` 會讓「使用者說別再學
    這個」被下一次掃描原地撤銷、理由還被抹掉——那是個無限循環，而使用者只會看到它又出現了。
    """
    ex = json.dumps(examples or [], ensure_ascii=False)
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO habits(kind, pattern, meaning, scope, home_project_id,
                                  evidence_count, counter_count, examples,
                                  first_seen, last_seen, source, evidence_trusted)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s::jsonb,
                       coalesce(%s::date, current_date), coalesce(%s::date, current_date),
                       %s::habit_source,
                       CASE WHEN %s::habit_source IN ('auto','human') THEN %s ELSE 0 END)
               ON CONFLICT (kind, pattern, meaning) DO UPDATE SET
                 -- 總數照收（顯示與一致率用）
                 evidence_count = habits.evidence_count + EXCLUDED.evidence_count,
                 -- **可信證據只認 auto/human 寫入的那部分。**
                 -- 單靠 source 欄位擋不住順序：先 llm 寫 evidence=99、之後一次真實 auto
                 -- 訊號把列升成 auto，那 99 筆自填的數字就掛在可信列上了（0006 的成因）。
                 evidence_trusted = habits.evidence_trusted + CASE
                   WHEN EXCLUDED.source IN ('auto','human') THEN EXCLUDED.evidence_count
                   ELSE 0 END,
                 -- 反例相反：任何來源的反例都要算。證據不可以被洗白。
                 counter_count  = habits.counter_count  + EXCLUDED.counter_count,
                 examples = (
                   SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM (
                     SELECT e FROM jsonb_array_elements(EXCLUDED.examples || habits.examples) e
                     ORDER BY 1 LIMIT %s) s),
                 -- 合併日期範圍：習慣的「持續多久」要跨掃描累積，不是每次覆蓋成今天
                 first_seen = least(habits.first_seen, EXCLUDED.first_seen),
                 last_seen  = greatest(habits.last_seen, EXCLUDED.last_seen),
                 -- source 只升不降：human 確認過的不會被之後的 llm 判讀降級
                 source = CASE WHEN habits.source = 'human' OR EXCLUDED.source = 'human'
                               THEN 'human'::habit_source
                               WHEN habits.source = 'auto' OR EXCLUDED.source = 'auto'
                               THEN 'auto'::habit_source ELSE habits.source END,
                 -- retired 要黏著：再出現只累加證據，不自動復活
                 status = habits.status,
                 retired_reason = habits.retired_reason,
                 updated_at = now()
               RETURNING id""",
            (kind, pattern, meaning, scope, project_id, evidence, counter, ex,
             first_seen, last_seen, source, source, evidence, MAX_EXAMPLES),
        )
        return str(cur.fetchone()[0])


def confidence(evidence: int, counter: int) -> float:
    total = evidence + counter
    return (evidence / total) if total else 0.0


def promote(conn: psycopg.Connection) -> list[tuple[str, str, str]]:
    """依門檻調整 autonomy。回傳 (pattern → meaning, 舊, 新)。

    **一致率要跨同一個 pattern 的所有列來算。** 同一個簡語可能對到多個動作，各自一列；
    只看單列的話「推」對到 git push 12 次會是 100%，完全看不見它另外 5 次做了別的事。
    分母是該 pattern 的全部觀察，分子是這一列——這才是「我這樣說的時候有多大機率是指這件事」。

    三個門檻都要過才升 act。**跨天數那條最容易被忽略**：同一天連做五次不是習慣，那是
    一次工作；沒有它的話，任何一次密集的操作都會在隔天變成「可直接執行」。

    **但門檻只在 `source` 不是 `llm` 時才有意義**（見 0005）：`term`/`directive`/`correction`
    三類不自動累加，證據數由夢境的 LLM 自己填，一次 `--add --evidence 39` 就三道全過。
    所以 `llm` 來源封頂在 suggest，要升 act 得是機械統計（`auto`）或使用者確認（`human`）。
    被否決過的（`retired_count > 0`）同樣不自動升，除非使用者親自確認。
    """
    changed = []
    with conn.cursor() as cur:
        cur.execute("SELECT kind::text, pattern, sum(evidence_count + counter_count) "
                    "FROM habits WHERE status='active' GROUP BY 1,2")
        totals = {(k, p): t for k, p, t in cur.fetchall()}

        cur.execute("SELECT id, kind::text, pattern, meaning, autonomy::text, evidence_count, "
                    "counter_count, (last_seen - first_seen) AS span, source::text, "
                    "retired_count, evidence_trusted "
                    "FROM habits WHERE status='active'")
        for (hid, kind, pattern, meaning, autonomy, ev, ct, span, source,
             retired_n, ev_trusted) in cur.fetchall():
            total = totals.get((kind, pattern), 0) or 1
            may_act = source in ("auto", "human") and (retired_n == 0 or source == "human")
            # **門檻吃的是 evidence_trusted，不是 evidence_count。** 後者含 LLM 自填的數字，
            # 而那正是這幾道門檻要擋的東西（見 0006）。
            ok = (may_act
                  and ev_trusted >= ACT_MIN_EVIDENCE
                  and (ev_trusted / total) >= ACT_MIN_CONFIDENCE
                  and (span or 0) >= ACT_MIN_SPAN_DAYS)
            want = "act" if ok else "suggest"
            if want != autonomy:
                cur.execute("UPDATE habits SET autonomy=%s, updated_at=now() WHERE id=%s",
                            (want, hid))
                changed.append((f"{pattern} → {meaning}", autonomy, want))
    return changed


def decay(conn: psycopg.Connection) -> list[str]:
    """久沒再出現的習慣降回 suggest。**刻意不 retire。**

    習慣與記憶的衰減語義不同：一則記憶久沒被查，多半真的不需要了；一個習慣久沒出現，
    很可能只是最近沒遇到那個情境（半年沒發版不代表發版流程變了）。所以只收回「可直接
    執行」的授權，樣態本身留著——真的過時了要由人或夢境明確 retire 並寫原因。
    """
    with conn.cursor() as cur:
        cur.execute(
            f"UPDATE habits SET autonomy='suggest', updated_at=now() "
            f"WHERE status='active' AND autonomy='act' "
            f"  AND last_seen < current_date - {STALE_DAYS} RETURNING pattern")
        return [r[0] for r in cur.fetchall()]


def retire(conn: psycopg.Connection, kind: str, pattern: str, reason: str) -> bool:
    """否決一則習慣。**理由同時留一份在 last_retired_reason**——`retired_reason` 是狀態的
    一部分（CHECK 綁著 status），而 last_retired_reason 是歷史：習慣日後再被觀察到時，
    報告要講得出「這條你在 X 時否決過，理由是 Y」，否則使用者只會看到它又冒出來。"""
    with conn.cursor() as cur:
        cur.execute("UPDATE habits SET status='retired', retired_reason=%s, "
                    "last_retired_reason=%s, retired_count = retired_count + 1, "
                    "autonomy='suggest', updated_at=now() "
                    "WHERE kind=%s AND pattern=%s AND status='active'",
                    (reason, reason, kind, pattern))
        return cur.rowcount > 0


def unretire(conn: psycopg.Connection, kind: str, pattern: str) -> bool:
    """把否決過的習慣放回來（使用者改變主意時的正式路徑）。

    存在的理由：`upsert` 現在不會自動復活 retired 的習慣，所以需要一個明確的入口——
    否則使用者只能改 DB。復活後一律回到 suggest 重新累積，`retired_count` 留著。"""
    with conn.cursor() as cur:
        cur.execute("UPDATE habits SET status='active', retired_reason=NULL, "
                    "autonomy='suggest', updated_at=now() "
                    "WHERE kind=%s AND pattern=%s AND status='retired'", (kind, pattern))
        return cur.rowcount > 0


HABITS_MAX_LINES = 80          # 常駐成本的硬上限。超過就只留信心最高的
HABITS_HEADER = """# 習慣（夢境自動維護，勿手改）

由 `/dream` 每晚從實際對話學到的用法。**改內容改 DB**（`memory habits`），
手改這個檔會在下次 `memory habits --export` 被覆蓋。

三條使用規則：

1. **CLAUDE.md 的明文規則優先。** 這裡是觀察，那裡是意圖；觀察可能只是樣本偏差。
   兩者矛盾時照規則做，並把矛盾寫進夢境報告，由使用者決定要改規則還是改行為。
2. **`act` 的習慣可以直接做，但要講一句依據**（「依過去 N 次的用法」）。
3. **可逆性把關不因習慣而鬆動。判準是一句話：能不能用一個指令把它完整還原？**
   不能，或**不確定**，就照既有規則確認——安全鐵律不是統計問題，而「還不知道」與
   「確認不需要」是兩件事（CLAUDE.md 安全鐵律第 4 條）。
   刻意不用封閉列舉：列舉在定義上 fail-open，`memory forget`、`move-scope`、覆寫正文、
   對規則檔的 commit 都不會出現在任何一份清單上，卻都收不回來。
4. **`推` 這類「一次做完一串」的習慣，變更集合含規則檔時要先給我看。**
   `CLAUDE.md` / `habits.md` / `skills/**` 若在這次要提交的檔案裡，先印 `--stat` 並確認。
   理由：夢境昨晚可能自動改過規則並 commit，而「早上說一句『推』」會把它推上去——
   使用者對「全自動改規則」的風險接受，隱含前提是「我早上會看報告」，這條路徑正好
   把那個檢查點消掉。
5. **以「先前那個動作」為對象的習慣（例如 `try again`）繼承該動作的可逆性等級**，
   不因為習慣本身是 `act` 就無條件重試。

一致率怎麼讀：分母是這個樣態被觀察到的總次數。**只有 `AskUserQuestion 有標(推薦)的選項時`
那條的分子分母都是機械數出來的**；其餘由判讀寫入的條目，100% 的意思是「判讀當下沒看到
反例」，不是統計結論——照著做而被糾正時，反例會累加、一致率會掉、`act` 會自動降回 `suggest`。
"""


def render_md(rows: list[dict]) -> str:
    """把習慣渲染成常駐檔。超過行數上限時**砍掉信心最低的**，並明講砍了幾條。"""
    act = [r for r in rows if r["autonomy"] == "act"]
    sug = [r for r in rows if r["autonomy"] != "act"]

    # 一致率的分母是同一個 pattern 的全部觀察，不是這一列自己——同一個簡語對到多個動作時
    # 只看單列會顯示 100%，把「另外那幾次做了別的事」藏起來。
    totals: dict = {}
    for r in rows:
        key = (r["kind"], r["pattern"])
        totals[key] = totals.get(key, 0) + r["evidence_count"] + r["counter_count"]

    def line(r: dict) -> str:
        total = totals.get((r["kind"], r["pattern"]), 0) or 1
        span = f'{r["first_seen"]}～{r["last_seen"]}'
        return (f'- **{r["pattern"]}** → {r["meaning"]}'
                f'（{r["evidence_count"]}/{total} 次，一致率 {r["evidence_count"] / total:.0%}，{span}）')

    body: list[str] = []
    if act:
        body.append("## 可直接執行")
        body.append("")
        body += [line(r) for r in act]
        body.append("")
    if sug:
        body.append("## 參考用（排序選項、補完意圖；動作仍照既有規則確認）")
        body.append("")
        body += [line(r) for r in sug]
        body.append("")

    head = HABITS_HEADER.splitlines()
    budget = HABITS_MAX_LINES - len(head) - 4
    dropped = 0
    if budget > 0 and len(body) > budget:
        # 由後往前砍（suggest 區的尾端＝信心最低），act 區永遠保留
        keep = []
        for ln in body:
            if len(keep) < budget or ln.startswith("#") or ln == "":
                keep.append(ln)
            else:
                dropped += 1
        body = keep
    out = head + [""] + ["<!-- HABITS:BEGIN -->"] + body + ["<!-- HABITS:END -->"]
    if dropped:
        out.append("")
        out.append(f"（另有 {dropped} 條信心較低的習慣未列出，`memory habits`（不帶動作）可看全部）")
    return "\n".join(out) + "\n"


def export_md(conn: psycopg.Connection, path) -> int:
    import pathlib as _p
    p = _p.Path(path)
    rows = listing(conn)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(render_md(rows), encoding="utf-8", newline="\n")
    return len(rows)


def listing(conn: psycopg.Connection, *, include_retired: bool = False) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT kind::text, pattern, meaning, evidence_count, counter_count, "
            "       autonomy::text, first_seen, last_seen, status, examples, "
            "       source::text, retired_count, last_retired_reason, evidence_trusted "
            "FROM habits " + ("" if include_retired else "WHERE status='active' ") +
            "ORDER BY autonomy DESC, evidence_count DESC, pattern")
        cols = [d.name for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]
