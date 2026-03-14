# Warehouse Receipts — CLI Integration Guide

This guide covers how to deploy, configure, and operate the warehouse receipts extension against a testnet-deployed World contract using the Sui CLI.

All operations use **programmable transaction blocks (PTBs)** via `sui client ptb` because the functions involve type parameters, return values, or witness objects.

## Prerequisites

- Sui CLI installed and configured for testnet (`sui client switch --env testnet`)
- An active address with testnet SUI (`sui client faucet`)
- The warehouse_receipts package published on testnet

## Reference Object IDs

Throughout this guide, replace these placeholders with your actual object IDs:

```bash
# Published package IDs
WAREHOUSE_PKG=0x<warehouse_receipts_package_id>
WORLD_PKG=0x<world_package_id>
MULTICOIN_PKG=0x<multicoin_package_id>

# Object IDs (from your deployment / World contract state)
STORAGE_UNIT=0x<storage_unit_object_id>
CHARACTER=0x<character_object_id>
OWNER_CAP=0x<owner_cap_for_storage_unit>   # OwnerCap<StorageUnit>, held by character
CHAR_OWNER_CAP=0x<owner_cap_for_character> # OwnerCap<Character>, held by character

# Created after vault initialization
VAULT_CONFIG=0x<vault_config_object_id>
COLLECTION=0x<collection_object_id>
```

> **Tip:** Use `sui client objects` to list your owned objects, and `sui client object <ID>` to inspect fields.

---

## 1. Publish the Package

```bash
cd packages/contracts
sui client publish --gas-budget 100000000
```

Note the published package ID from the output — this is your `WAREHOUSE_PKG`.

---

## 2. Authorize Extension & Initialize Vault

The SSU owner must authorize the `VaultAuth` witness type on their StorageUnit, initialize the vault, and freeze the extension configuration so it cannot be changed later. This can be done in a single PTB — borrow the `OwnerCap<StorageUnit>`, authorize, initialize, freeze, and return the cap.

```bash
sui client ptb \
  --move-call "${WORLD_PKG}::character::borrow_owner_cap" \
    "<${WORLD_PKG}::storage_unit::StorageUnit>" \
    @${CHARACTER} \
    --receiving @${OWNER_CAP} \
  --assign cap_and_receipt \
  --assign owner_cap cap_and_receipt.0 \
  --assign receipt cap_and_receipt.1 \
  --move-call "${WORLD_PKG}::storage_unit::authorize_extension" \
    "<${WAREHOUSE_PKG}::receipt::VaultAuth>" \
    @${STORAGE_UNIT} \
    owner_cap \
  --move-call "${WAREHOUSE_PKG}::receipt::initialize_vault" \
    @${STORAGE_UNIT} \
    owner_cap \
  --move-call "${WORLD_PKG}::storage_unit::freeze_extension_config" \
    @${STORAGE_UNIT} \
    owner_cap \
  --move-call "${WORLD_PKG}::character::return_owner_cap" \
    "<${WORLD_PKG}::storage_unit::StorageUnit>" \
    @${CHARACTER} \
    owner_cap \
    receipt \
  --gas-budget 50000000
```

> **Note:** `freeze_extension_config` is irreversible. Once frozen, the SSU cannot be re-authorized to a different extension. Only freeze after the extension code is audited and tested.

Check the transaction output for `VaultInitializedEvent` — it contains the `vault_config_id` and `collection_id` you'll need for all subsequent operations.

```bash
# Find the created shared objects
sui client tx-block <TX_DIGEST> --json | jq '.events'
```

---

## 3. Deposit Items for a Receipt

A player deposits items from their owned inventory and receives a `multicoin::Balance` receipt. This requires borrowing the player's `OwnerCap<Character>`.

```bash
TYPE_ID=88070      # The item's type_id
QUANTITY=5         # Number of items to deposit

sui client ptb \
  --move-call "${WORLD_PKG}::character::borrow_owner_cap" \
    "<${WORLD_PKG}::character::Character>" \
    @${CHARACTER} \
    --receiving @${CHAR_OWNER_CAP} \
  --assign cap_and_receipt \
  --assign owner_cap cap_and_receipt.0 \
  --assign receipt cap_and_receipt.1 \
  --move-call "${WAREHOUSE_PKG}::receipt::deposit_for_receipt" \
    "<${WORLD_PKG}::character::Character>" \
    @${STORAGE_UNIT} \
    @${CHARACTER} \
    owner_cap \
    @${VAULT_CONFIG} \
    @${COLLECTION} \
    ${TYPE_ID} \
    ${QUANTITY} \
  --assign balance \
  --move-call "${WORLD_PKG}::character::return_owner_cap" \
    "<${WORLD_PKG}::character::Character>" \
    @${CHARACTER} \
    owner_cap \
    receipt \
  --transfer-objects "[balance]" @<YOUR_ADDRESS> \
  --gas-budget 50000000
```

The receipt (`multicoin::Balance`) is transferred to your address. Note its object ID from the transaction output.

---

## 4. Redeem a Receipt

Anyone holding a receipt can redeem it. The items are deposited into the character's owned inventory at the target StorageUnit.

```bash
RECEIPT=0x<balance_object_id>

sui client ptb \
  --move-call "${WAREHOUSE_PKG}::receipt::redeem_receipt" \
    @${RECEIPT} \
    @${STORAGE_UNIT} \
    @${CHARACTER} \
    @${VAULT_CONFIG} \
    @${COLLECTION} \
  --gas-budget 50000000
```

