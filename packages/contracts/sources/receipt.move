/// Vault Receipts extension for StorageUnit — deposit/redeem using MultiCoin-based receipts.
///
/// This extension allows players to deposit items into the open inventory and receive
/// a transferable `multicoin::Balance` (bearer token) representing their deposit.
/// The balance can be freely transferred, split, joined, sold, or held, and later
/// redeemed by whoever possesses it to withdraw the deposited items.
///
/// Each StorageUnit gets its own MultiCoin Collection (1:1 mapping), so
/// `collection_id` identifies the storage unit and `asset_id` maps to `type_id`.
///
/// Flow:
/// 1. SSU owner calls `initialize_vault` to create the Collection + VaultConfig
///    (or `new_vault` → … → `share_vault` to act on the new VaultConfig in the
///    same PTB before it is shared)
/// 2. SSU owner calls `authorize_extension<VaultAuth>` on the StorageUnit
/// 3. Player calls `deposit_for_receipt` to move items from owned → open inventory
/// 4. Extension mints a `multicoin::Balance` and returns it to the caller
/// 5. Receipt holder (anyone) calls `redeem_receipt` to withdraw items
///
/// Use Cases:
/// - Escrow services
/// - Collateralized lending (receipt as collateral)
/// - Tradeable warehouse receipts on TriexBook MultiCoin pools
/// - Gift vouchers / claim tickets
module warehouse_receipts::receipt {
    use multicoin::multicoin::{Collection, Balance};
    use sui::event;
    use warehouse_receipts::vault::{Self, VaultConfig};
    use world::{access::OwnerCap, character::Character, storage_unit::StorageUnit};

    // === Errors ===
    #[error(code = 0)]
    const EStorageUnitMismatch: vector<u8> = b"Receipt belongs to a different storage unit";
    #[error(code = 1)]
    const EBatchLengthMismatch: vector<u8> =
        b"type_ids and quantities vectors must have the same length";

    // === Structs ===

    /// Witness type for extension authorization
    public struct VaultAuth has drop {}

    /// A vault created by `new_vault` that the same transaction must share.
    ///
    /// `initialize_vault` shares the new `VaultConfig` and `Collection` inside
    /// the call, and a PTB cannot pass an object shared earlier in the same
    /// transaction to a later command — so nothing could act on a fresh vault
    /// (register it with a downstream protocol, say) until a second
    /// transaction. Holding both objects here lets a downstream *Move*
    /// function take `&PendingVault` and read them first; a PTB cannot call
    /// the reference-returning accessors directly. No abilities: the only way
    /// to consume it is `share_vault`, so a vault can never be left owned,
    /// wrapped, or dropped half-initialized.
    public struct PendingVault {
        config: VaultConfig,
        collection: Collection,
    }

    // === Events ===

    public struct VaultInitializedEvent has copy, drop {
        storage_unit_id: ID,
        collection_id: ID,
        vault_config_id: ID,
    }

    public struct ReceiptMintedEvent has copy, drop {
        storage_unit_id: ID,
        collection_id: ID,
        balance_id: ID,
        type_id: u64,
        quantity: u64,
        depositor: address,
    }

    public struct ReceiptRedeemedEvent has copy, drop {
        storage_unit_id: ID,
        collection_id: ID,
        balance_id: ID,
        type_id: u64,
        quantity: u64,
        redeemer: address,
    }

    // === Public Functions ===

    /// Initialize the vault for a StorageUnit. Creates the MultiCoin Collection
    /// and VaultConfig, sharing both. Must be called before deposits.
    public fun initialize_vault(
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        ctx: &mut TxContext,
    ) {
        new_vault(storage_unit, owner_cap, ctx).share_vault();
    }

    /// Create the vault for a StorageUnit without sharing it yet, so later
    /// commands in the same PTB can pass the `PendingVault` to Move functions
    /// that read the new `VaultConfig` and `Collection`. The returned
    /// `PendingVault` must be passed to `share_vault` before the transaction
    /// ends. Same authorization as `initialize_vault`.
    ///
    /// `VaultInitializedEvent` is emitted here rather than at `share_vault`, so
    /// it precedes any event a downstream registration emits for the same
    /// vault in the same transaction. The hot potato guarantees the share
    /// follows; if anything aborts, the event goes with the transaction.
    public fun new_vault(
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        ctx: &mut TxContext,
    ): PendingVault {
        let storage_unit_id = object::id(storage_unit);
        assert!(world::access::is_authorized(owner_cap, storage_unit_id), EStorageUnitMismatch);

        let (config, collection) = vault::create_vault(storage_unit_id, ctx);
        event::emit(VaultInitializedEvent {
            storage_unit_id,
            collection_id: object::id(&collection),
            vault_config_id: object::id(&config),
        });
        PendingVault { config, collection }
    }

    /// The pending vault's config, for Move callers acting on it before it is
    /// shared. Returns a reference, so it is not callable as a PTB command.
    public fun pending_vault_config(self: &PendingVault): &VaultConfig {
        &self.config
    }

    /// The pending vault's collection, for Move callers acting on it before it
    /// is shared. Returns a reference, so it is not callable as a PTB command.
    public fun pending_vault_collection(self: &PendingVault): &Collection {
        &self.collection
    }

