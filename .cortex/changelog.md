## 2026-10-02 — add two-phase vault initialization via PendingVault

Added `new_vault` and `share_vault` to `receipt.move`, introducing a no-ability `PendingVault` hot potato so a newly created vault can be registered downstream (e.g. the triex hub operator adapter) within the same PTB before it is shared. `new_vault` emits `VaultInitializedEvent`; `initialize_vault` now delegates to `new_vault` + `share_vault` with the same signature, authorization and event. Compatible upgrade of the published package. Added tests for the pending-vault flow, the `to_ssu_owner = true` redeem branch and the storage-unit mismatch on redeem; `receipt` and `vault` are at 100% coverage (27 tests).

## 2026-09-29 — redeploy to testnet_stillness

Redeployed `warehouse_receipts` to testnet_stillness (`0x134dfa96...`) against the latest world-contracts main and freshly redeployed multicoin. Cleared stale deployment records for testnet_utopia, testnet_stillness, and testnet_wip across contracts and tribal_vault; tribal_vault is not yet redeployed. Updated `receipt_tests` to pass the `to_ssu_owner` argument (false) to `redeem_receipt`/`batch_redeem_receipt`; all 24 tests pass.

## 2026-04-08 — cortex onboarding

Added `.cortex/` directory with manifest.yaml and overview.md. Integrated with
Cortex MCP server for convention-aware development workflow.
