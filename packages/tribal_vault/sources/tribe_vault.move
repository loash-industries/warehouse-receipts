/// Tribal Storage Vault — a tribe-scoped accumulator for warehouse receipts.
///
/// Players mint standard `multicoin::Balance` receipts via the warehouse_receipts
/// package, then deposit them here. The vault accepts only receipts from the SSU's
/// specific collection (locked at initialization). Balances are accumulated per
/// asset_id. Only tribe members (matching `tribe_id` in their Character) can
/// deposit or withdraw.
///
/// Flow:
/// 1. SSU owner calls `initialize_tribe_vault`, passing the SSU's receipt collection_id —
///    creates a shared TribeVaultConfig. No SSU extension interaction required.
/// 2. A tribe member calls `deposit_receipt(vault, balance, character)` —
///    tribe_id + collection_id validated, Balance merged into vault pool.
/// 3. A tribe member calls `withdraw_receipt(vault, asset_id, amount, character)` —
///    tribe_id checked, split Balance returned to caller.
module tribal_vault::tribe_vault {
    use multicoin::multicoin::Balance;
    use sui::{dynamic_field as df, event};
    use world::{access::OwnerCap, character::{Self, Character}, storage_unit::StorageUnit};

    // === Errors ===
    #[error(code = 0)]
    const EStorageUnitMismatch: vector<u8> = b"OwnerCap does not match this storage unit";
    #[error(code = 1)]
    const ETribeNotMember: vector<u8> =
        b"Character's tribe_id does not match this vault's tribe — access denied";
    #[error(code = 2)]
    const EInsufficientVaultBalance: vector<u8> = b"Insufficient balance in tribal vault";
    #[error(code = 3)]
    const EWrongCollection: vector<u8> =
        b"Receipt collection_id does not match this vault's collection";

    // === Structs ===

    /// Shared per-(StorageUnit, tribe_id) vault config.
    /// Accepts only receipts from `collection_id` (the SSU's receipt collection).
    /// Per-asset balances are stored as dynamic fields keyed by asset_id (u64).
    public struct TribeVaultConfig has key {
        id: UID,
        tribe_id: u32,
        storage_unit_id: ID,
        collection_id: ID,
    }

    // === Events ===

    public struct TribeVaultInitializedEvent has copy, drop {
        vault_config_id: ID,
        tribe_id: u32,
        storage_unit_id: ID,
        collection_id: ID,
    }

    public struct TribeVaultDepositEvent has copy, drop {
        vault_config_id: ID,
        tribe_id: u32,
        collection_id: ID,
        asset_id: u64,
        amount: u64,
        depositor: address,
    }

    public struct TribeVaultWithdrawEvent has copy, drop {
        vault_config_id: ID,
        tribe_id: u32,
        collection_id: ID,
        asset_id: u64,
        amount: u64,
        withdrawer: address,
    }

    // === Public Functions ===

    /// Initialize a tribal vault for the caller's tribe on a given StorageUnit.
    /// `collection_id` must be the ID of the SSU's warehouse receipt Collection.
    /// The tribe_id is read from `character` and locked permanently.
    /// Only the SSU owner can call this.
    public fun initialize_tribe_vault(
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        character: &Character,
        collection_id: ID,
        ctx: &mut TxContext,
    ) {
        let storage_unit_id = object::id(storage_unit);
        assert!(world::access::is_authorized(owner_cap, storage_unit_id), EStorageUnitMismatch);

        let tribe_id = character::tribe(character);

        let config = TribeVaultConfig {
            id: object::new(ctx),
            tribe_id,
            storage_unit_id,
            collection_id,
        };
        let vault_config_id = object::id(&config);

        transfer::share_object(config);

        event::emit(TribeVaultInitializedEvent {
            vault_config_id,
            tribe_id,
            storage_unit_id,
            collection_id,
        });
    }

    /// Deposit a warehouse receipt into the tribal vault.
    /// Caller must be a tribe member. Receipt must belong to the vault's collection.
    /// The Balance is merged with any existing balance for that asset_id.
    public fun deposit_receipt(
        vault: &mut TribeVaultConfig,
        receipt: Balance,
        character: &Character,
        ctx: &mut TxContext,
    ) {
        assert!(character::tribe(character) == vault.tribe_id, ETribeNotMember);
        assert!(receipt.collection_id() == vault.collection_id, EWrongCollection);

        let asset_id = receipt.asset_id();
        let amount = receipt.value();

        if (df::exists_(&vault.id, asset_id)) {
            let stored: &mut Balance = df::borrow_mut(&mut vault.id, asset_id);
            stored.join(receipt, ctx);
        } else {
            df::add(&mut vault.id, asset_id, receipt);
        };

        event::emit(TribeVaultDepositEvent {
            vault_config_id: object::id(vault),
            tribe_id: vault.tribe_id,
            collection_id: vault.collection_id,
            asset_id,
            amount,
            depositor: ctx.sender(),
        });
    }

    /// Withdraw a specific amount for a given asset_id from the tribal vault.
    /// Caller must be a tribe member. Returns the split Balance to the caller.
    public fun withdraw_receipt(
        vault: &mut TribeVaultConfig,
        asset_id: u64,
        amount: u64,
        character: &Character,
        ctx: &mut TxContext,
    ): Balance {
        assert!(character::tribe(character) == vault.tribe_id, ETribeNotMember);

        assert!(df::exists_(&vault.id, asset_id), EInsufficientVaultBalance);
        let stored: &mut Balance = df::borrow_mut(&mut vault.id, asset_id);
        assert!(stored.value() >= amount, EInsufficientVaultBalance);

        let withdrawn = stored.split(amount, ctx);

        // Remove zero-balance slot to reclaim storage
        if (stored.value() == 0) {
            let zero: Balance = df::remove(&mut vault.id, asset_id);
            zero.destroy_zero();
        };

        event::emit(TribeVaultWithdrawEvent {
            vault_config_id: object::id(vault),
            tribe_id: vault.tribe_id,
            collection_id: vault.collection_id,
            asset_id,
            amount,
            withdrawer: ctx.sender(),
        });

        withdrawn
    }

    // === View Functions ===

    public fun tribe_id(vault: &TribeVaultConfig): u32 {
        vault.tribe_id
    }

    public fun storage_unit_id(vault: &TribeVaultConfig): ID {
        vault.storage_unit_id
    }

    public fun collection_id(vault: &TribeVaultConfig): ID {
        vault.collection_id
    }

    /// Returns the vault's accumulated balance for a given asset_id.
    public fun vault_balance(vault: &TribeVaultConfig, asset_id: u64): u64 {
        if (df::exists_(&vault.id, asset_id)) {
            let stored: &Balance = df::borrow(&vault.id, asset_id);
            stored.value()
        } else {
            0
        }
    }
}
