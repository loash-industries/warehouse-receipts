## 2026-10-04 — upgrade warehouse_receipts to v2 on testnet_stillness

Compatible upgrade of `warehouse_receipts` on testnet_stillness to version 2 (published-at `0xcfd8ce37426e9ed1578795f538e8e5c6a5275d509c651d96586dfb877998194c`; original-id `0x134dfa96...` and UpgradeCap `0x83fc5d72...` unchanged), shipping the two-phase vault init (`new_vault` / `PendingVault` / `share_vault`) and `ENotStorageUnitOwner`. Upgrade tx `7b77NZdXJavJGFhaaoVCDc2sGJmRyjRcMw3DFZZobVkc`, built with sui 1.81.0. Updated `Published.toml`.

## 2026-10-04 — review fixes for two-phase vault init

Replaced the misleading `EStorageUnitMismatch` with a dedicated `ENotStorageUnitOwner` (code 2) for the OwnerCap check in `new_vault`/`initialize_vault`, and documented `new_vault`/`share_vault` and the new error in the README and both integration guides. Hardened tests: the pending-vault test now asserts `VaultInitializedEvent` by type and contents via a test-only constructor, the redeem mismatch test uses a fully usable second SSU (online, own vault, stocked) so only the storage-unit guard can refuse it, and six inline second-SSU setups were consolidated into a `create_storage_unit_at(item_offset)` helper. All 27 tests pass.

## 2026-10-02 — add two-phase vault initialization via PendingVault

Added `new_vault` and `share_vault` to `receipt.move`, introducing a no-ability `PendingVault` hot potato so a newly created vault can be registered downstream (e.g. the triex hub operator adapter) within the same PTB before it is shared. `new_vault` emits `VaultInitializedEvent`; `initialize_vault` now delegates to `new_vault` + `share_vault` with the same signature, authorization and event. Compatible upgrade of the published package. Added tests for the pending-vault flow, the `to_ssu_owner = true` redeem branch and the storage-unit mismatch on redeem; `receipt` and `vault` are at 100% coverage (27 tests).

## 2026-09-29 — redeploy to testnet_stillness

Redeployed `warehouse_receipts` to testnet_stillness (`0x134dfa96...`) against the latest world-contracts main and freshly redeployed multicoin. Cleared stale deployment records for testnet_utopia, testnet_stillness, and testnet_wip across contracts and tribal_vault; tribal_vault is not yet redeployed. Updated `receipt_tests` to pass the `to_ssu_owner` argument (false) to `redeem_receipt`/`batch_redeem_receipt`; all 24 tests pass.

## 2026-04-08 — cortex onboarding

Added `.cortex/` directory with manifest.yaml and overview.md. Integrated with
Cortex MCP server for convention-aware development workflow.
