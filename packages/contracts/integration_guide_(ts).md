# Warehouse Receipts — TypeScript Integration Guide

This guide covers how to deploy, configure, and operate the warehouse receipts extension against a testnet-deployed World contract using the `@mysten/sui` TypeScript SDK.

## Prerequisites

- Node.js 18+ and a package manager (npm, pnpm, or yarn)
- `@mysten/sui` installed: `npm install @mysten/sui`
- The warehouse_receipts package published on testnet

## Setup

```typescript
import { SuiClient, getFullnodeUrl } from "@mysten/sui/client";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

const client = new SuiClient({ url: getFullnodeUrl("testnet") });
const keypair = Ed25519Keypair.fromSecretKey("<your-private-key>");
const sender = keypair.getPublicKey().toSuiAddress();
```

## Reference Object IDs

```typescript
// Published package IDs
const WAREHOUSE_PKG = "0x<warehouse_receipts_package_id>";
const WORLD_PKG = "0x<world_package_id>";
const MULTICOIN_PKG = "0x<multicoin_package_id>";

// Object IDs (from your deployment / World contract state)
const STORAGE_UNIT = "0x<storage_unit_object_id>";
const CHARACTER = "0x<character_object_id>";
const OWNER_CAP = "0x<owner_cap_for_storage_unit>";     // OwnerCap<StorageUnit>
const CHAR_OWNER_CAP = "0x<owner_cap_for_character>";   // OwnerCap<Character>

// Created after vault initialization
const VAULT_CONFIG = "0x<vault_config_object_id>";
const COLLECTION = "0x<collection_object_id>";
```

## Helper

All examples use this helper to sign, execute, and log:

```typescript
async function execute(tx: Transaction) {
  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer: keypair,
    options: { showEffects: true, showObjectChanges: true, showEvents: true },
  });
  console.log("Digest:", result.digest);
  return result;
}
```

---

## 1. Publish the Package

Publishing is done via the CLI:

```bash
cd packages/contracts
sui client publish --gas-budget 100000000
```

Note the published package ID — this is your `WAREHOUSE_PKG`.

---

## 2. Authorize Extension, Initialize Vault & Freeze

The SSU owner must authorize the `VaultAuth` witness type, initialize the vault, and freeze the extension configuration in a single transaction.

```typescript
async function authorizeInitializeAndFreeze() {
  const tx = new Transaction();

  // Borrow OwnerCap<StorageUnit> from Character
  const [ownerCap, receipt] = tx.moveCall({
    target: `${WORLD_PKG}::character::borrow_owner_cap`,
    typeArguments: [`${WORLD_PKG}::storage_unit::StorageUnit`],
    arguments: [tx.object(CHARACTER), tx.object(OWNER_CAP)],
  });

  // Authorize VaultAuth extension on the StorageUnit
  tx.moveCall({
    target: `${WORLD_PKG}::storage_unit::authorize_extension`,
    typeArguments: [`${WAREHOUSE_PKG}::receipt::VaultAuth`],
    arguments: [tx.object(STORAGE_UNIT), ownerCap],
  });

  // Initialize the vault (creates Collection + VaultConfig as shared objects)
  tx.moveCall({
    target: `${WAREHOUSE_PKG}::receipt::initialize_vault`,
    arguments: [tx.object(STORAGE_UNIT), ownerCap],
  });

  // Freeze extension config (irreversible — prevents changing the extension)
  tx.moveCall({
    target: `${WORLD_PKG}::storage_unit::freeze_extension_config`,
    arguments: [tx.object(STORAGE_UNIT), ownerCap],
  });

  // Return the OwnerCap to the Character
  tx.moveCall({
    target: `${WORLD_PKG}::character::return_owner_cap`,
    typeArguments: [`${WORLD_PKG}::storage_unit::StorageUnit`],
    arguments: [tx.object(CHARACTER), ownerCap, receipt],
  });

  const result = await execute(tx);

  // Extract created object IDs from events
  const initEvent = result.events?.find(
    (e) => e.type.includes("VaultInitializedEvent")
  );
  if (initEvent) {
    const { vault_config_id, collection_id } = initEvent.parsedJson as any;
    console.log("VaultConfig:", vault_config_id);
    console.log("Collection:", collection_id);
  }
}
```

