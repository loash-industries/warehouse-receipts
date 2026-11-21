---
name: new-cycle-deployment
description: "Full cycle-rollover runbook — when EVE Frontier ships a new cycle (new world-contracts deployment), redeploy every dependent Move package in order and chase the new package IDs through signer-api, the triex-book indexer, etl-api, triex-app-api tenants, the SDK/MCP release, and the CDN coin registry, without mixing old-cycle and new-cycle data. Use when the user asks for: \"new cycle deployment\", \"cycle rollover\", \"deploy for cycle 7\", \"new cycle release\", \"redeploy everything on the new world\", \"new game service deployment\", \"world contracts redeployed\", \"new testnet environment rollout\"."
---

<!-- cortex-managed: generated from cortex-config skills/platform/new-cycle-deployment.md; edits here are overwritten -->

# Deploy the TriEx stack onto a new game cycle

This file only makes the procedure discoverable. The procedure itself lives in the Cortex skill registry and is maintained there.

1. Get it: call the cortex MCP tool `search_skills` with `{ "id": "platform/new-cycle-deployment" }`. Its `content` is the full procedure.
2. Run each of its `required_context` queries with `search_context` before changing anything, and check its `state_locations`.
3. Follow the procedure. If it's wrong or out of date, fix `skills/platform/new-cycle-deployment.md` in cortex-config rather than working around it here.

If the cortex MCP server isn't connected, say so instead of improvising the procedure.

Add machine- or repo-specific notes below a `<!-- local: kept across regeneration -->` line; everything under it survives regeneration.
