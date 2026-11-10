# Resolve technical decisions before escalating

When an unresolved technical choice would otherwise interrupt the user, first give Codex the
concrete question, relevant evidence, alternatives, existing authorization and acceptance criteria.
Use the existing doc-review entrypoint; require an independent assessment, not agreement with a
preferred answer. Do not add a consultation to routine work whose decision is already clear.

Consensus means both assessments support the same concrete action and material objections have
been resolved with evidence. Within the user's authorized task, implement that decision and run
the relevant verification without another permission question. Record the evidence, decision and
verification in the existing task log. Agreement alone is not a test result.

Continue discussion only when new evidence or a material revision can reduce unresolved issues.
An empty/repeated convergence question ends discussion, but does not resolve an outstanding
objection. If a substantive disagreement remains, take it to Fable arbitration (below; Claude main
thread only); only what that does not settle goes to the user as the precise unresolved choice with every position and
your recommendation. Pause only dependent work and continue independent authorized work.

Missing replies, tool errors, RATE_LIMITED, SKIP or unverified inference are not consensus.
Resolve a tool failure where feasible; otherwise, for the disputed decision only, use Fable as the
substitute second opinion (below) and escalate to the user what that does not settle, disclosing
the missing Codex opinion. This never substitutes for a codex-review round (spec, plan or diff).
Existing nonblocking review skips may continue unrelated, already-decided work, but cannot
authorize the disputed action.

For a routine choice inside already-authorized work, `scripts/codex-decide.sh --question <path>
--prefer <id>` asks the focused "which option" question and reports the outcome through its exit
code only: `0` consensus (proceed without interrupting), `3` no consensus, `4` RATE_LIMITED,
`1` FAILED, `2` caller contract error, `5` Codex ruled 停下 (it judges the decision to fall under the
safety iron rules or to be irreversible). Anything other than `0` escalates: `2` means fix the
caller; `5` goes straight to the user and is never arbitrated — whether a decision falls in an
excluded class is itself a question two Claude-family models must not overrule Codex on; `1`, `3`
and `4` go to Fable arbitration first (below; Claude main thread only), then to the user. A failed consultation
must never fall through to the preferred option — that would silently degrade the whole mechanism
into "do what I already wanted" the day the quota runs out.

A launch failure of codex's own shell is also `3`, **even with `--allow-inference`** (added 2026-10-14).
The script reads the `--json` event stream; one `command_execution` item with `status=failed`,
`exit_code=-1` and an output that *starts with* `Failed to create unified exec process` or
`CreateProcess…failed` is enough — whole-text matching is deliberately not used, since an
`agent_message` may quote those strings. In that case codex never read the question's files, yet the
reply can still be perfectly formatted, carry all five contract lines and even claim 已讀, so the
verdict is unverified inference no matter how it is labelled; `--allow-inference` only excuses a
decision that has no code to read, not a read that failed. **The price:** the count includes
failures that codex later retried successfully, so an intermittent launch failure still yields `3`
and interrupts the user although the final reply may have been fine. Clear the cause (see the
diagnostic notes in `scripts/codex-review.sh`) and re-run; do not relax the check to avoid the
interruption.

The reply must carry all five contract lines (裁定 / 信心 / 依據 / 理由 / 異議) with 信心 in
高|中|低 and 依據 in 已讀|推論. A missing or out-of-range field is no consensus, never a default:
a truncated reply carrying only `裁定:` would otherwise leave the confidence and objection checks
both inert and pass. 依據 of 推論 is likewise no consensus by default, matching "unverified
inference are not consensus" above; pass `--allow-inference` only for a choice that genuinely has
no code to read (pure sequencing), which names the exception instead of silently allowing it. The
script also refuses any question file without a `## 安全與可逆性聲明` section, so the
irreversibility check cannot be skipped by omission.

Check authorization from the actual request and session history. A production/security label alone
does not require another approval if already authorized; models agreeing can never supply missing
authorization or scope, and business intent or external facts only through the user's own precedent
(Fable arbitration below). Explicit review-only requests remain read-only.
Never treat ten minutes of silence as choosing the recommended option, permission to skip an
issue, or permission to post an issue comment. Issue writes follow the user's existing authorization
or an explicitly invoked workflow, not the timeout.

## Fable arbitration before the user (user decisions, 2026-11-10)

