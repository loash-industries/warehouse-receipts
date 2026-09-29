# warehouse-receipts

SUI Move smart contract extension for EVE Frontier World Storage Units that converts deposited items into tradeable bearer tokens using MultiCoin.

## Core Capabilities

**Warehouse Receipt Minting** — Players deposit items from their owned inventory into an extension-controlled open inventory and receive a `multicoin::Balance` receipt in return. Receipts are standard MultiCoin balance objects — splittable, joinable, transferable, and tradeable.

**Receipt Redemption** — Anyone holding a receipt can redeem it to withdraw the underlying items from the exact Storage Unit it was minted at. The redeemer does not need to be the original depositor.

**Vault Initialization** — SSU owners perform a one-time setup: authorize the extension, freeze it (preventing revocation), and call `initialize_vault` to create the shared `Collection` + `VaultConfig`.

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
| `Collection` | `multicoin` | Shared object tracking supply per asset type (1:1 with StorageUnit) |
| `Balance` | `multicoin` | Owned receipt token — splittable, joinable, transferable |

## Events

| Event | Emitted When |
|-------|-------------|
| `VaultInitializedEvent` | Vault created for a StorageUnit |
| `ReceiptMintedEvent` | Items deposited, receipt issued |
| `ReceiptRedeemedEvent` | Receipt burned, items withdrawn |

## Deployed Environments

- `testnet_stillness` — `0x134dfa96ad8bc50d4a2055cd78c91e264feb2fe79facf2d030f8bb466a80bb68` (built on world-contracts main `d33ff23` and multicoin rev `2772c26`)

Note: `tribal_vault` is not currently deployed; all prior environment records (testnet_utopia, testnet_stillness, testnet_wip) were cleared during redeployment.
