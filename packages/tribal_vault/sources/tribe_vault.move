/// Tribal Storage Vault — deposit/redeem using tribe-scoped MultiCoin receipts.
///
/// Extends StorageUnit with tribe-gated inventory custody. Each (StorageUnit, tribe_id)
/// pair has exactly one vault. The tribe_id is locked at initialization from the
/// creator's Character — if that player (or any caller) leaves the tribe, their
/// character's tribe_id no longer matches the vault and all operations are blocked.
///
/// Flow:
/// 1. SSU owner calls `initialize_tribe_vault`, passing their Character (tribe_id locked here)
/// 2. SSU owner calls `authorize_extension<TribeVaultAuth>` on the StorageUnit
/// 3. A tribe member calls `deposit_for_tribe_receipt` — character must match vault tribe_id
/// 4. Extension mints a `multicoin::Balance` receipt and returns it to the caller
/// 5. A tribe member calls `redeem_tribe_receipt` — character must also match vault tribe_id
///
/// Access control:
/// - Deposits and redeems both enforce `character::tribe(character) == vault.tribe_id()`
/// - A player who switches tribes loses access immediately (no oracle or callback needed)
/// - The vault config persists but is effectively frozen to outsiders
module tribal_vault::tribe_vault {
    use multicoin::multicoin::{Collection, Balance};
    use sui::event;
    use tribal_vault::tribe_custody::{Self, TribeVaultConfig};
    use world::{access::OwnerCap, character::{Self, Character}, storage_unit::StorageUnit};

    // === Errors ===
    #[error(code = 0)]
    const EStorageUnitMismatch: vector<u8> = b"Receipt belongs to a different storage unit";
    #[error(code = 1)]
    const EBatchLengthMismatch: vector<u8> =
        b"type_ids and quantities vectors must have the same length";
    #[error(code = 2)]
    const ETribeNotMember: vector<u8> =
        b"Character's tribe_id does not match this vault's tribe — access denied";

    // === Structs ===

    /// Witness type for extension authorization
    public struct TribeVaultAuth has drop {}

    // === Events ===

    public struct TribeVaultInitializedEvent has copy, drop {
        storage_unit_id: ID,
        tribe_id: u32,
        collection_id: ID,
        vault_config_id: ID,
    }

    public struct TribeReceiptMintedEvent has copy, drop {
        storage_unit_id: ID,
        tribe_id: u32,
        collection_id: ID,
        balance_id: ID,
        type_id: u64,
        quantity: u64,
        depositor: address,
    }

    public struct TribeReceiptRedeemedEvent has copy, drop {
        storage_unit_id: ID,
        tribe_id: u32,
        collection_id: ID,
        balance_id: ID,
        type_id: u64,
        quantity: u64,
        redeemer: address,
    }

    // === Public Functions ===

    /// Initialize a tribal vault for the caller's tribe on a given StorageUnit.
    /// The tribe_id is read from `character` at this point and locked permanently
    /// into the TribeVaultConfig. One vault per (storage_unit, tribe_id).
    public fun initialize_tribe_vault(
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        character: &Character,
        ctx: &mut TxContext,
    ) {
        let storage_unit_id = object::id(storage_unit);
        assert!(world::access::is_authorized(owner_cap, storage_unit_id), EStorageUnitMismatch);

        let tribe_id = character::tribe(character);

        let (config, collection) = tribe_custody::create_tribe_vault(storage_unit_id, tribe_id, ctx);
        let collection_id = object::id(&collection);
        let vault_config_id = object::id(&config);

        transfer::public_share_object(collection);
        transfer::public_share_object(config);

        event::emit(TribeVaultInitializedEvent {
            storage_unit_id,
            tribe_id,
            collection_id,
            vault_config_id,
        });
    }