> **Note:** `freeze_extension_config` is irreversible. Once frozen, the SSU cannot be re-authorized to a different extension. Only freeze after the extension code is audited and tested.

---

## 3. Deposit Items for a Receipt

A player deposits items from their owned inventory and receives a `multicoin::Balance` receipt. The player's `OwnerCap<Character>` is borrowed for inventory access.

```typescript
async function depositForReceipt(typeId: number, quantity: number) {
  const tx = new Transaction();

  // Borrow OwnerCap<Character> from Character
  const [ownerCap, receipt] = tx.moveCall({
    target: `${WORLD_PKG}::character::borrow_owner_cap`,
    typeArguments: [`${WORLD_PKG}::character::Character`],
    arguments: [tx.object(CHARACTER), tx.object(CHAR_OWNER_CAP)],
  });

  // Deposit items and receive a multicoin Balance
  const [balance] = tx.moveCall({
    target: `${WAREHOUSE_PKG}::receipt::deposit_for_receipt`,
    typeArguments: [`${WORLD_PKG}::character::Character`],
    arguments: [
      tx.object(STORAGE_UNIT),
      tx.object(CHARACTER),
      ownerCap,
      tx.object(VAULT_CONFIG),
      tx.object(COLLECTION),
      tx.pure.u64(typeId),
      tx.pure.u32(quantity),
    ],
  });

  // Return OwnerCap
  tx.moveCall({
    target: `${WORLD_PKG}::character::return_owner_cap`,
    typeArguments: [`${WORLD_PKG}::character::Character`],
    arguments: [tx.object(CHARACTER), ownerCap, receipt],
  });

  // Transfer the receipt to the sender
  tx.transferObjects([balance], tx.pure.address(sender));

  return execute(tx);
}

// Example: deposit 5 items of type 88070
await depositForReceipt(88070, 5);
```

---

## 4. Redeem a Receipt

Anyone holding a receipt can redeem it. No `OwnerCap` is needed — it's a bearer-token redemption.

```typescript
async function redeemReceipt(receiptId: string) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${WAREHOUSE_PKG}::receipt::redeem_receipt`,
    arguments: [
      tx.object(receiptId),
      tx.object(STORAGE_UNIT),
      tx.object(CHARACTER),
      tx.object(VAULT_CONFIG),
      tx.object(COLLECTION),
    ],
  });

  return execute(tx);
}

await redeemReceipt("0x<balance_object_id>");
```

---

## 5. Transfer a Receipt

Receipts are standard Sui objects with `key + store`:

```typescript
async function transferReceipt(receiptId: string, recipient: string) {
  const tx = new Transaction();
  tx.transferObjects([tx.object(receiptId)], tx.pure.address(recipient));
  return execute(tx);
}
```

---

## 6. Split a Receipt

Split a receipt into two parts (e.g., split off 2 from a receipt of 5):

```typescript
async function splitReceipt(receiptId: string, splitAmount: number) {
  const tx = new Transaction();

  const [newBalance] = tx.moveCall({
    target: `${MULTICOIN_PKG}::multicoin::split`,
    arguments: [tx.object(receiptId), tx.pure.u64(splitAmount)],
  });

  tx.transferObjects([newBalance], tx.pure.address(sender));

  return execute(tx);
}

// Split 2 from a receipt — original keeps (original - 2), new balance has 2
await splitReceipt("0x<balance_object_id>", 2);
```

---

## 7. Join Two Receipts

Merge two receipts of the same asset type into one:

```typescript
async function joinReceipts(keepId: string, mergeId: string) {
  const tx = new Transaction();

  tx.moveCall({
    target: `${MULTICOIN_PKG}::multicoin::join`,
    arguments: [tx.object(keepId), tx.object(mergeId)],
  });

  return execute(tx);
}