**Goal.** Fable takes over as many decisions as it can, so the user is interrupted only for what
genuinely needs them; a gate so strict that most cases still reach the user defeats the purpose. It
also learns how the user decides, from the user's past rulings, and that learning widens what it can
settle on its own. Claude main thread only: on a Codex main thread there is no Fable arbiter and the
previous rule applies.

**What Fable may decide.** Anything that would otherwise interrupt the user, except the reserved list:
- a technical disagreement — `codex-decide.sh --prefer <our option>` exits `1`, `3` or `4` (Codex
  disagreed or could not be consulted), or a disagreement left by a doc/diff co-design loop;
- a requirement or intent question the main thread would otherwise ask the user (what they want,
  priorities, trade-offs, an external fact) — **only when precedent covers it** (see Precedent).
  Without precedent it goes to the user, and the user's answer is recorded as precedent (Record).
  A critical requirement boundary goes to the user unless precedent answers that very question.
For Codex's inability Fable is the substitute second opinion on that decision only: it never
replaces a codex-review round, and the delivery cross-family review axis is unchanged — Fable is
Claude-family.

**Reserved for the user (never arbitrated).** Irreversible, destructive or production actions;
expanding authorization or scope (including the review-loop scope stop and moving work out of an
issue's scope); anything touching the safety iron rules; codex-decide exit `5` (Codex ruled 停下).
Exit `2` means fix the caller.

**Before dispatching.**
- Codex chose our option but attached an objection: first follow the existing procedure — record the
  objection under the question file's「上一輪處置」and ask Codex once more; arbitrate only if that
  still exits `3`.
- If an experiment (a test, a measurement, a grep) can settle the question, run it instead, write the
  result into the question file and re-run codex-decide: exit `0` proceeds; `1`, `3` or `4` go to
  arbitration (if this decision has not been arbitrated yet) or to the user; `5` goes to the user. The
  main thread never acts on its own reading of an experiment.
- Every arbitration works from a question file in codex-decide format (options with short
  alphanumeric ids, evidence, existing authorization, acceptance criteria and the
  `## 安全與可逆性聲明` section). A doc/diff disagreement or an intent question gets one written first;
  a doc/diff disagreement also gets one `codex-decide.sh --prefer <our option>` run (exit `0` is
  consensus — no arbitration). Record that `--prefer` id in the task log: it is "our preferred
  option" below and cannot change after Fable replies.
- Arbitrate only what would really interrupt the user; Fable usage counts against the shared weekly
  plan limit (at most half of it).
- **Precedent.** Only a ruling the user made counts, on the same kind of question:
  - a memory recording the user's decision or preference (usually kind `decision`, or a description
    marking it as the user's ruling or feedback) — find them with `~/.claude/scripts/memory search "<2–4 key terms>"` two or three times
    with different terms;
  - an intent-mapping entry in `~/.claude/habits.md` (an 意圖對照 line) that answers the same kind of
    question. Behaviour-tendency statistics there (for example how often the user takes the
    recommended option) are reference only, never precedent: they would let Fable pick the
    recommended option for the user, which silence never authorizes;
  - an arbitration record carrying the user's `overturn`, `user_answer` or explicit `user_accepted`.
    Search them with the path pointed at `~/.claude/cache/arbitration` and `glob: "*.json"` (`.gitignore`
    hides `cache/` from a Grep rooted at `~/.claude`; the glob skips the retro's calibration files). An arbitration Fable executed that the user never answered is
    reference only — silence is not acceptance, and Fable's own rulings must not pile up into "the
    user's precedent".
  When rulings conflict, the newest user ruling wins, and current AGENTS.md / skill text overrides an
  older remembered ruling. A precedent about an external fact (a deadline, a budget, the peer's
  version) counts only if it still holds for this situation; when that cannot be confirmed, ask the
  user.

**Dispatch** `Agent(subagent_type: "eng-flow:tier-d-arbiter")` with each side's position (Codex's
five lines verbatim when it gave them, and any objection Codex raised that names a reserved class —
ask Fable to address it), the main thread's preferred option, and an explicit list of file paths to
read: the question file, its evidence files and the precedent files. Give the facts, not a
recommendation.

**Check the reply really came from Fable and that it read the files.** Open the subagent
transcript (`~/.claude/projects/<project-slug>/<session-id>/subagents/agent-<agent-id>.jsonl`):
apart from records Claude Code writes itself (`"model":"<synthetic>"`), every assistant record's
`message.model` must start with `claude-fable-`, including the record carrying the contract lines (the
safety classifier silently reroutes a Fable subagent to Opus 4.8 or Opus 5). The lines may be at the
end of the final text or of the hand-back tool call's message. The question file, every evidence
file on the dispatch list (the code and documents the decision rests on — not only the main thread's
summary of them) and every precedent file Fable cites must have a successful Read whose result
returned content, or a Grep whose result returned the relevant lines (a failed or empty read, a Grep
with no match, or a Glob that only lists names, does not count; a later successful retry does). A
transcript that cannot be found, another model, or a required file without such a read sends the
decision to the user.

**Proceed without the user** when the reply ends with the six contract lines (裁定 / 信心 / 依據 /
判例 / 理由 / 異議) with legal values, and all of these hold:
- 信心 is 高 or 中;
- 依據 is 已讀 — 推論 only for a technical question whose triggering codex-decide call carried
  `--allow-inference`. 已讀 needs independent evidence beyond the main thread's own question file:
  for a technical question at least one evidence file (the actual code or document) read
  successfully, unless the triggering call carried `--allow-inference`; for an intent question the
  qualifying precedent it cites;
- 判例 is 無 or a 、-separated list of paths each exactly matching a path on the dispatch list (any
  other text is an illegal line); for an intent question it names at least one qualifying precedent
  (see Precedent) that Fable read. A technical disagreement needs no precedent: the evidence decides it;
- 裁定 is a listed option or NEW (described under `## 新方案` with its id). If it is not our preferred
  option, first check it against the reserved list and add its own safety-and-reversibility statement
  to the question file (why it is not an iron-rule or irreversible action, how to undo it if wrong);
  anything reserved goes to the user;
- neither 理由 nor 異議 says the ruling falls in a reserved class (irreversible, destructive,
  production, authorization or scope, safety iron rules). A 理由 that only answers another side's
  concern and shows the ruling is not in such a class does not trigger this; when unsure, go to the
  user. Any other 異議 does not block: record it and report it.
Then execute the ruling and run the relevant verification.

**Everything else goes to the user** with all positions, Fable's included: 無法裁決, 信心 低, missing
or illegal lines, a NEW option without `## 新方案` and id, an intent question without qualifying
precedent, Fable unavailable (ZDR, dispatch failure), a failed transcript check, or a reserved class.
When 無法裁決 names an experiment, run it, write the result into the question file and re-run
codex-decide (not a second arbitration): proceed only on exit `0`, otherwise go to the user.

**Record, report, learn.**
- One arbitration per decision; never loop Fable and Codex.
- Write one JSON file per arbitration with the Write tool to
  `~/.claude/cache/arbitration/<YYYYMMDD-HHMMSS>-<slug>.json`: `id`, `date`, `project`, `kind`
  (`technical` | `intent`), `question` (one sentence), `question_file`, `options`, `preferred`,
  `codex` (its five lines or `null`), `fable` (the six lines), `precedents` (paths), `outcome`
  (`executed` | `user`), `reason` (for `user`: `reserved`, `undecided`, `low-confidence`,
  `no-precedent`, `illegal-reply`, `transcript-check` or `unavailable`), `executed_option` (the
  option id carried out, or `null`).
- A requirement question asked directly because no precedent covers it gets a record too, with
  `fable: null`, `outcome: user` and `reason: no-precedent`, so the answer has somewhere to land.
- List every arbitration in the closing report with its id, all positions, the ruling and its reason,
  so the user can overturn it.
- Every user answer becomes precedent. When the user answers an escalated question, add
  `"user_answer": {"date", "choice", "reason"}` to its file; when the user overturns an executed
  ruling, add `"overturn": {"date", "user_choice", "reason"}`; when the user explicitly confirms one,
  add `"user_accepted": {"date"}`. For an answer or an overturn, also record the user's ruling with
  `memory write`／`memory learn` as a decision memory (search first; one memory per kind of question,
  updated rather than duplicated), then run `memory edit <name> --no-decay --reason ...` so a
  rarely-needed correction does not fade — write and learn have no such flag. A ruling about an
  external fact also gets `--review-by`, so `memory audit` reports it overdue once it may no longer hold.
  That memory is the precedent the next similar question is judged by.
- The weekly retro calibrates Fable against the user's past answers (retro skill, section 0b).