    /// Deposit items from a tribe member's owned inventory into the tribal vault
    /// and mint a receipt. The caller's character must belong to the vault's tribe.
    ///
    /// The receipt is returned to the caller. Note: unlike the standard warehouse
    /// receipt, this receipt can only be redeemed by a character in the same tribe.
    public fun deposit_for_tribe_receipt<T: key>(
        storage_unit: &mut StorageUnit,
        character: &Character,
        owner_cap: &OwnerCap<T>,
        vault_config: &TribeVaultConfig,
        collection: &mut Collection,
        type_id: u64,
        quantity: u32,
        ctx: &mut TxContext,
    ): Balance {
        assert!(character::tribe(character) == vault_config.tribe_id(), ETribeNotMember);

        let storage_unit_id = object::id(storage_unit);
        assert!(vault_config.storage_unit_id() == storage_unit_id, EStorageUnitMismatch);

        let item = storage_unit.withdraw_by_owner(character, owner_cap, type_id, quantity, ctx);
        storage_unit.deposit_to_open_inventory(character, item, TribeVaultAuth {}, ctx);

        let receipt = tribe_custody::mint(vault_config, collection, type_id, quantity as u64, ctx);

        event::emit(TribeReceiptMintedEvent {
            storage_unit_id,
            tribe_id: vault_config.tribe_id(),
            collection_id: vault_config.collection_id(),
            balance_id: object::id(&receipt),
            type_id,
            quantity: quantity as u64,
            depositor: ctx.sender(),
        });

        receipt
    }

    /// Redeem a tribe receipt to withdraw items from the tribal vault.
    /// The caller's character must belong to the vault's tribe — ex-members are blocked.
    ///
    /// `to_ssu_owner` controls the deposit destination (same semantics as the
    /// standard warehouse receipt).
    public fun redeem_tribe_receipt(
        receipt: Balance,
        storage_unit: &mut StorageUnit,
        character: &Character,
        vault_config: &TribeVaultConfig,
        collection: &mut Collection,
        to_ssu_owner: bool,
        ctx: &mut TxContext,
    ) {
        assert!(character::tribe(character) == vault_config.tribe_id(), ETribeNotMember);

        let balance_id = object::id(&receipt);
        let collection_id = receipt.collection_id();
        let (storage_unit_id, type_id, quantity) =
            tribe_custody::burn(vault_config, collection, receipt, ctx);

        assert!(storage_unit_id == object::id(storage_unit), EStorageUnitMismatch);

        let item = storage_unit.withdraw_from_open_inventory<TribeVaultAuth>(
            character,
            TribeVaultAuth {},
            type_id,
            quantity as u32,
            ctx,
        );

        if (to_ssu_owner) {
            storage_unit.deposit_item<TribeVaultAuth>(character, item, TribeVaultAuth {}, ctx);
        } else {
            storage_unit.deposit_to_owned<TribeVaultAuth>(character, item, TribeVaultAuth {}, ctx);
        };

        event::emit(TribeReceiptRedeemedEvent {
            storage_unit_id,
            tribe_id: vault_config.tribe_id(),
            collection_id,
            balance_id,
            type_id,
            quantity,
            redeemer: ctx.sender(),
        });
    }

    /// Batch deposit multiple item types in a single transaction.
    public fun batch_deposit_for_tribe_receipt<T: key>(
        storage_unit: &mut StorageUnit,
        character: &Character,
        owner_cap: &OwnerCap<T>,
        vault_config: &TribeVaultConfig,
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
            let receipt = deposit_for_tribe_receipt(
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
    public fun batch_redeem_tribe_receipt(
        receipts: vector<Balance>,
        storage_unit: &mut StorageUnit,
        character: &Character,
        vault_config: &TribeVaultConfig,
        collection: &mut Collection,
        to_ssu_owner: bool,
        ctx: &mut TxContext,
    ) {
        let len = receipts.length();
        let mut receipts = receipts;
        let mut i = 0;
        while (i < len) {
            let receipt = receipts.pop_back();
            redeem_tribe_receipt(
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
