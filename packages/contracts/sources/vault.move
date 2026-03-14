/// Warehouse receipt configuration for MultiCoin-based bearer tokens.
///
/// This module manages a per-StorageUnit `VaultConfig` that custodies a MultiCoin
/// `CollectionCap` and links to the shared `Collection`. One `Collection` is created
/// per StorageUnit so that `collection_id` identifies the storage unit and
/// `asset_id` (u64) maps directly to `type_id`.
///
/// Receipts are standard `multicoin::Balance` objects — they inherit split, join,
/// transfer, and all other Coin-like operations from multicoin. No custom receipt
/// struct is needed.
///
/// Mint and burn are `public(package)` — only extension modules in this package can
/// create or destroy receipts.
module warehouse_receipts::vault {
    use multicoin::multicoin::{Self, Collection, CollectionCap, Balance};

    // === Errors ===
    #[error(code = 0)]
    const EWrongStorageUnit: vector<u8> = b"Balance collection does not match this VaultConfig";

    // === Structs ===

    /// Per-StorageUnit configuration that custodies the CollectionCap.
    /// Created once during vault initialization and shared.
    public struct VaultConfig has key, store {
        id: UID,
        /// The storage unit this config is bound to
        storage_unit_id: ID,
        /// Admin capability for minting — custodied, not freely transferable
        collection_cap: CollectionCap,
    }

    // === Package Functions ===

    /// Create a new VaultConfig and Collection for a storage unit.
    /// Returns the VaultConfig (to be shared) and Collection (to be shared).
    public(package) fun create_vault(
        storage_unit_id: ID,
        ctx: &mut TxContext,
    ): (VaultConfig, Collection) {
        let (collection, collection_cap) = multicoin::new_collection(ctx);

        let config = VaultConfig {
            id: object::new(ctx),
            storage_unit_id,
            collection_cap,
        };

        (config, collection)
    }

    /// Mint a receipt (multicoin Balance) for the given type_id and quantity.
    public(package) fun mint(
        config: &VaultConfig,
        collection: &mut Collection,
        type_id: u64,
        quantity: u64,
        ctx: &mut TxContext,
    ): Balance {
        multicoin::mint_balance(&config.collection_cap, collection, type_id, quantity, ctx)
    }

    /// Burn a receipt, returning (storage_unit_id, type_id, quantity).
    /// Verifies the balance belongs to this vault's collection.
    public(package) fun burn(
        config: &VaultConfig,
        collection: &mut Collection,
        balance: Balance,
        ctx: &TxContext,
    ): (ID, u64, u64) {
        assert!(
            balance.collection_id() == multicoin::cap_collection_id(&config.collection_cap),
            EWrongStorageUnit,
        );
        let type_id = balance.asset_id();
        let amount = multicoin::burn(collection, balance, ctx);
        (config.storage_unit_id, type_id, amount)
    }

    // === View Functions ===

    /// Returns the storage unit ID this vault is bound to
    public fun storage_unit_id(config: &VaultConfig): ID {
        config.storage_unit_id
    }

    /// Returns the collection ID for this vault
    public fun collection_id(config: &VaultConfig): ID {
        multicoin::cap_collection_id(&config.collection_cap)
    }

    /// Returns the total supply of a given type_id in this vault
    public fun total_supply(collection: &Collection, type_id: u64): u64 {
        multicoin::total_supply(collection, type_id)
    }
}
