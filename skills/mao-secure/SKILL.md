---
name: mao-secure
description: 安全加固。處理輸入驗證、認證、資料安全時使用。三層邊界防禦模型。
---

# Security Hardening

## Three-Tier Boundary System

### Always Do (Non-negotiable)
- **Parameterize queries** — never concatenate user input into SQL/queries
- **Validate at boundaries** — all external input (user, API, file) validated on entry
- **Secrets in environment** — never in code, logs, or version control
- **Encode output** — prevent injection when rendering user-provided data
- **Use framework auth** — don't roll your own authentication/encryption
- **Least privilege** — request minimum permissions needed

### Ask First (Context-dependent)
- Rate limiting on public endpoints
- IP allowlisting for admin functions
- Data encryption at rest
- Audit logging for sensitive operations
- Session timeout policies

### Never Do
- Store plaintext passwords
- Log sensitive data (tokens, passwords, PII)
- Trust client-side validation alone
- Disable security features for convenience
- Hardcode credentials or API keys
- Use deprecated crypto algorithms

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
