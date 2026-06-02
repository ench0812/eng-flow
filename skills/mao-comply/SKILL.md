---
name: mao-comply
description: ISO 27001 合規查核與部署。需確認程式/變更是否符合 ISO 27001、處理稽核合規、或要把合規 git hook/CI gate 部署到專案時使用。
---

# ISO 27001 Compliance (dev)

Verify a change against ISO/IEC 27001:2022 dev controls, then deploy machine gates.
For full control detail + per-control dev actions see `~/.claude/docs/iso27001-dev.md`.

## Red Lines (never cross) — items 1-3 are also always-on in `CLAUDE.md`
1. No hard-coded secrets in code/config/Dockerfile/CI — secrets manager / env [A.8.24/A.8.28]
2. No secrets/PII in logs [A.8.15/A.8.11]
3. TLS 1.2+ in transit; AES-256 at rest; ban MD5/SHA-1/DES/3DES/RC4 [A.8.24]
4. Every PR peer-reviewed; no direct push to main; no `--no-verify` [A.8.4/A.8.28]
5. Least privilege; authz server-side (not UI-only); filter-by-permission before returning data [A.5.15/A.8.2/A.8.3]
6. dev/test/prod strictly separated; no shared secrets across env; devs never connect to prod directly [A.8.31]
7. No unmasked prod data/PII in non-prod — test data synthetic or masked [A.8.33/A.8.11]
8. Deps pinned + SCA on every PR; no merge on high/critical CVE without written risk acceptance [A.8.7/A.8.8/A.5.21]
9. MFA for all privileged, remote, and cloud-console access [A.8.2/A.8.5]
10. Audit logs immutable (not app-deletable); prod changes via CI/CD + change record, no manual console [A.5.33/A.8.9/A.8.32]

## Self-Check (answer at implementation time; every "no" = gap to close before ship)
- [ ] Zero secrets in code/config/CI? Secrets in a manager (not committed env)?
- [ ] TLS 1.2+ in transit, AES-256 at rest, no banned algorithms?
- [ ] Logs free of PII/secrets/sensitive stack traces?
- [ ] Input validated+rejected at boundaries? Queries parameterized? Output encoded?
- [ ] Authz enforced server-side; results filtered by permission before return?
- [ ] New user/service account = least privilege; privileged ops behind MFA?
- [ ] No unmasked prod data in dev/test/staging?
- [ ] Deps pinned + lockfile; SCA clean (no new high/critical)?
- [ ] ≥1 approved peer review; no `--no-verify`; linked change record; tested in staging?
- [ ] Audit logs immutable / not deletable by app accounts?

## Enforcement (machine layer)

**Automatic (this plugin's hooks, all projects):**
- `PreToolUse[Write|Edit]` blocks hardcoded secrets (gitleaks if installed, else regex) [A.8.24/A.8.28].
- `PreToolUse[Bash]` blocks `--no-verify` and `curl|wget … | sh` [A.8.32/A.5.21].
- False positive? add an `iso-scan:ignore` comment on that line. Low-risk paths (docs, tests, fixtures, lockfiles) are skipped.

**Per-project gate (run once per repo — covers human/terminal commits hooks can't see):**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/deploy-iso-gate.sh   # add --force to overwrite
```
Installs `.githooks/pre-commit` (secret scan + dependency audit), `.github/workflows/iso-compliance.yml` (same in CI), and sets `core.hooksPath`. Commit both so the team inherits the gate. For deepest local scanning, install `gitleaks`.

Related: `mao-secure` (build-time hardening), `mao-review` (review-time axis 4).
