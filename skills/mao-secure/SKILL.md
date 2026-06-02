---
name: mao-secure
description: 安全加固。處理輸入驗證、認證、資料安全時使用。三層邊界防禦模型。
---

# Security Hardening

## Three-Tier Boundary System

### Always Do (Non-negotiable)
- **Parameterize queries** — never concatenate user input into SQL/queries [A.8.28]
- **Validate at boundaries** — all external input (user, API, file) validated on entry [A.8.26]
- **Secrets in environment** — never in code, logs, or version control [A.8.24/A.8.28]
- **Encode output** — prevent injection when rendering user-provided data [A.8.28]
- **Use framework auth** — don't roll your own authentication/encryption [A.8.5/A.8.24]
- **Least privilege** — request minimum permissions needed [A.5.15/A.8.2]

### Ask First (Context-dependent)
- Rate limiting on public endpoints
- IP allowlisting for admin functions
- Data encryption at rest
- Audit logging for sensitive operations
- Session timeout policies

### Never Do
- Store plaintext passwords (use bcrypt/Argon2id/scrypt) [A.8.5]
- Log sensitive data (tokens, passwords, PII) [A.8.15/A.8.11]
- Trust client-side validation alone [A.8.3]
- Disable security features for convenience (no `--no-verify`) [A.8.32]
- Hardcode credentials or API keys [A.8.24]
- Use deprecated crypto algorithms (MD5/SHA-1/DES/3DES/RC4; require TLS 1.2+) [A.8.24]

### ISO 27001 additions (load `mao-comply` for full self-check + gate deploy)
- **Env separation** — dev/test/prod isolated; no shared secrets; no unmasked prod data in non-prod [A.8.31/A.8.33]
- **Dependency hygiene** — pin versions + lockfile; SCA on every PR; no high/critical CVE unreviewed [A.8.7/A.8.8/A.5.21]
- **Source control** — branch protection: required review + green CI; only CI/CD pushes to prod [A.8.4]
- **Audit trail** — security-event logs immutable, not deletable by app accounts [A.5.33/A.8.15]
- **Change control** — prod change via CI/CD + change record, no manual console [A.8.9/A.8.32]

## Input Validation Principles

```
External data → Validate type, range, format → Sanitize → Use

Validate WHAT:
- Type (string, int, email, URL)
- Range (min/max length, numeric bounds)
- Format (regex for structured data)
- Business rules (exists in DB, authorized to access)

Validate WHERE:
- System boundaries only (API endpoints, file parsers, form handlers)
- Don't re-validate inside trusted internal code
```

## Authorization Pattern

```
1. Authenticate: who is this user?
2. Authorize: can this user do this action on this resource?
3. Validate: is the input well-formed?
4. Execute: perform the operation
```

Always check ownership: `if (resource.ownerId != currentUser.id) → 403`

## Security Review Checklist

- [ ] No secrets in code or version control
- [ ] All user input validated at entry points
- [ ] Queries parameterized (no string interpolation)
- [ ] Auth checked on all protected endpoints
- [ ] Error messages don't leak internal details
- [ ] Dependencies up to date (no known vulnerabilities)
- [ ] Sensitive data not logged
