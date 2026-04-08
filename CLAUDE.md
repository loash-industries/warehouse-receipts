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
- Deployed to `testnet_utopia` and `testnet_stillness` environments
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
