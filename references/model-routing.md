# Model Routing (eng-flow shared rules)

Two knobs per `agent()` / Agent-tool dispatch, not per skill — **model**（能力）與 **effort**（推理預算）。**兩者成對選定、一律明寫**（2026-08-06 校準）：挑 tier 就把該 tier 的 effort 一起帶上，不靠 omit 繼承 session。Sonnet 分兩檔，是這張表的重點——降成本先在 B1→B2 之間動，不是急著降到 haiku。

| Tier | Model | Effort | 用途 | How |
|------|-------|--------|------|-----|
| **Session** | 主線（settings.json `model`） | `high`（settings.json `effortLevel`） | 編排、架構決策、需求拆解 | 不由 `agent()` 設定；改 settings |
| **D** | fable（`claude-fable-5-1`） | 繼承 session（見下） | **只有** mao-brainstorm 2.5 與 mao-plan Draft Stage 的起草 — 一次性，不參與後續 | `model:"fable"` |
| **A** | opus（繼承主線） | `high` | 平行深度任務、跨模組驗證 — **節制使用** | Omit `model` + `effort:'high'` |
| **B1** | sonnet | `high` | 複雜商業邏輯、演算法 — 執行層首選工程師 | `model:"sonnet"` + `effort:'high'` |
| **B2** | sonnet | `medium` | Spec 明確的實作、標準重構 | `model:"sonnet"` + `effort:'medium'` |
| **C** | haiku | **不設** | 樣板、config、migration、文件 | `model:"haiku"`，`effort` 留空 |

B1 vs B2 的判準是**任務不確定性**，不是任務大小：要自己想出解法（演算法、跨模組互動、狀態機、並行/交易邏輯）→ B1；解法已寫在 spec/plan 裡、只是落地成 code → B2。C 層刻意不設 effort——樣板與文件不需要推理預算，交給模型自己的預設。

**D 層不是「比 A 更強的通用層」**（2026-09-01 加）。Fable 5.1 確實是更強的模型，但它在這張表裡**只有兩個合法呼叫點**：mao-brainstorm 的 Draft Stage（方案取捨＋設計骨架）與 mao-plan 的 Draft Stage（依賴圖＋切片＋task 骨架）。理由是成本形狀而非能力：

| | Input $/MTok | Output $/MTok |
|---|---|---|
| `claude-fable-5-1` | 10.00 | 50.00 |
| `claude-opus-5` | 5.00 | 25.00 |

貴一倍，而且**貴在 output**。起草階段最吃判斷（依賴順序、切片邊界、task 顆粒度、接縫風險）而 output 量小；補完階段最吃 output（每個 task 的完整測試碼與實作碼）而判斷已經定案。所以 D 層只承接前者，後者留給主線。**不要因為某個任務「很難」就升到 D**——那是 A 層的用途；D 是階段性的，不是難度性的。

**D 層一次性、不參與後續**：起草交付後 Fable 就退出，codex 共議、收斂、修訂全部由主線負責。它也不看 codex 的回覆——共議是主線與 codex 兩方。

**Effort 的已知限制（不要假裝已解決）**：Agent tool 只有 `model` 參數、**沒有 `effort`**，所以 D 層派工的 effort 繼承 session 的 `effortLevel`。這違反本文件「除 C 層外一律明寫」的規則，是工具限制不是疏忽。要明寫得改走 Workflow `agent()` 的 `opts.effort` 或具名 agent 的 frontmatter——skill 刻意不那樣做，因為它要能在沒有本機 `~/.claude/agents/` 的機器上照跑。**Fable 5.1 的 thinking 恆開**（`{type:"disabled"}` 與 `budget_tokens` 都回 400），所以「沒明寫 effort」不等於「沒有推理預算」，只等於「用 session 的檔位」。

## Rules

