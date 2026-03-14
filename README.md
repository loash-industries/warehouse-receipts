# Warehouse Receipts

A Sui Move extension for [World](https://github.com/evefrontier/world-contracts) StorageUnits that turns deposited items into tradeable bearer tokens using [MultiCoin](https://github.com/Algorithmic-Warfare/multicoin).

## Overview

Players deposit items from their owned inventory into a StorageUnit's extension-controlled open inventory and receive a `multicoin::Balance` receipt in return. The receipt is a standard MultiCoin balance object — it can be split, joined, transferred, or traded freely. Anyone holding the receipt can redeem it to withdraw the underlying items.

### Why Warehouse Receipts?

Before _warehouse receipts_, every behavior a Storage Unit needed - item trading, lending, escrow, guild hangars - had to be built into a single monolithic extension contract. Adding a new use case meant rewriting and redeploying the extension, and the SSU owner had to trust that one contract to handle everything.

Warehouse receipts decouple item custody from downstream logic by minting a _claim_ on an item deposited in an underlying storage unit. The extension's only job is converting items deposited into open inventory - into freely tradeable receipts of deposit. Once a player holds a receipt, they can interact with independent, composable systems item exchanges, tribe mission contracts, lending platforms, or escrow services. All without the SSU extension needing to know about any of them.

### Use Cases

- **Escrow services** — lock items and issue a receipt to the counterparty
- **Collateralized lending** — use receipts as on-chain collateral
- **Tradeable warehouse receipts** — list receipts on MultiCoin-based DEX pools
- **Gift vouchers / claim tickets** — mint and distribute redeemable tokens

## Architecture

```
┌──────────────────────────────────────────────────┐
│                 receipt.move                      │
│  (public interface — deposit, redeem, init)       │
│                                                   │
│  VaultAuth          deposit_for_receipt()         │
│  (extension          redeem_receipt()             │
│   witness)           initialize_vault()           │
└──────────────┬───────────────────────────────────┘
               │ public(package)
┌──────────────▼───────────────────────────────────┐
│                  vault.move                       │
│  (internal — mint/burn custody)                   │
│                                                   │
│  VaultConfig        create_vault()                │
│  (custodies          mint()                       │
│   CollectionCap)     burn()                       │
└──────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────┐
│              multicoin::multicoin                 │
│  Collection, CollectionCap, Balance               │
│  (split, join, transfer, mint, burn)              │
└──────────────────────────────────────────────────┘
```

### Modules

| Module | Visibility | Purpose |
|--------|-----------|---------|
| `receipt` | `public` | User-facing functions: vault initialization, deposit, and redeem |
| `vault` | `public(package)` | Internal custody layer: wraps MultiCoin mint/burn behind a `VaultConfig` |

### Key Types

| Type | Module | Description |
|------|--------|-------------|
| `VaultAuth` | `receipt` | Witness for StorageUnit extension authorization |
| `VaultConfig` | `vault` | Shared object binding a StorageUnit to its MultiCoin `CollectionCap` |
| `Collection` | `multicoin` | Shared object tracking supply per asset type (1:1 with StorageUnit) |
| `Balance` | `multicoin` | Owned receipt token — splittable, joinable, transferable |

## Flow

### Setup (SSU owner, one-time)

1. Call `authorize_extension<VaultAuth>` on the StorageUnit
2. Call `initialize_vault` — creates and shares the `Collection` + `VaultConfig`

### Deposit (any player with items in owned inventory)

1. Call `deposit_for_receipt` with the item `type_id` and `quantity`
2. Items move: **owned inventory → open inventory** (extension-controlled)
3. A `multicoin::Balance` receipt is minted and returned to the caller

### Redeem (anyone holding a receipt)

1. Call `redeem_receipt` with the `Balance` receipt
2. The receipt is burned and items move: **open inventory → redeemer's owned inventory**
3. The redeemer does not need to be the original depositor

### Receipt Operations (standard MultiCoin)

Receipts are standard `multicoin::Balance` objects:

```
balance.split(amount, ctx)   // Split into two balances
balance.join(other, ctx)     // Merge two balances of same type
transfer::public_transfer(balance, recipient)  // Transfer to another address
```

## Events

| Event | Emitted When |
|-------|-------------|
| `VaultInitializedEvent` | Vault created for a StorageUnit |
| `ReceiptMintedEvent` | Items deposited, receipt issued |
| `ReceiptRedeemedEvent` | Receipt burned, items withdrawn |

## Error Codes

| Constant | Module | Meaning |
|----------|--------|---------|
| `EStorageUnitMismatch` | `receipt` | VaultConfig or receipt doesn't match the target StorageUnit |
| `EWrongStorageUnit` | `vault` | Balance's collection doesn't match the VaultConfig's CollectionCap |

## Build & Test

```bash
cd packages/contracts
sui move build
sui move test
```
