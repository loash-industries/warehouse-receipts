## 2026-09-29 — redeploy to testnet_stillness

Redeployed `warehouse_receipts` to testnet_stillness (`0x134dfa96...`) against the latest world-contracts main and freshly redeployed multicoin. Cleared stale deployment records for testnet_utopia, testnet_stillness, and testnet_wip across contracts and tribal_vault; tribal_vault is not yet redeployed. Updated `receipt_tests` to pass the `to_ssu_owner` argument (false) to `redeem_receipt`/`batch_redeem_receipt`; all 24 tests pass.

## 2026-04-08 — cortex onboarding

Added `.cortex/` directory with manifest.yaml and overview.md. Integrated with
Cortex MCP server for convention-aware development workflow.