- **mao-execute pipeline**: implement 依任務性質選 B1 或 B2（plan 標記 architecture-level / high-uncertainty 的升 A）；spec-review / code-review 走 B2，安全 / 認證 / 資料完整性相關的升 A。
- **mao-review reviewer dispatch**: default B2（`model:"sonnet"` + `effort:'medium'`）。High-risk changes (security, auth, data integrity) → A（omit `model` + `effort:'high'`）。
- **Named user-level agents** (`~/.claude/agents/`): senior-reviewer=A, root-cause-debugger=A, implementer=B2（其定義就是「依明確 spec 落地」）, mechanical-scanner=C。These apply to Agent-tool dispatch only — Workflow `agent()` does NOT consult them; route Workflow stages explicitly with the table above.
- **Effort 寫在哪**：Workflow `agent()` 用 `opts.effort`；`~/.claude/agents/*.md` 用 frontmatter `effort:`。除 C 層外一律明寫——session 有自己的 effortLevel，omit 會讓 stage 悄悄繼承它、失去分層的意義。
- **Draft stage dispatch**: mao-brainstorm 2.5 與 mao-plan Draft Stage 走 D（`model:"fable"`），一次，之後不再出現。Fable 不可用時由主線自己走完該階段並在交付時講一句，**不要為此停下來問使用者**——它是加速器不是必要條件。
- When unsure: 升 tier（B2→B1→A），不要拆開 model 與 effort 的配對去單獨拉 effort；也不要用降 model 來省成本（能力降級是反向操作）。確定機械化才進 C。**D 不在這條階梯上**——它是階段性的路由，不是「A 之上的一格」，任務難度再高也不是升 D 的理由。
- **沿革**：2026-08-05 曾把 implement stage 單獨校準為 `effort:'high'`（理由：high→xhigh 對範疇明確任務邊際效益遞減、每輪思考延遲照付，平行化省下的時間不該被吃回去）。該結論已被本版吸收成 **B1**——差別是現在由「任務不確定性」決定 implement 走 B1 還是 B2，而不是整條 implement stage 一律 high。

## Codex Cross-Family Consultation (gpt-5.6)

`scripts/codex-review.sh` keeps a small local ledger under `$CODEX_REVIEW_STATE` (round count + payload snapshot per review line); it still writes nothing inside the repo. One call is **at most** one consultation — a repeat whose payload is byte-identical to the previous round is refused outright (`CODEX_REVIEW_FORCE=1` overrides). Two modes, two semantics:

