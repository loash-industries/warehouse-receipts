/// Warehouse receipt vaults on world-contracts v1 (`dev`).
///
/// One `VaultConfig` per world `Entity` (TRIEX-160). The config's UID is a
/// derived object claimed from the shared `VaultRegistry` under the entity's id,
/// so a second vault for the same entity aborts, and anyone can derive the
/// config's address from the entity id without an index.
///
/// The config custodies the MultiCoin `CollectionCap`. Each vault gets its own
/// `Collection`, so `collection_id` identifies the vault. A receipt's `asset_id`
/// is derived from the item's `VariantKey` (`asset_id`), and the config keeps
/// the reverse map so a redeem knows which variant to free.
module warehouse_receipts::vault;

use multicoin::multicoin::{Self, Balance, Collection, CollectionCap};
use sui::{bcs, derived_object, hash, table::{Self, Table}};
use variant::variant::VariantKey;

// === Errors ===

#[error(code = 0)]
const EWrongCollection: vector<u8> = b"Receipt is not from this vault's collection";
#[error(code = 1)]
const EVaultExists: vector<u8> = b"This entity already has a warehouse receipt vault";
#[error(code = 2)]
const EAssetIdCollision: vector<u8> = b"Two variants derive the same receipt asset id";

// === Structs ===

/// Shared registry the vault configs derive from. Created once at publish.
public struct VaultRegistry has key {
    id: UID,
}

/// Derivation key: the world entity a vault is bound to.
public struct VaultKey(ID) has copy, drop, store;

/// The vault bound to one world entity. Shared. No `store`, so it can't be
/// wrapped or moved out of this package's control.
public struct VaultConfig has key {
    id: UID,
    /// World entity the receipts are backed by.
    entity_id: ID,
    /// Component id of the entity's Inventory (the Airlock) holding the items.
    inventory_id: u64,
    collection_cap: CollectionCap,
    /// Receipt `asset_id` -> the item variant it stands for.
    assets: Table<u64, VariantKey>,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(VaultRegistry { id: object::new(ctx) });
}

// === Package Functions ===

/// Create the vault for `entity_id`. Aborts with `EVaultExists` if one was ever
/// created for it (TRIEX-160).
public(package) fun create(
    registry: &mut VaultRegistry,
    entity_id: ID,
    inventory_id: u64,
    ctx: &mut TxContext,
): (VaultConfig, Collection) {
    assert!(!derived_object::exists(&registry.id, VaultKey(entity_id)), EVaultExists);
    let id = derived_object::claim(&mut registry.id, VaultKey(entity_id));
    let (collection, collection_cap) = multicoin::new_collection(ctx);
    let assets = table::new(ctx);
    (VaultConfig { id, entity_id, inventory_id, collection_cap, assets }, collection)
}

public(package) fun share(config: VaultConfig) {
    transfer::share_object(config);
}

/// Mint a receipt for `quantity` of variant `key`, recording its asset id.
public(package) fun mint(
    config: &mut VaultConfig,
    collection: &mut Collection,
    key: VariantKey,
    quantity: u64,
    ctx: &mut TxContext,
): Balance {
    let asset = asset_id(&key);
    if (config.assets.contains(asset)) assert!(config.assets[asset] == key, EAssetIdCollision)
    else config.assets.add(asset, key);
    multicoin::mint_balance(&config.collection_cap, collection, asset, quantity, ctx)
}

/// Burn a receipt from this vault's collection. Returns `(key, quantity)`.
public(package) fun burn(
    config: &VaultConfig,
    collection: &mut Collection,
    receipt: Balance,
    ctx: &TxContext,
): (VariantKey, u64) {
    assert!(receipt.collection_id() == collection_id(config), EWrongCollection);
    let key = config.assets[receipt.asset_id()];
    let quantity = multicoin::burn(collection, receipt, ctx);
    (key, quantity)
}

// === View Functions ===

public fun entity_id(config: &VaultConfig): ID { config.entity_id }

public fun inventory_id(config: &VaultConfig): u64 { config.inventory_id }

public fun collection_id(config: &VaultConfig): ID {
    multicoin::cap_collection_id(&config.collection_cap)
}

public fun total_supply(collection: &Collection, asset_id: u64): u64 {
    multicoin::total_supply(collection, asset_id)
}

/// Receipt asset id for item variant `key`: the first 8 bytes (LE) of
/// `blake2b256(bcs(key))`.
public fun asset_id(key: &VariantKey): u64 {
    bcs::new(hash::blake2b256(&bcs::to_bytes(key))).peel_u64()
}

/// The item variant behind receipt `asset_id`, if this vault ever minted it.
public fun asset_key(config: &VaultConfig, asset_id: u64): Option<VariantKey> {
    if (config.assets.contains(asset_id)) option::some(config.assets[asset_id])
    else option::none()
}

/// Whether `entity_id` already has a vault.
public fun has_vault(registry: &VaultRegistry, entity_id: ID): bool {
    derived_object::exists(&registry.id, VaultKey(entity_id))
}

/// The address `entity_id`'s `VaultConfig` has (or will have).
public fun vault_address(registry: &VaultRegistry, entity_id: ID): address {
    derived_object::derive_address(object::id(registry), VaultKey(entity_id))
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
