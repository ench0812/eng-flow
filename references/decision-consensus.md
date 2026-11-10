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
does not require another approval if already authorized; two models agreeing cannot supply missing
business intent, external facts or authorization. Explicit review-only requests remain read-only.
Never treat ten minutes of silence as choosing the recommended option, permission to skip an
issue, or permission to post an issue comment. Issue writes follow the user's existing authorization
or an explicitly invoked workflow, not the timeout.

## Fable arbitration before the user (user decision, 2026-11-10)

Claude main thread only. On a Codex main thread there is no Fable arbiter: the previous rule
applies and the disputed decision goes to the user.

**When.** Ask Fable once before interrupting the user when `codex-decide.sh --prefer <our option>`
exits `1`, `3` or `4` — whether Codex disagreed or could not be consulted (SKIP, RATE_LIMITED, shell
launch failure, a malformed reply). For Codex's inability this makes Fable the substitute second
opinion on this one decision only: it never replaces a codex-review round, and the delivery
cross-family review axis is unchanged — Fable is Claude-family. The decision itself never depends on
parsing Codex's output: proceeding always rests on our own option plus Fable's, or on a
codex-decide exit `0` (below).

**Not arbitrated.** Exit `2`: fix the caller. Exit `5` (Codex ruled 停下) and anything only the user
can supply go straight to the user: business intent, external facts, authorization, scope expansion
(including the review-loop scope stop), the safety iron rules, irreversible, destructive or
production actions.

**Before dispatching.**
- Record in the task log the `--prefer` value of the codex-decide call that triggered arbitration.
  That id is "our preferred option" below and cannot be changed after Fable replies.
- Codex chose our option but attached an objection: first follow the existing procedure — record the
  objection under the question file's「上一輪處置」and ask Codex once more; arbitrate only if that
  still exits `3`.
- If an experiment (a test, a measurement, a grep) can settle the question, run it instead, write the
  result into the question file as evidence and re-run codex-decide: proceed only on exit `0`;
  `1`, `3` or `4` arbitrate as usual; `5` goes to the user; `2` means fix the caller. The main thread
  never acts on its own reading of an experiment.
- A disagreement left by a doc/diff co-design loop has no question file and only free-form review
  text from Codex: write a question file in codex-decide format first (options with short
  alphanumeric ids, evidence, existing authorization, acceptance criteria and the
  `## 安全與可逆性聲明` section) and run `codex-decide.sh --prefer <our option>` on it. Exit `0` is
  consensus — no arbitration; `1`, `3` or `4` arbitrate as above using that question file; `5`
  goes to the user; `2` means fix the caller.

**Dispatch** `Agent(subagent_type: "eng-flow:tier-d-arbiter")` with each side's position and why the
other rejected it, and an explicit list of files to read: the question file itself plus every file
it relies on as evidence. For Codex's position, relay
its five lines verbatim when codex-decide printed them (the stderr line starting
`[codex-decide] codex 立場:` summarises them); say so when Codex gave none. Give the facts, not a
recommendation.

**Check the reply really came from Fable and that it read the files.** Open the subagent
transcript (`~/.claude/projects/<project-slug>/<session-id>/subagents/agent-<agent-id>.jsonl`):
apart from records Claude Code writes itself (`"model":"<synthetic>"`), every assistant record's
`message.model` must start with `claude-fable-`, including the record carrying the five lines (the
safety classifier silently reroutes a Fable subagent to Opus 4.8 or Opus 5). The five lines may be
at the end of the final text or of the hand-back tool call's message, whichever returned the report.
Every file on the dispatch list must have a successful Read whose tool result returned its content
(or a Grep whose result returned the relevant lines), and at least one of them must be an evidence
file other than the question file, unless the triggering codex-decide call carried
`--allow-inference`. A failed or empty read, a Grep with no match, or a Glob that only lists names
does not count; a later successful retry does. A transcript that cannot be found, another model, or a
listed file without such a result (依據 已讀 is then unsupported) sends the decision to the user.

**Proceed without the user** only when the reply ends with all five contract lines with legal values,
信心 高, 依據 已讀 (推論 only when the triggering codex-decide call carried `--allow-inference`), 異議 無, and:
- 裁定 is our preferred option: proceed — the main thread and Fable both support it;
- 裁定 is anything else — Codex's verdict, another listed option, or NEW (described under
  `## 新方案` with its id): first check it against the "Not arbitrated" list and update the question
  file's `## 安全與可逆性聲明` for it (anything in an excluded class goes to the user), add it to the
  question file if new, then run `codex-decide.sh --prefer <its id>` and proceed only on exit `0`.
  That applies codex-decide's own confidence and objection thresholds, and the release rests on its
  exit code alone. This confirmation is not a second arbitration, and it gets no re-ask: any exit
  other than `0` (including Codex being unreachable) goes to the user.

**Everything else goes to the user** with all positions, Fable's included: 無法裁決, 信心 中/低, any
異議 other than 無, missing or illegal lines (including 裁定 NEW without a `## 新方案` section and id),
Fable unavailable (ZDR, dispatch failure), or a reply that fails the transcript check. One exception:
when 無法裁決 names an experiment, run it, write the result into the question file and re-run
codex-decide (not a second arbitration); proceed only on exit `0`, otherwise go to the user.

**Termination and reporting.** One arbitration per decision: never ask Fable again about it and
never loop Fable and Codex. Record the question file, the positions, Fable's five lines, the
transcript check and the outcome in the task log, and list every item decided through arbitration
in the closing report (positions, ruling, reason) so the user can overturn it. Fable usage counts
against the shared weekly plan limit (at most half of it), so send it nothing these rules already
settle without it.