    /// Share a pending vault's `Collection` and `VaultConfig`, completing
    /// initialization. (`new_vault` already emitted `VaultInitializedEvent`.)
    public fun share_vault(self: PendingVault) {
        let PendingVault { config, collection } = self;
        transfer::public_share_object(collection);
        transfer::public_share_object(config);
    }

    /// Deposit items from player's owned inventory into the extension-controlled
    /// open inventory and mint a multicoin receipt.
    /// The receipt is returned to the caller and can be freely traded.
    public fun deposit_for_receipt<T: key>(
        storage_unit: &mut StorageUnit,
        character: &Character,
        owner_cap: &OwnerCap<T>,
        vault_config: &VaultConfig,
        collection: &mut Collection,
        type_id: u64,
        quantity: u32,
        ctx: &mut TxContext,
    ): Balance {
        // Withdraw from player's owned inventory
        let item = storage_unit.withdraw_by_owner(
            character,
            owner_cap,
            type_id,
            quantity,
            ctx,
        );

        // Deposit to open inventory (extension-controlled)
        storage_unit.deposit_to_open_inventory(
            character,
            item,
            VaultAuth {},
            ctx,
        );

        // Verify vault config matches this storage unit
        let storage_unit_id = object::id(storage_unit);
        assert!(vault_config.storage_unit_id() == storage_unit_id, EStorageUnitMismatch);

        // Mint multicoin receipt
        let receipt = vault::mint(
            vault_config,
            collection,
            type_id,
            quantity as u64,
            ctx,
        );

        event::emit(ReceiptMintedEvent {
            storage_unit_id,
            collection_id: vault_config.collection_id(),
            balance_id: object::id(&receipt),
            type_id,
            quantity: quantity as u64,
            depositor: ctx.sender(),
        });

        receipt
    }

    /// Redeem a receipt to withdraw items from open inventory.
    /// The receipt (multicoin Balance) is burned upon redemption. Anyone holding the receipt can redeem.
    /// If `to_ssu_owner` is true, items are deposited into the SSU owner's main inventory slot.
    /// Otherwise, items are deposited into the redeemer's character owned inventory slot.
    public fun redeem_receipt(
        receipt: Balance,
        storage_unit: &mut StorageUnit,
        character: &Character,
        vault_config: &VaultConfig,
        collection: &mut Collection,
        to_ssu_owner: bool,
        ctx: &mut TxContext,
    ) {
        let balance_id = object::id(&receipt);
        let collection_id = receipt.collection_id();
        let (storage_unit_id, type_id, quantity) = vault::burn(
            vault_config,
            collection,
            receipt,
            ctx,
        );

        // Verify receipt matches this storage unit
        assert!(storage_unit_id == object::id(storage_unit), EStorageUnitMismatch);

        // Withdraw from open inventory
        let item = storage_unit.withdraw_from_open_inventory<VaultAuth>(
            character,
            VaultAuth {},
            type_id,
            quantity as u32,
            ctx,
        );

        if (to_ssu_owner) {
            // Deposit to SSU owner's main inventory (keyed by storage_unit.owner_cap_id)
            storage_unit.deposit_item<VaultAuth>(character, item, VaultAuth {}, ctx);
        } else {
            // Deposit to redeemer's character owned inventory slot
            storage_unit.deposit_to_owned<VaultAuth>(character, item, VaultAuth {}, ctx);
        };

        event::emit(ReceiptRedeemedEvent {
            storage_unit_id,
            collection_id,
            balance_id,
            type_id,
            quantity,
            redeemer: ctx.sender(),
        });
    }

    /// Batch deposit multiple item types in a single transaction.
    /// Each pair of (type_id, quantity) is deposited and a corresponding receipt is minted.
    /// Returns a vector of `Balance` receipts, one per deposit.
    public fun batch_deposit_for_receipt<T: key>(
        storage_unit: &mut StorageUnit,
        character: &Character,
        owner_cap: &OwnerCap<T>,
        vault_config: &VaultConfig,
        collection: &mut Collection,
        type_ids: vector<u64>,
        quantities: vector<u32>,
        ctx: &mut TxContext,
    ): vector<Balance> {
        let len = type_ids.length();
        assert!(len == quantities.length(), EBatchLengthMismatch);

        let mut receipts = vector[];
        let mut i = 0;
        while (i < len) {
            let receipt = deposit_for_receipt(
                storage_unit,
                character,
                owner_cap,
                vault_config,
                collection,
                type_ids[i],
                quantities[i],
                ctx,
            );
            receipts.push_back(receipt);
            i = i + 1;
        };

        receipts
    }

    /// Batch redeem multiple receipts in a single transaction.
    /// Each receipt is burned and items are withdrawn from open inventory.
    /// `to_ssu_owner` controls the deposit destination (see `redeem_receipt`).
    public fun batch_redeem_receipt(
        receipts: vector<Balance>,
        storage_unit: &mut StorageUnit,
        character: &Character,
        vault_config: &VaultConfig,
        collection: &mut Collection,
        to_ssu_owner: bool,
        ctx: &mut TxContext,
    ) {
        let mut i = 0;
        let len = receipts.length();
        let mut receipts = receipts;
        while (i < len) {
            let receipt = receipts.pop_back();
            redeem_receipt(
                receipt,
                storage_unit,
                character,
                vault_config,
                collection,
                to_ssu_owner,
                ctx,
            );
            i = i + 1;
        };
        receipts.destroy_empty();
    }
}