| Mode | Semantics / caller | Invocation | Severity source |
|------|--------------------|------------|-----------------|
| diff (default) | **Second opinion** at mao-review / mao-execute closing, after all Required/Critical fixed — once per review round, extra rounds convergence-gated (see below) | `--severity <level> [--base <branch>]` | Highest original severity from the first-pass five-axis review (even if already fixed) |
| spec | **Co-design loop** in mao-brainstorm, once the design doc is saved, before the User Review Gate (convergence-gated; loop state lives in the doc's `## Cross-Check Log`) | `--doc <spec.md> --kind spec --severity <level>` | Claude's design-risk self-assessment: cross-system / security / data migration / irreversible → critical; normal feature → required; small local → optional |
| plan | **Co-design loop** in mao-plan, once the plan file is saved, before Execution Handoff; Codex follows the plan's `Spec:` line to cross-check coverage against the design doc | `--doc <plan.md> --kind plan --severity <level>` | Same design-risk self-assessment |

**Convergence protocol — no consultation caps (any mode).** Every consultation prompt makes codex end its reply with a single line, `收斂問句:<its most important open question>` — or `收斂問句:無` when nothing left would change the artifact. Claude judges continue/stop each round, and stop is the default: continue **only** when the round adopted Critical/Required changes codex hasn't seen, or the question is substantive (answering it would change the doc/code) AND in scope AND not already settled. A `無`, repeated, or scope-expanding question ends the loop (scope-expanding ones become *user call* / open questions for the user — never another round). Every extra round must shrink the open-question set. Tripwire: in doc mode the script prints a non-blocking `警示` at ≥6 `### Round` entries in the Cross-Check Log — read it as "force-converge now". Per-skill wording lives in mao-brainstorm / mao-plan / mao-review / mao-execute.

**Rate limit.** If codex reports a usage/credit limit the script prints `[codex-review] RATE_LIMITED:` and exits 0. That consultation did not happen: do **not** retry it, do **not** log a round for it, and carry straight on with whatever came next. The next time a consultation is due, call the script again as normal — being rate-limited once never disables codex for the rest of the flow.

**Input too large.** If the script answers `[codex-review] FAILED: 輸入過長,未送出`, the consultation did **not** happen and this is *not* a quota problem — the diff exceeds codex's input limit, so it will never be reviewed until the scope is narrowed. Unlike RATE_LIMITED you must not just carry on: re-run with a tighter `--base` (per-commit or per-theme), or review the high-risk files separately from the test-file bulk. Treating it as reviewed is a false pass.

Severity is an **input decided by the source** — never re-triaged by a weaker model. When in doubt, over-estimate — under-calling sends work that deserves deep review to a cheap luna scan. Model mapping (all modes, revised 2026-08-07 to cut token spend):

| Source severity | Codex model / effort |
|---------------------|----------------------|
| Critical | `gpt-5.6-sol` / medium |
| Required | `gpt-5.6-terra` / high |
| Optional / Nit / FYI | `gpt-5.6-luna` / max |
| (unspecified) | fallback `gpt-5.6-luna` / max |

The ladder walks the **model** down with severity (sol → terra → luna) and walks **effort** up to compensate. The previous mapping put both Critical and Required on the flagship's most expensive tiers (`sol/max`, `sol/high`), which was the dominant token cost. Caveat carried knowingly: `gpt-5.6-luna` is the nano tier — extra reasoning effort does not buy it flagship-level review depth, so anything that might actually matter should be called `required` or above, not left on luna. The unspecified-severity fallback now lands on that same bottom rung (it used to be the flagship): omitting `--severity` no longer buys a deep review, it buys the shallowest one. The script still prints a warning on omission — treat that warning as a caller bug to fix, not as a default to lean on.

**Effort ceilings per model** (source: the model catalog bundled in codex 0.146.0 — `supported_reasoning_levels` per slug, not a blog post; several third-party write-ups get this wrong):

| Model | Supported efforts | Default |
|---|---|---|
| `gpt-5.6-sol` | low, medium, high, xhigh, max, **ultra** | low |
| `gpt-5.6-terra` | low, medium, high, xhigh, max, **ultra** | medium |
| `gpt-5.6-luna` | low, medium, high, xhigh, max | medium |

So `luna/max` is luna's ceiling — `ultra` is not a valid setting there. `ultra` exists on sol *and* terra (it is not sol-exclusive), but it spawns parallel subagents and burns quota fast, which runs against the point of this mapping — do not reach for it without deciding the cost is worth it. Note the CLI does not validate effort against this catalog locally: an unsupported pair is sent to the server, so a bad combination surfaces as a request error at consultation time, not at call time.

Doc mode skips the base-branch / empty-diff gates; outside a git repo it continues with `--skip-git-repo-check` (sandbox is read-only — codex merely loses repo context). A missing `--doc` file or contradictory flags is a caller bug → exit 2, loud (environment gaps SKIP with exit 0, never blocking). Requires codex client >= 0.144.x + GPT-5.6 access; self-skips when codex is absent/unauthorized.

## Codex payload cost & telemetry (v1.17.0)

The model ladder above decides the **per-token price**. It says nothing about **how many tokens you send**, and measurement showed that was the dominant term: over 2026-08-20~24 the script ran 129 times, 107 of them diff mode with no round counting at all (median gap between calls on one branch: 5.0 minutes — i.e. per fix, not per round). One plan document was consulted 12 times in 52 minutes while its payload grew 4,929 → 26,758 characters, because each round's `## Cross-Check Log` entry was written back into the same file and the whole file was resent: 181,335 characters sent for a 26,758-character document.

Four mechanisms now bound that, all in `scripts/codex-review.sh`:

| Mechanism | What it does | Where it shows |
|---|---|---|
| Round ledger | counts consultations per review line (repo/mode/target) | non-blocking `警示: ...第 N 次諮詢`; doc warns at 6, diff at 3 |
| Payload trim | doc: only the last Cross-Check Log round; diff: excludes **build artifacts only** (`dist`/`build`/`vendor`/`node_modules`/minified/snapshots) | `已排除 N 字元未送出;其中建置產物: <files>` — never silent |
| Secret-shaped files | `.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa*`, `id_ed25519*` are withheld from the payload **and** flagged | `警示: 本次變更含疑似機密檔案,內容【未送出】也【未被複查】: <files>` |
| Dedup | refuses to send content identical to the previous round | `SKIP: 送出內容與上一輪...完全相同` |
| Session resume | **off by default**; when enabled, inside `CODEX_RESUME_TTL` (default **30s**, tightened from the 1500s originally planned — see the measurements below) resumes the same session and sends only the delta | header `resume(<id>) delta A/B 字元` |

**Why resume is off by default.** Codex sets `prompt_cache_key = session_id` and 0.148.0 exposes no override, so a fresh `codex exec` can never reuse the previous round's payload at the cached rate — resume is the only cache lever that exists. It also turns out to be unusable at the cadence reviews actually run at. Measured on `gpt-5.6-luna`:

| gap since previous round | session | input | cached | uncached | hit |
|---|---|---|---|---|---|
| — | fresh | 15,348 | 9,984 | 5,364 | 65.1% |
| 25 s | resume | 16,219 | 15,104 | **1,115** | **93.1%** |
| 100 s | resume | 17,004 | 9,984 | 7,020 | 58.7% |

At 25 s the history is cached and uncached input drops 79%. At 100 s only the static prefix is still cached, and because resume re-sends the history *including the previous assistant reply*, it costs ~30% **more** than a fresh call. The observed real-world gap between consultations is ~5 minutes, i.e. always in the losing region — so `CODEX_REVIEW_RESUME` defaults to `0`. Set it to `1` only for back-to-back rounds seconds apart (which is the per-fix pattern this release is trying to discourage). When enabled, each review line self-corrects: a resume round whose hit rate lands under 80% halves that line's resume window for next time.

Three things these measurements rule out, so nobody re-litigates them:

**(a) Payload layout / prefix alignment is not the problem.** The obvious hypothesis — that the short static instruction block (150–300 tokens, under the 1,024-token minimum) sits between the cached system prefix and a volatile payload, so nothing of ours ever forms a cacheable prefix — was tested directly: two **fresh** calls five seconds apart sharing an identical ~15,900-token prefix, differing only in a one-line tail. Both returned `cached_input_tokens: 9,984` — the system block and nothing else. A perfectly aligned, far-over-threshold identical prefix cached **zero** of our content. Reordering the payload (stable files first, changed files last) would therefore buy nothing.

**(b) Keeping a codex CLI process alive does not help.** The 100 s call resumed the session successfully and produced a coherent continuation, and still missed — the cache is server-side, not process-local.

**(c) A long-lived process saves no re-sending either.** Round 2's input ≈ round 1's input + round 1's output + delta, so codex re-sends the full history every turn; it does not use server-side conversation storage.

Taken together the operative rule is: **the same `prompt_cache_key` (i.e. the same session, i.e. resume) is a necessary condition for any of our content to cache, and even then the window is tens of seconds.** The always-warm 9,984-token block is codex's own system+tools prefix, shared by every codex user — not something a caller can earn.

**The constraint that makes resume work when it works:** it only turns *history* into cached input; the new message is always full price. A resume round must therefore send a **delta**, never the full payload. Do not "simplify" that away.

**Lockfiles are deliberately NOT excluded.** They were, in the first cut, purely for payload size. Codex's own cross-check flagged that as a supply-chain blind spot and it was right: the lockfile is where the resolved versions, transitive dependencies and integrity hashes live, so a clean manifest says nothing about whether the lockfile was tampered with. "We don't know whether it changed" is not the same as "it doesn't need review". Verified after the change: a planted `left-pad@0.0.0-evil` with `integrity: sha512-SUSPICIOUS` was caught on the first real run. A project that genuinely cannot afford its lockfile churn can add it to `CODEX_REVIEW_EXCLUDE` itself — that is an explicit, local decision, not a silent default.

**Secret-shaped files are withheld but never silent.** Two rules apply at once and they point in opposite directions: don't ship key material to an external service, and a `.env`/`*.pem` showing up in a diff is itself a violation worth surfacing. So those paths are kept out of the payload *and* reported loudly, rather than quietly dropped.

**Dedup is independent of resume.** The payload snapshot is written and compared on every call regardless of `CODEX_REVIEW_RESUME`; sending content identical to the previous round is refused outright. Turning resume off must not turn that off.

**Telemetry.** `codex exec --json` is used because human mode prints only `tokens used <total>` with no cached/input split — without the split there is no hit rate to speak of. Each call (including `FAILED` and `RATE_LIMITED`, which still burn input tokens) appends a row to `$CODEX_REVIEW_LOG` (default `~/.claude/cache/codex-review-usage.tsv`): `sent_chars, input_tokens, cached_input_tokens, output_tokens, reasoning_tokens, cache_hit_pct, session_mode, round, status, rc`. Read it with `bash scripts/codex-usage.sh [--since YYYY-MM-DD]`. **Track uncached input (`input − cached`), not total input** — that is the number that is actually billed at full rate.

**Security note.** `codex exec resume` has no `-s/--sandbox` flag (0.148.0), so the resume branch passes `-c sandbox_mode="read-only"` explicitly. A user `config.toml` may carry e.g. `[windows] sandbox = "elevated"`; leaving the sandbox to the environment on an unattended review call is a fail-open. Verified by the header codex prints for that call: `sandbox: read-only`. (Note `--strict-config` does **not** validate `-c` overrides — it only rejects unknown fields in `config.toml`, so it is not evidence that the key took effect; the header is.)
