/// Tribal vault custody layer — manages per-tribe MultiCoin mint/burn.
///
/// Each (StorageUnit, tribe_id) pair gets its own Collection so receipts
/// from different tribes are non-fungible with one another by construction.
///
/// Mint and burn are `public(package)` — only `tribe_vault` in this package
/// may create or destroy tribe receipts.
module tribal_vault::tribe_custody {
    use multicoin::multicoin::{Self, Collection, CollectionCap, Balance};

    // === Errors ===
    #[error(code = 0)]
    const EWrongVault: vector<u8> = b"Balance collection does not match this TribeVaultConfig";

    // === Structs ===

    /// Per-(StorageUnit, tribe_id) configuration that custodies the CollectionCap.
    /// Created once during vault initialization and shared.
    public struct TribeVaultConfig has key, store {
        id: UID,
        /// The storage unit this config is bound to
        storage_unit_id: ID,
        /// The tribe this vault is locked to (set from creator's character at init)
        tribe_id: u32,
        /// Admin capability for minting — custodied, not freely transferable
        collection_cap: CollectionCap,
    }

    // === Package Functions ===

    /// Create a new TribeVaultConfig and Collection for a (storage_unit, tribe) pair.
    public(package) fun create_tribe_vault(
        storage_unit_id: ID,
        tribe_id: u32,
        ctx: &mut TxContext,
    ): (TribeVaultConfig, Collection) {
        let (collection, collection_cap) = multicoin::new_collection(ctx);

        let config = TribeVaultConfig {
            id: object::new(ctx),
            storage_unit_id,
            tribe_id,
            collection_cap,
        };

        (config, collection)
    }

    /// Mint a tribe receipt (multicoin Balance) for the given type_id and quantity.
    public(package) fun mint(
        config: &TribeVaultConfig,
        collection: &mut Collection,
        type_id: u64,
        quantity: u64,
        ctx: &mut TxContext,
    ): Balance {
        multicoin::mint_balance(&config.collection_cap, collection, type_id, quantity, ctx)
    }

    /// Burn a tribe receipt, returning (storage_unit_id, type_id, quantity).
    /// Verifies the balance belongs to this vault's collection.
    public(package) fun burn(
        config: &TribeVaultConfig,
        collection: &mut Collection,
        balance: Balance,
        ctx: &TxContext,
    ): (ID, u64, u64) {
        assert!(
            balance.collection_id() == multicoin::cap_collection_id(&config.collection_cap),
            EWrongVault,
        );
        let type_id = balance.asset_id();
        let amount = multicoin::burn(collection, balance, ctx);
        (config.storage_unit_id, type_id, amount)
    }

    // === View Functions ===

    public fun storage_unit_id(config: &TribeVaultConfig): ID {
        config.storage_unit_id
    }

    public fun tribe_id(config: &TribeVaultConfig): u32 {
        config.tribe_id
    }

    public fun collection_id(config: &TribeVaultConfig): ID {
        multicoin::cap_collection_id(&config.collection_cap)
    }

    public fun total_supply(collection: &Collection, type_id: u64): u64 {
        multicoin::total_supply(collection, type_id)
    }
}
