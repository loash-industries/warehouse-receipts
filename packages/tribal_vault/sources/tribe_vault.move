/// Tribal Storage Vault — a tribe-scoped accumulator for warehouse receipts.
///
/// Players mint standard `multicoin::Balance` receipts via the warehouse_receipts
/// package, then deposit them here. The vault accepts only receipts from the SSU's
/// specific collection (locked at initialization). Balances are accumulated per
/// asset_id. Only tribe members (matching `tribe_id` in their Character) can
/// deposit or withdraw.
///
/// Any tribe member can initialize a tribal vault for their tribe at a given SSU,
/// provided no vault already exists for that (SSU, tribe_id) pair. The shared
/// TribeVaultRegistry enforces this uniqueness invariant.
///
/// Flow:
/// 1. Any tribe member calls `initialize_tribe_vault`, passing the SSU and the
///    SSU's receipt collection_id — creates a shared TribeVaultConfig and registers
///    it. Reverts if a vault for this tribe already exists at this SSU.
/// 2. A tribe member calls `deposit_receipt(vault, balance, character)` —
///    tribe_id + collection_id validated, Balance merged into vault pool.
/// 3. A tribe member calls `withdraw_receipt(vault, asset_id, amount, character)` —
///    tribe_id checked, split Balance returned to caller.
module tribal_vault::tribe_vault {
    use multicoin::multicoin::Balance;
    use sui::{dynamic_object_field as dof, event, table::{Self, Table}};
    use world::{character::{Self, Character}, storage_unit::StorageUnit};

    // === Errors ===

    #[error(code = 0)]
    const ETribeNotMember: vector<u8> =
        b"Character's tribe_id does not match this vault's tribe — access denied";
    #[error(code = 1)]
    const EInsufficientVaultBalance: vector<u8> = b"Insufficient balance in tribal vault";
    #[error(code = 2)]
    const EWrongCollection: vector<u8> =
        b"Receipt collection_id does not match this vault's collection";
    #[error(code = 3)]
    const ETribeVaultAlreadyExists: vector<u8> =
        b"A tribal vault already exists for this tribe at this storage unit";

    // === Structs ===

    /// Composite key used in the registry table.
    public struct VaultKey has copy, drop, store {
        storage_unit_id: ID,
        tribe_id: u32,
    }

    /// Shared singleton registry that maps (storage_unit_id, tribe_id) → vault_config_id.
    /// Enforces one vault per tribe per SSU. Created once by the module initializer.
    public struct TribeVaultRegistry has key {
        id: UID,
        vaults: Table<VaultKey, ID>,
    }

    /// Shared per-(StorageUnit, tribe_id) vault config.
    /// Accepts only receipts from `collection_id` (the SSU's receipt collection).
    /// Per-asset balances are stored as dynamic fields keyed by asset_id (u64).
    public struct TribeVaultConfig has key {
        id: UID,
        tribe_id: u32,
        storage_unit_id: ID,
        collection_id: ID,
    }

    // === Module initializer ===

    fun init(ctx: &mut TxContext) {
        transfer::share_object(TribeVaultRegistry {
            id: object::new(ctx),
            vaults: table::new(ctx),
        });
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
    /// Any tribe member may call this. Reverts if a vault for this tribe already
    /// exists at this SSU — use `registry::lookup` to check first.
    /// `collection_id` must be the ID of the SSU's warehouse receipt Collection.
    public fun initialize_tribe_vault(
        registry: &mut TribeVaultRegistry,
        storage_unit: &StorageUnit,
        character: &Character,
        collection_id: ID,
        ctx: &mut TxContext,
    ) {
        let storage_unit_id = object::id(storage_unit);
        let tribe_id = character::tribe(character);
        let key = VaultKey { storage_unit_id, tribe_id };

        assert!(!table::contains(&registry.vaults, key), ETribeVaultAlreadyExists);

        let config = TribeVaultConfig {
            id: object::new(ctx),
            tribe_id,
            storage_unit_id,
            collection_id,
        };
        let vault_config_id = object::id(&config);

        table::add(&mut registry.vaults, key, vault_config_id);
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

        if (dof::exists_(&vault.id, asset_id)) {
            let stored: &mut Balance = dof::borrow_mut(&mut vault.id, asset_id);
            stored.join(receipt, ctx);
        } else {
            dof::add(&mut vault.id, asset_id, receipt);
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

        assert!(dof::exists_(&vault.id, asset_id), EInsufficientVaultBalance);
        let stored: &mut Balance = dof::borrow_mut(&mut vault.id, asset_id);
        assert!(stored.value() >= amount, EInsufficientVaultBalance);

        let withdrawn = stored.split(amount, ctx);

        // Remove zero-balance slot to reclaim storage
        if (stored.value() == 0) {
            let zero: Balance = dof::remove(&mut vault.id, asset_id);
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

    /// Look up the vault_config_id for a (storage_unit_id, tribe_id) pair.
    /// Returns `option::none()` if no vault has been initialized for that pair.
    public fun lookup(
        registry: &TribeVaultRegistry,
        storage_unit_id: ID,
        tribe_id: u32,
    ): Option<ID> {
        let key = VaultKey { storage_unit_id, tribe_id };
        if (table::contains(&registry.vaults, key)) {
            option::some(*table::borrow(&registry.vaults, key))
        } else {
            option::none()
        }
    }

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
        if (dof::exists_(&vault.id, asset_id)) {
            let stored: &Balance = dof::borrow(&vault.id, asset_id);
            stored.value()
        } else {
            0
        }
    }
}
