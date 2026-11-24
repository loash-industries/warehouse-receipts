/// Warehouse receipt vaults on world-contracts v1 (`dev`).
///
/// One `VaultConfig` per world `Entity` (TRIEX-160). The config's UID is a
/// derived object claimed from the shared `VaultRegistry` under the entity's id,
/// so a second vault for the same entity aborts, and anyone can derive the
/// config's address from the entity id without an index.
///
/// The config custodies the MultiCoin `CollectionCap`. Each vault gets its own
/// `Collection`, so `collection_id` identifies the vault and `asset_id` is the
/// game `type_id`.
module warehouse_receipts::vault;

use multicoin::multicoin::{Self, Balance, Collection, CollectionCap};
use sui::derived_object;

// === Errors ===

#[error(code = 0)]
const EWrongCollection: vector<u8> = b"Receipt is not from this vault's collection";
#[error(code = 1)]
const EVaultExists: vector<u8> = b"This entity already has a warehouse receipt vault";

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
    (VaultConfig { id, entity_id, inventory_id, collection_cap }, collection)
}

public(package) fun share(config: VaultConfig) {
    transfer::share_object(config);
}

public(package) fun mint(
    config: &VaultConfig,
    collection: &mut Collection,
    type_id: u64,
    quantity: u64,
    ctx: &mut TxContext,
): Balance {
    multicoin::mint_balance(&config.collection_cap, collection, type_id, quantity, ctx)
}

/// Burn a receipt from this vault's collection. Returns `(type_id, quantity)`.
public(package) fun burn(
    config: &VaultConfig,
    collection: &mut Collection,
    receipt: Balance,
    ctx: &TxContext,
): (u64, u64) {
    assert!(receipt.collection_id() == collection_id(config), EWrongCollection);
    let type_id = receipt.asset_id();
    let quantity = multicoin::burn(collection, receipt, ctx);
    (type_id, quantity)
}

// === View Functions ===

public fun entity_id(config: &VaultConfig): ID { config.entity_id }

public fun inventory_id(config: &VaultConfig): u64 { config.inventory_id }

public fun collection_id(config: &VaultConfig): ID {
    multicoin::cap_collection_id(&config.collection_cap)
}

public fun total_supply(collection: &Collection, type_id: u64): u64 {
    multicoin::total_supply(collection, type_id)
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
