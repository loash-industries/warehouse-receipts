# warehouse-receipts

SUI Move smart contract extension for EVE Frontier World Storage Units that converts deposited items into tradeable bearer tokens using MultiCoin.

## Core Capabilities

**Warehouse Receipt Minting** — Players deposit items from their owned inventory into an extension-controlled open inventory and receive a `multicoin::Balance` receipt in return. Receipts are standard MultiCoin balance objects — splittable, joinable, transferable, and tradeable.

**Receipt Redemption** — Anyone holding a receipt can redeem it to withdraw the underlying items from the exact Storage Unit it was minted at. The redeemer does not need to be the original depositor.

**Vault Initialization** — SSU owners perform a one-time setup: authorize the extension, freeze it (preventing revocation), and call `initialize_vault` to create the shared `Collection` + `VaultConfig`. To act on the new vault in the same PTB (e.g. register a hub operator), use the two-phase form instead: `new_vault` returns a `PendingVault` that downstream Move functions can read, and `share_vault` shares it before the transaction ends.

## Architecture

- **Framework**: SUI Move (edition 2024)
- **Dependencies**: `world` (EVE Frontier world-contracts), `multicoin` (Algorithmic-Warfare)
- **Packages**: `warehouse_receipts` (main), `tribal_vault` (tribal use-case variant)

## Key Modules

| Module | Visibility | Purpose |
|--------|-----------|---------|
| `receipt` | `public` | User-facing: vault init, deposit, redeem |
| `vault` | `public(package)` | Internal custody: wraps MultiCoin mint/burn behind `VaultConfig` |

## Key Types

| Type | Module | Description |
|------|--------|-------------|
| `VaultAuth` | `receipt` | Witness for StorageUnit extension authorization |
| `VaultConfig` | `vault` | Shared object binding a StorageUnit to its MultiCoin `CollectionCap` |
| `PendingVault` | `receipt` | No-ability hot potato holding a new, unshared `VaultConfig` + `Collection`; consumed only by `share_vault` |
| `Collection` | `multicoin` | Shared object tracking supply per asset type (1:1 with StorageUnit) |
| `Balance` | `multicoin` | Owned receipt token — splittable, joinable, transferable |

## Events

| Event | Emitted When |
|-------|-------------|
| `VaultInitializedEvent` | Vault created for a StorageUnit (`initialize_vault` / `new_vault`) |
| `ReceiptMintedEvent` | Items deposited, receipt issued |
| `ReceiptRedeemedEvent` | Receipt burned, items withdrawn |

## Deployed Environments

- `testnet_stillness` — original-id `0x134dfa96ad8bc50d4a2055cd78c91e264feb2fe79facf2d030f8bb466a80bb68`, published-at (v2) `0xcfd8ce37426e9ed1578795f538e8e5c6a5275d509c651d96586dfb877998194c` (built on world-contracts main `d33ff23` and multicoin rev `2772c26`). Type tags use the original-id; call v2-only functions (`new_vault`, `share_vault`, `pending_vault_*`) via published-at

Note: `tribal_vault` is not currently deployed; all prior environment records (testnet_utopia, testnet_stillness, testnet_wip) were cleared during redeployment.
