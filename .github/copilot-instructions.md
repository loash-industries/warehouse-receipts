<!-- cortex-managed: do not edit below this line -->
# GitHub Copilot Instructions — Loash Engineering

> **This file is managed by cortex-config and distributed automatically.**
> Do not edit it directly in this repo — changes belong in `cortex-config/standards/ai-tooling/copilot-instructions.md`.

---

## Cortex Knowledge Base

This org uses a shared AI knowledge base called Cortex. It contains documentation for every registered service,
org-wide coding conventions, infrastructure guides, and deployment patterns.

**Before answering questions about how the org works, or before writing new code, use the Cortex MCP tools.**

## MCP Tools Available

### `search_context`
Use this to understand any service, domain, or system in the org.
- "How does the auth service work?" → `search_context({ query: "auth service" })`
- "What events does signer-api publish?" → `search_context({ query: "signer-api events" })`
- "Which service owns the ledger?" → `search_context({ query: "ledger ownership" })`

### `get_conventions`
Use this before writing any new code. Always fetch conventions for the framework/language in use.
- NestJS service → `get_conventions({ framework: "nestjs" })`
- TypeScript file → `get_conventions({ language: "typescript" })`
- General org rules → `get_conventions({ scope: "general" })`

### `chronicle_changes`
Use this before every commit. It generates the changelog entry and patches `overview.md` if needed.
Always include the updated `.cortex/` files in the commit.
- `chronicle_changes({ service_id: "<from .cortex/manifest.yaml>", change_summary: "...", changed_files: [...] })`

## Priority Order for Context

1. **Cortex MCP tools** — always the first source for org knowledge and conventions
2. **`.cortex/overview.md`** — this repo's own description of what it does
3. **Source files** — only after the above don't answer the question

## Org Conventions Summary

- All services use structured JSON logging via Pino — never `console.log`
- Secrets come from environment variables only — never hardcoded
- Trunk-based development: short-lived branches, PR to `main`
- All NestJS services follow the module/service/controller pattern in `src/`
- Drizzle ORM for database access — no raw SQL queries outside migrations
