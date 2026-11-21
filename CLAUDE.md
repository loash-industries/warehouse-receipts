# CLAUDE.md

## About This Service

warehouse-receipts is a SUI Move smart contract extension for EVE Frontier World Storage Units.
It converts deposited items into tradeable bearer tokens using MultiCoin. For full context, see `.cortex/overview.md`.

## Cortex Integration

This repo is managed by Cortex. For full service context, conventions, and org-wide standards,
connect to the Cortex MCP server:

**MCP Server:** `http://cortex-relay-dev-api.trinary.exchange/mcp`

### Key Commands

- To get this service's full context: use the `search_context` tool with `service_id: "warehouse-receipts"`
- To get general org conventions: use the `getConventions` tool with `scope: general`

## Before Committing

**Always call `chronicle_changes` before committing.** This updates `.cortex/changelog.md`
and patches `overview.md` if the change is significant. Include the updated `.cortex/` files
in your commit alongside the code changes.

```typescript
// Call this before every commit:
chronicle_changes({
  service_id: "warehouse-receipts",
  change_summary: "brief description of what changed",
  changed_files: ["packages/contracts/sources/...", "packages/tribal_vault/sources/..."]
})
// Apply the returned changelog_entry and overview_patch to .cortex/ before committing
```

## Service-Specific Notes

- Two Move packages: `contracts` (warehouse_receipts) and `tribal_vault`
- `contracts` deployed to `testnet_stillness`; `tribal_vault` currently undeployed
- Dependencies: `world` (EVE Frontier) and `multicoin` (Algorithmic-Warfare)
- Move edition 2024

## Build & Test

```bash
cd packages/contracts
sui move build
sui move test

cd packages/tribal_vault
sui move build
sui move test
```

---
<!-- cortex-managed: do not edit below this line -->
# Cortex: Org-Wide Instructions

> Managed by cortex-config (`standards/ai-tooling/org-claude.md`) and distributed to every service repo. Edit it there, not here. Write repo-specific notes above the marker line.

Cortex is the org's shared knowledge base: every service's docs and API specs, coding conventions, infrastructure, and runbooks. Claude Code reaches it through the Cortex MCP server.

**What to do when isn't written in this file.** It comes live from cortex-relay, so it stays current without editing this file:
- The Cortex MCP server's instructions say which tool fits which question.
- The SessionStart hook (`.claude/hooks/cortex-session-digest.mjs`) adds a digest for this repo's service at session start: the services it talks to and their latest changes, the services that use it, its infrastructure, and the skills for it.

**Rules that don't change:**
- **This repo:** read `.cortex/overview.md` locally. It's fresher than search results about this repo. `.cortex/manifest.yaml` has its `name`, the `service_id` for Cortex calls.
- **Anything outside this repo** (another service's API, infrastructure, environments, secrets): ask Cortex before reading or grepping sibling repos.
- **Before committing:** draft the changelog entry with `chronicle_changes` and commit the `.cortex/` changes with your code. The commit hook (`.claude/hooks/cortex-commit-check.mjs`) blocks a commit with no changelog entry.
- **Org facts you learn** (how an environment behaves, where something really points) belong in a Cortex document, not only in private memory.
- **If Cortex isn't connected,** say so instead of guessing.

**Setup, once per machine:** create a key on the docs app's `/api-keys` page (https://cortex.trinary.exchange/api-keys). Connect the MCP server at `https://cortex-relay-dev-api.trinary.exchange/mcp` with it, and `export CORTEX_MCP_KEY=<key>` in your shell profile so the session hook can fetch the digest.
