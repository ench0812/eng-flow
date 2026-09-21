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
objection. If a substantive disagreement remains, present the precise unresolved choice and
recommendation to the user; pause only dependent work and continue independent authorized work.

Missing replies, tool errors, RATE_LIMITED, SKIP or unverified inference are not consensus.
Resolve a tool failure where feasible; otherwise disclose the missing second opinion and escalate
the disputed decision. Existing nonblocking review skips may continue unrelated, already-decided
work, but cannot authorize the disputed action.

For a routine choice inside already-authorized work, `scripts/codex-decide.sh --question <path>
--prefer <id>` asks the focused "which option" question and reports the outcome through its exit
code only: `0` consensus (proceed without interrupting), `3` no consensus, `4` RATE_LIMITED,
`1` FAILED, `2` caller contract error. Anything other than `0` escalates. A failed consultation
must never fall through to the preferred option — that would silently degrade the whole mechanism
into "do what I already wanted" the day the quota runs out.

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