> **Note:** `redeem_receipt` does not require an `OwnerCap` — it's a bearer-token redemption. Whoever holds the `Balance` object can redeem it.

---

## 5. Transfer a Receipt to Another Player

Receipts are standard Sui objects with `key + store`, so they can be transferred directly:

```bash
RECEIPT=0x<balance_object_id>
RECIPIENT=0x<recipient_address>

sui client transfer --object-id ${RECEIPT} --to ${RECIPIENT} --gas-budget 10000000
```

---

## 6. Split a Receipt

Split a receipt into two parts (e.g., keep 3, give away 2 from a receipt of 5):

```bash
RECEIPT=0x<balance_object_id>
SPLIT_AMOUNT=2

sui client ptb \
  --move-call "${MULTICOIN_PKG}::multicoin::split" \
    @${RECEIPT} \
    ${SPLIT_AMOUNT} \
  --assign new_balance \
  --transfer-objects "[new_balance]" @<YOUR_ADDRESS> \
  --gas-budget 10000000
```

After this, the original receipt has `(original - SPLIT_AMOUNT)` and the new balance has `SPLIT_AMOUNT`.

---

## 7. Join Two Receipts

Merge two receipts of the same asset type into one:

```bash
RECEIPT_KEEP=0x<balance_to_keep>
RECEIPT_MERGE=0x<balance_to_consume>

sui client ptb \
  --move-call "${MULTICOIN_PKG}::multicoin::join" \
    @${RECEIPT_KEEP} \
    @${RECEIPT_MERGE} \
  --gas-budget 10000000
```

`RECEIPT_MERGE` is consumed (deleted). `RECEIPT_KEEP` now holds the combined amount.

---

## Querying State

### List All Receipts Owned by a Player

```bash
# List all multicoin::Balance objects owned by an address
sui client objects --json | jq '[.[] | select(.data.type | contains("multicoin::Balance"))]'
```

Or query by type directly:

```bash
sui client objects \
  --filter '{"StructType": "<MULTICOIN_PKG>::multicoin::multicoin::Balance"}' \
  --json
```

### Inspect a Specific Receipt

```bash
sui client object ${RECEIPT} --json | jq '.data.content.fields'
```

Returns:
```json
{
  "id": { "id": "0x..." },
  "collection": "0x...",
  "asset_id": "88070",
  "amount": "5"
}
```

- `collection` — the Collection ID (identifies which StorageUnit vault)
- `asset_id` — the item `type_id`
- `amount` — quantity of items this receipt represents

### Check Vault Total Supply

Query the `Collection` object to see how many receipts are outstanding for a given type:

```bash
sui client object ${COLLECTION} --json | jq '.data.content.fields.supply'
```

### Find the VaultConfig for a StorageUnit

Look up the `VaultConfig` by querying events from the initialization transaction, or search for shared objects of type:

```bash
sui client objects \
  --filter '{"StructType": "<WAREHOUSE_PKG>::vault::VaultConfig"}' \
  --json
```

Inspect to confirm it's bound to your StorageUnit:

```bash
sui client object ${VAULT_CONFIG} --json | jq '.data.content.fields.storage_unit_id'
```

### Query Deposit/Redeem History

Filter on-chain events by type:

```bash
# Deposit events
sui client events \
  --event-type "${WAREHOUSE_PKG}::receipt::ReceiptMintedEvent" \
  --json

# Redeem events
sui client events \
  --event-type "${WAREHOUSE_PKG}::receipt::ReceiptRedeemedEvent" \
  --json
```

---

## Common Workflows

### Escrow: Lock Items for a Trade

```
1. Seller deposits items         → deposit_for_receipt → gets Balance
2. Seller transfers receipt      → sui client transfer → buyer receives Balance
3. Buyer redeems receipt         → redeem_receipt → items in buyer's inventory
```

### Partial Claim Tickets

```
1. Organizer deposits 100 items  → deposit_for_receipt → gets Balance(amount=100)
2. Split into 10 tickets of 10   → split (×9) → 10 Balance objects
3. Distribute tickets             → transfer each to recipients
4. Recipients redeem individually → redeem_receipt → 10 items each
```

### Collateral for Lending

```
1. Borrower deposits items       → deposit_for_receipt → gets Balance
2. Borrower sends receipt to     → transfer → lender holds as collateral
   lender as collateral
3a. Borrower repays              → lender returns receipt → borrower redeems
3b. Borrower defaults            → lender redeems receipt → lender gets items
```

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `EStorageUnitMismatch` | VaultConfig doesn't match the StorageUnit passed | Ensure you're using the correct VaultConfig for this SSU |
| `EWrongStorageUnit` | Receipt's collection doesn't match the VaultConfig | You're redeeming at the wrong vault — use the vault that issued the receipt |
| `EExtensionNotAuthorized` | `authorize_extension<VaultAuth>` not called | SSU owner must authorize the extension first (step 2) |
| `EAssemblyNotAuthorized` | Wrong OwnerCap used | Ensure the OwnerCap is authorized for this StorageUnit |
| `EInventoryInsufficientQuantity` | Not enough items in inventory | Check inventory balance before depositing/redeeming |