// mergeId is consumed (deleted); keepId holds the combined amount
await joinReceipts("0x<balance_to_keep>", "0x<balance_to_consume>");
```

---

## Querying State

### List All Receipts Owned by a Player

```typescript
async function getReceipts(owner: string) {
  const objects = await client.getOwnedObjects({
    owner,
    filter: {
      StructType: `${MULTICOIN_PKG}::multicoin::Balance`,
    },
    options: { showContent: true, showType: true },
  });
  return objects.data;
}

const receipts = await getReceipts(sender);
console.log("Receipts:", receipts);
```

### Inspect a Specific Receipt

```typescript
async function inspectReceipt(receiptId: string) {
  const obj = await client.getObject({
    id: receiptId,
    options: { showContent: true },
  });
  const fields = (obj.data?.content as any)?.fields;
  console.log("Collection:", fields?.collection);
  console.log("Asset ID:", fields?.asset_id);   // item type_id
  console.log("Amount:", fields?.amount);        // quantity
  return fields;
}
```

### Check Vault Total Supply

```typescript
async function getVaultSupply(collectionId: string) {
  const obj = await client.getObject({
    id: collectionId,
    options: { showContent: true },
  });
  const fields = (obj.data?.content as any)?.fields;
  console.log("Supply:", fields?.supply);
  return fields?.supply;
}
```

### Find the VaultConfig for a StorageUnit

```typescript
async function findVaultConfig(owner: string, storageUnitId: string) {
  const objects = await client.getOwnedObjects({
    owner,
    filter: {
      StructType: `${WAREHOUSE_PKG}::vault::VaultConfig`,
    },
    options: { showContent: true },
  });

  for (const obj of objects.data) {
    const fields = (obj.data?.content as any)?.fields;
    if (fields?.storage_unit_id === storageUnitId) {
      return obj.data?.objectId;
    }
  }
  return null;
}
```

> **Note:** `VaultConfig` is a shared object. To find it, query events from the initialization transaction or use `queryEvents` (see below).

### Query Deposit/Redeem History

```typescript
async function getDepositEvents() {
  const events = await client.queryEvents({
    query: {
      MoveEventType: `${WAREHOUSE_PKG}::receipt::ReceiptMintedEvent`,
    },
  });
  return events.data;
}

async function getRedeemEvents() {
  const events = await client.queryEvents({
    query: {
      MoveEventType: `${WAREHOUSE_PKG}::receipt::ReceiptRedeemedEvent`,
    },
  });
  return events.data;
}
```

---

## Common Workflows

### Escrow: Lock Items for a Trade

```typescript
// 1. Seller deposits items → gets a Balance receipt
const depositResult = await depositForReceipt(88070, 5);
const receiptId = /* extract created Balance object ID from depositResult */;

// 2. Seller transfers receipt to buyer
await transferReceipt(receiptId, buyerAddress);

// 3. Buyer redeems receipt → items appear in buyer's owned inventory
await redeemReceipt(receiptId); // called by buyer
```

### Partial Claim Tickets

```typescript
// 1. Organizer deposits 100 items
const depositResult = await depositForReceipt(88070, 100);
const originalReceiptId = /* extract Balance ID */;

// 2. Split into 10 tickets of 10
const ticketIds: string[] = [originalReceiptId];
for (let i = 0; i < 9; i++) {
  const splitResult = await splitReceipt(ticketIds[0], 10);
  const newTicketId = /* extract new Balance ID from splitResult */;
  ticketIds.push(newTicketId);
}

// 3. Distribute tickets to recipients
for (let i = 0; i < ticketIds.length; i++) {
  await transferReceipt(ticketIds[i], recipientAddresses[i]);
}

// 4. Each recipient redeems their ticket → 10 items each
```

### Collateral for Lending

```typescript
// 1. Borrower deposits items → gets receipt
const depositResult = await depositForReceipt(88070, 50);
const receiptId = /* extract Balance ID */;

// 2. Borrower sends receipt to lender as collateral
await transferReceipt(receiptId, lenderAddress);

// 3a. Borrower repays → lender returns receipt → borrower redeems
// 3b. Borrower defaults → lender redeems receipt → lender gets the items
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
