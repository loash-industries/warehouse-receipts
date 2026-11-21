---
name: deploy-sui-move-packages
description: "Fresh-publish one or more Sui Move packages in the armature stack to the testnet_wip environment, including cache patching for transitive deps that don't declare the env. Use when the user asks for: \"deploy move package\", \"publish move package\", \"redeploy move package\", \"deploy to testnet_wip\", \"publish to testnet\", \"deploy armature\", \"deploy armature_framework\", \"deploy armature_proposals\", \"deploy armature_world_bridge\", \"deploy armature_trading\", \"deploy armature_vault\", \"sui client publish\", \"move package deploy\"."
---

<!-- cortex-managed: generated from cortex-config skills/platform/deploy-sui-move-packages.md; edits here are overwritten -->

# Deploy Sui Move packages to testnet_wip

This file only makes the procedure discoverable. The procedure itself lives in the Cortex skill registry and is maintained there.

1. Get it: call the cortex MCP tool `search_skills` with `{ "id": "platform/deploy-sui-move-packages" }`. Its `content` is the full procedure.
2. Run each of its `required_context` queries with `search_context` before changing anything, and check its `state_locations`.
3. Follow the procedure. If it's wrong or out of date, fix `skills/platform/deploy-sui-move-packages.md` in cortex-config rather than working around it here.

If the cortex MCP server isn't connected, say so instead of improvising the procedure.

Add machine- or repo-specific notes below a `<!-- local: kept across regeneration -->` line; everything under it survives regeneration.
