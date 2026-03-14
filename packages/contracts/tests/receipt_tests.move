#[test_only]
module warehouse_receipts::receipt_tests {
    use multicoin::multicoin::{Self, Collection, Balance};
    use std::{string::utf8, unit_test::assert_eq};
    use sui::{clock, test_scenario as ts};
    use warehouse_receipts::{receipt::{Self, VaultAuth}, vault::{Self, VaultConfig}};
    use world::{
        access::{OwnerCap, AdminACL},
        character::{Self, Character},
        energy::EnergyConfig,
        inventory,
        network_node::{Self, NetworkNode},
        object_registry::ObjectRegistry,
        storage_unit::{Self, StorageUnit}
    };

    // === Constants ===
    const OWNER_ITEM_ID: u32 = 1000u32;
    const DEPOSITOR_ITEM_ID: u32 = 2000u32;
    const REDEEMER_ITEM_ID: u32 = 3000u32;
    const LOCATION_HASH: vector<u8> =
        x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
    const MAX_CAPACITY: u64 = 100000;
    const STORAGE_TYPE_ID: u64 = 5555;
    const STORAGE_ITEM_ID: u64 = 90002;

    const LENS_TYPE_ID: u64 = 88070;
    const LENS_ITEM_ID: u64 = 1000004145108;
    const LENS_VOLUME: u64 = 50;
    const LENS_QUANTITY: u32 = 5;

    const AMMO_TYPE_ID: u64 = 99010;
    const AMMO_ITEM_ID: u64 = 2000005255209;
    const AMMO_VOLUME: u64 = 10;
    const AMMO_QUANTITY: u32 = 8;

    const MS_PER_SECOND: u64 = 1000;
    const NWN_TYPE_ID: u64 = 111000;
    const NWN_ITEM_ID: u64 = 5000;
    const FUEL_MAX_CAPACITY: u64 = 1000;
    const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
    const MAX_PRODUCTION: u64 = 100;
    const FUEL_TYPE_ID: u64 = 1;
    const FUEL_VOLUME: u64 = 10;

    // === Test Addresses ===
    fun governor(): address { @0xA }

    fun admin(): address { @0xB }

    fun owner(): address { @0xC }

    fun depositor(): address { @0xD }

    fun redeemer(): address { @0xE }

    // === Setup Helpers ===
    fun setup_world(ts: &mut ts::Scenario) {
        world::test_helpers::setup_world(ts);
        world::test_helpers::configure_assembly_energy(ts);
        world::test_helpers::register_server_address(ts);
    }

    fun create_character(ts: &mut ts::Scenario, user: address, item_id: u32): ID {
        ts::next_tx(ts, admin());
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let character = character::create_character(
            &mut registry,
            &admin_acl,
            item_id,
            utf8(b"tenant"),
            100,
            user,
            utf8(b"name"),
            ts.ctx(),
        );
        let id = object::id(&character);
        character.share_character(&admin_acl, ts.ctx());
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
        id
    }

    fun create_storage_unit(ts: &mut ts::Scenario, character_id: ID): (ID, ID) {
        ts::next_tx(ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let character = ts::take_shared_by_id<Character>(ts, character_id);
        let admin_acl = ts::take_shared<AdminACL>(ts);

        let nwn = network_node::anchor(
            &mut registry,
            &character,
            &admin_acl,
            NWN_ITEM_ID,
            NWN_TYPE_ID,
            LOCATION_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        let nwn_id = object::id(&nwn);
        nwn.share_network_node(&admin_acl, ts.ctx());

        ts::return_shared(character);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);

        ts::next_tx(ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let character = ts::take_shared_by_id<Character>(ts, character_id);
        let storage_unit_id = {
            let admin_acl = ts::take_shared<AdminACL>(ts);
            let storage_unit = storage_unit::anchor(
                &mut registry,
                &mut nwn,
                &character,
                &admin_acl,
                STORAGE_ITEM_ID,
                STORAGE_TYPE_ID,
                MAX_CAPACITY,
                LOCATION_HASH,
                ts.ctx(),
            );
            let id = object::id(&storage_unit);
            storage_unit.share_storage_unit(&admin_acl, ts.ctx());
            ts::return_shared(admin_acl);
            id
        };
        ts::return_shared(character);
        ts::return_shared(registry);
        ts::return_shared(nwn);
        (storage_unit_id, nwn_id)
    }

    fun online_storage_unit(
        ts: &mut ts::Scenario,
        user: address,
        character_id: ID,
        storage_id: ID,
        nwn_id: ID,
    ) {
        let clock = clock::create_for_testing(ts.ctx());
        ts::next_tx(ts, user);
        let mut character = ts::take_shared_by_id<Character>(ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<NetworkNode>(
            ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&character_id),
            ts.ctx(),
        );
        ts::next_tx(ts, user);
        {
            let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
            nwn.deposit_fuel_test(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, &clock);
            ts::return_shared(nwn);
        };
        ts::next_tx(ts, user);
        {
            let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
            nwn.online(&owner_cap, &clock);
            ts::return_shared(nwn);
        };
        character.return_owner_cap(owner_cap, receipt);

        ts::next_tx(ts, user);
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
            let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
            let energy_config = ts::take_shared<EnergyConfig>(ts);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_id),
                ts.ctx(),
            );
            storage_unit.online(&mut nwn, &energy_config, &owner_cap);
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(storage_unit);
            ts::return_shared(nwn);
            ts::return_shared(energy_config);
        };

        ts::return_shared(character);
        clock.destroy_for_testing();
    }

    // === Success Tests ===

    /// Test the full deposit-and-redeem flow with different players:
    /// - Owner: creates SSU, authorizes VaultAuth
    /// - Depositor: deposits items, receives receipt
    /// - Redeemer: receives transferred receipt, redeems items
    #[test]
    fun deposit_and_redeem_by_different_player() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);
        let redeemer_id = create_character(&mut ts, redeemer(), REDEEMER_ITEM_ID);

        // Owner creates, onlines, and authorizes VaultAuth on the storage unit
        let (storage_id, nwn_id) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id, nwn_id);

        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            storage_unit.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&storage_unit, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Depositor: mint items into their owned inventory
        ts::next_tx(&mut ts, depositor());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            storage_unit.game_item_to_chain_inventory_test<Character>(
                &character,
                &owner_cap,
                LENS_ITEM_ID,
                LENS_TYPE_ID,
                LENS_VOLUME,
                LENS_QUANTITY,
                ts.ctx(),
            );
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Get owner_cap IDs for assertions
        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };
        let redeemer_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, redeemer_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };
        // Depositor: deposit items and receive receipt
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                LENS_QUANTITY,
                ts.ctx(),
            );

            // Verify receipt properties
            assert_eq!(deposit_receipt.value(), LENS_QUANTITY as u64);
            assert_eq!(deposit_receipt.asset_id(), LENS_TYPE_ID);

            // Transfer receipt to redeemer
            transfer::public_transfer(deposit_receipt, redeemer());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Assert: items moved from depositor's owned inventory to open inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            // Open inventory has the items
            assert_eq!(su.item_quantity(su.open_storage_key(), LENS_TYPE_ID), LENS_QUANTITY);
            // Depositor's owned inventory is empty
            assert!(!su.contains_item(depositor_owner_cap_id, LENS_TYPE_ID));
            ts::return_shared(su);
        };

        // Redeemer: redeem the receipt (depositor is offline)
        ts::next_tx(&mut ts, redeemer());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut redeemer_char = ts::take_shared_by_id<Character>(&ts, redeemer_id);
            let (owner_cap, cap_receipt) = redeemer_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&redeemer_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            // Take the deposit receipt (multicoin Balance)
            let deposit_receipt = ts::take_from_sender<Balance>(&ts);

            receipt::redeem_receipt(
                deposit_receipt,
                &mut storage_unit,
                &redeemer_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            redeemer_char.return_owner_cap(owner_cap, cap_receipt);
            ts::return_shared(redeemer_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Assert: items moved from open inventory to redeemer's owned inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            // Open inventory is empty
            assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
            // Redeemer's owned inventory has the items
            assert_eq!(su.item_quantity(redeemer_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            // Depositor's owned inventory still empty
            assert!(!su.contains_item(depositor_owner_cap_id, LENS_TYPE_ID));
            ts::return_shared(su);
        };

        ts::end(ts);
    }

    /// Test that the depositor can redeem their own receipt
    #[test]
    fun deposit_and_self_redeem() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

        // Setup storage unit
        let (storage_id, nwn_id) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id, nwn_id);

        // Authorize VaultAuth and initialize vault
        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            storage_unit.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&storage_unit, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Mint items to depositor
        ts::next_tx(&mut ts, depositor());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            storage_unit.game_item_to_chain_inventory_test<Character>(
                &character,
                &owner_cap,
                LENS_ITEM_ID,
                LENS_TYPE_ID,
                LENS_VOLUME,
                LENS_QUANTITY,
                ts.ctx(),
            );
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Deposit and get receipt
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                LENS_QUANTITY,
                ts.ctx(),
            );

            // Keep receipt for self
            transfer::public_transfer(deposit_receipt, depositor());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Self-redeem
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, cap_receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = ts::take_from_sender<Balance>(&ts);
            receipt::redeem_receipt(
                deposit_receipt,
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            depositor_char.return_owner_cap(owner_cap, cap_receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Verify items back in depositor's owned inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            ts::return_shared(su);
        };

        ts::end(ts);
    }

    /// Test redeem-and-gift: receipt holder redeems but directs items to a different player's character.
    #[test]
    fun redeem_and_gift_to_third_party() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);
        let redeemer_id = create_character(&mut ts, redeemer(), REDEEMER_ITEM_ID);
        let gift_recipient_id = create_character(&mut ts, @0xF, 4000u32);

        let (storage_id, nwn_id) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id, nwn_id);

        // Authorize VaultAuth and initialize vault
        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            storage_unit.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&storage_unit, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Depositor: mint items into owned inventory
        ts::next_tx(&mut ts, depositor());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            storage_unit.game_item_to_chain_inventory_test<Character>(
                &character,
                &owner_cap,
                LENS_ITEM_ID,
                LENS_TYPE_ID,
                LENS_VOLUME,
                LENS_QUANTITY,
                ts.ctx(),
            );
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        let redeemer_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, redeemer_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };
        let gift_recipient_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, gift_recipient_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Depositor: deposit and get receipt, transfer to redeemer
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                LENS_QUANTITY,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, redeemer());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Redeemer: redeem the receipt but pass gift_recipient's character as the target
        ts::next_tx(&mut ts, redeemer());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let gift_recipient_char = ts::take_shared_by_id<Character>(&ts, gift_recipient_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = ts::take_from_sender<Balance>(&ts);

            receipt::redeem_receipt(
                deposit_receipt,
                &mut storage_unit,
                &gift_recipient_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(gift_recipient_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Assert: items landed in gift recipient's owned inventory, not redeemer's
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            assert_eq!(su.item_quantity(gift_recipient_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            assert!(!su.has_inventory(redeemer_owner_cap_id));
            assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
            ts::return_shared(su);
        };

        ts::end(ts);
    }

    // === Failure Tests ===

    #[test]
    #[expected_failure(abort_code = 0, location = multicoin)]
    fun redeem_at_wrong_storage_unit_aborts() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

        // Setup first storage unit
        let (storage_id_1, nwn_id_1) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id_1, nwn_id_1);

        // Authorize and initialize vault on first SSU
        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            storage_unit.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&storage_unit, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Mint items
        ts::next_tx(&mut ts, depositor());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            storage_unit.game_item_to_chain_inventory_test<Character>(
                &character,
                &owner_cap,
                LENS_ITEM_ID,
                LENS_TYPE_ID,
                LENS_VOLUME,
                LENS_QUANTITY,
                ts.ctx(),
            );
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Deposit at first SSU
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                LENS_QUANTITY,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, depositor());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Create second storage unit
        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);

        let nwn_2 = network_node::anchor(
            &mut registry,
            &character,
            &admin_acl,
            NWN_ITEM_ID + 1,
            NWN_TYPE_ID,
            LOCATION_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        let nwn_id_2 = object::id(&nwn_2);
        nwn_2.share_network_node(&admin_acl, ts.ctx());

        ts::return_shared(character);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);

        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let mut nwn_2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id_2);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let storage_id_2 = {
            let admin_acl = ts::take_shared<AdminACL>(&ts);
            let storage_unit = storage_unit::anchor(
                &mut registry,
                &mut nwn_2,
                &character,
                &admin_acl,
                STORAGE_ITEM_ID + 1,
                STORAGE_TYPE_ID,
                MAX_CAPACITY,
                LOCATION_HASH,
                ts.ctx(),
            );
            let id = object::id(&storage_unit);
            storage_unit.share_storage_unit(&admin_acl, ts.ctx());
            ts::return_shared(admin_acl);
            id
        };
        ts::return_shared(character);
        ts::return_shared(registry);
        ts::return_shared(nwn_2);

        online_storage_unit(&mut ts, owner(), owner_id, storage_id_2, nwn_id_2);

        // Authorize and initialize vault on second SSU
        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut storage_unit_2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
            storage_unit_2.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&storage_unit_2, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit_2);
        };

        // Try to redeem receipt from SSU1 at SSU2's vault — should fail with EWrongStorageUnit
        // because the balance's collection_id doesn't match SSU2's VaultConfig
        ts::next_tx(&mut ts, depositor());
        let mut storage_unit_2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
        let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        // Take the second vault config (SSU2's), not the first
        let vault_config_1 = ts::take_shared<VaultConfig>(&ts);
        // We need SSU2's vault config — but the receipt is from SSU1's collection.
        // The burn will fail because the balance's collection_id doesn't match SSU2's cap.
        let vault_config_2 = ts::take_shared<VaultConfig>(&ts);
        let mut collection_2 = ts::take_shared<Collection>(&ts);

        let deposit_receipt = ts::take_from_sender<Balance>(&ts);

        receipt::redeem_receipt(
            deposit_receipt,
            &mut storage_unit_2,
            &depositor_char,
            &vault_config_2,
            &mut collection_2,
            ts.ctx(),
        );

        abort 0
    }

    /// Test that the SSU owner cannot withdraw items from the open inventory using their OwnerCap<StorageUnit>.
    #[test]
    #[expected_failure(abort_code = inventory::EItemDoesNotExist)]
    fun owner_cannot_withdraw_from_open_inventory() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

        let (storage_id, nwn_id) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id, nwn_id);

        // Authorize VaultAuth and initialize vault
        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            storage_unit.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&storage_unit, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Depositor: mint items into owned inventory
        ts::next_tx(&mut ts, depositor());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            storage_unit.game_item_to_chain_inventory_test<Character>(
                &character,
                &owner_cap,
                LENS_ITEM_ID,
                LENS_TYPE_ID,
                LENS_VOLUME,
                LENS_QUANTITY,
                ts.ctx(),
            );
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Depositor: deposit items into open inventory via extension
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                LENS_QUANTITY,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, depositor());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // SSU owner tries to withdraw from open inventory — aborts with EItemDoesNotExist
        ts::next_tx(&mut ts, owner());
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut owner_char = ts::take_shared_by_id<Character>(&ts, owner_id);
        let (owner_cap, _receipt) = owner_char.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
            ts.ctx(),
        );

        let _item = storage_unit.withdraw_by_owner(
            &owner_char,
            &owner_cap,
            LENS_TYPE_ID,
            LENS_QUANTITY,
            ts.ctx(),
        );

        abort 0
    }

    // === Shared Setup Helper ===

    /// Sets up world, owner + depositor characters, SSU with vault authorized and initialized.
    /// Returns (owner_id, depositor_id, storage_id, nwn_id).
    fun setup_vault_scenario(ts: &mut ts::Scenario): (ID, ID, ID, ID) {
        setup_world(ts);
        let owner_id = create_character(ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(ts, depositor(), DEPOSITOR_ITEM_ID);

        let (storage_id, nwn_id) = create_storage_unit(ts, owner_id);
        online_storage_unit(ts, owner(), owner_id, storage_id, nwn_id);

        // Authorize VaultAuth and initialize vault
        ts::next_tx(ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
            storage_unit.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&storage_unit, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        (owner_id, depositor_id, storage_id, nwn_id)
    }

    /// Mint items into depositor's owned inventory.
    fun mint_items_to_depositor(
        ts: &mut ts::Scenario,
        depositor_id: ID,
        storage_id: ID,
        item_id: u64,
        type_id: u64,
        volume: u64,
        quantity: u32,
    ) {
        ts::next_tx(ts, depositor());
        let mut character = ts::take_shared_by_id<Character>(ts, depositor_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        storage_unit.game_item_to_chain_inventory_test<Character>(
            &character,
            &owner_cap,
            item_id,
            type_id,
            volume,
            quantity,
            ts.ctx(),
        );
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(storage_unit);
    }

    /// Deposit items and return receipt to depositor's address.
    fun deposit_and_keep_receipt(
        ts: &mut ts::Scenario,
        depositor_id: ID,
        storage_id: ID,
        type_id: u64,
        quantity: u32,
    ) {
        ts::next_tx(ts, depositor());
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(ts, depositor_id);
        let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );
        let vault_config = ts::take_shared<VaultConfig>(ts);
        let mut collection = ts::take_shared<Collection>(ts);

        let deposit_receipt = receipt::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            &vault_config,
            &mut collection,
            type_id,
            quantity,
            ts.ctx(),
        );
        transfer::public_transfer(deposit_receipt, depositor());

        depositor_char.return_owner_cap(owner_cap, receipt);
        ts::return_shared(depositor_char);
        ts::return_shared(storage_unit);
        ts::return_shared(vault_config);
        ts::return_shared(collection);
    }

    // === Happy Path Tests ===

    /// Test partial redemption via splitting a receipt Balance.
    /// Deposit 5, split into 2+3, redeem only 2, verify 3 remain in open inventory.
    #[test]
    fun partial_redeem_via_split() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );
        deposit_and_keep_receipt(&mut ts, depositor_id, storage_id, LENS_TYPE_ID, LENS_QUANTITY);

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Split receipt: keep 3, redeem 2
        ts::next_tx(&mut ts, depositor());
        {
            let mut deposit_receipt = ts::take_from_sender<Balance>(&ts);
            let split_receipt = deposit_receipt.split(2, ts.ctx());
            // Keep the remainder (3)
            transfer::public_transfer(deposit_receipt, depositor());
            // Redeem 2
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::redeem_receipt(
                split_receipt,
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Assert: 2 items redeemed to depositor, 3 still in open inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), 2);
            assert_eq!(su.item_quantity(su.open_storage_key(), LENS_TYPE_ID), 3);
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 3);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        // Verify remaining receipt has value 3
        ts::next_tx(&mut ts, depositor());
        {
            let remaining = ts::take_from_sender<Balance>(&ts);
            assert_eq!(remaining.value(), 3);
            transfer::public_transfer(remaining, depositor());
        };

        ts::end(ts);
    }

    /// Test joining two receipts of the same type and redeeming the combined balance.
    #[test]
    fun join_receipts_then_redeem() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        // Mint 10 items total (two batches of 5)
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        // First deposit of 3
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let receipt_1 = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                3,
                ts.ctx(),
            );
            transfer::public_transfer(receipt_1, depositor());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Second deposit of 2
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let receipt_2 = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                2,
                ts.ctx(),
            );
            transfer::public_transfer(receipt_2, depositor());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Join two receipts and redeem them together
        ts::next_tx(&mut ts, depositor());
        {
            let mut receipt_a = ts::take_from_sender<Balance>(&ts);
            let receipt_b = ts::take_from_sender<Balance>(&ts);
            receipt_a.join(receipt_b, ts.ctx());
            assert_eq!(receipt_a.value(), 5);

            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::redeem_receipt(
                receipt_a,
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Assert: all items back in depositor's owned inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 0);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        ts::end(ts);
    }

    /// Test depositing two different item types and redeeming them independently.
    #[test]
    fun multiple_deposits_different_types() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        // Mint both item types
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
        );

        // Deposit LENS
        deposit_and_keep_receipt(&mut ts, depositor_id, storage_id, LENS_TYPE_ID, LENS_QUANTITY);
        // Deposit AMMO
        deposit_and_keep_receipt(&mut ts, depositor_id, storage_id, AMMO_TYPE_ID, AMMO_QUANTITY);

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Verify both types in open inventory and supply tracked independently
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(su.open_storage_key(), LENS_TYPE_ID), LENS_QUANTITY);
            assert_eq!(su.item_quantity(su.open_storage_key(), AMMO_TYPE_ID), AMMO_QUANTITY);
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), LENS_QUANTITY as u64);
            assert_eq!(vault::total_supply(&collection, AMMO_TYPE_ID), AMMO_QUANTITY as u64);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        // Redeem only LENS receipt
        ts::next_tx(&mut ts, depositor());
        {
            let receipt_1 = ts::take_from_sender<Balance>(&ts);
            let receipt_2 = ts::take_from_sender<Balance>(&ts);

            // Identify which receipt is LENS vs AMMO
            let (lens_receipt, ammo_receipt) = if (receipt_1.asset_id() == LENS_TYPE_ID) {
                (receipt_1, receipt_2)
            } else {
                (receipt_2, receipt_1)
            };

            // Redeem LENS
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::redeem_receipt(
                lens_receipt,
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            // Keep ammo receipt
            transfer::public_transfer(ammo_receipt, depositor());

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Assert: LENS redeemed, AMMO still in open inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            assert!(!su.contains_item(depositor_owner_cap_id, AMMO_TYPE_ID));
            assert_eq!(su.item_quantity(su.open_storage_key(), AMMO_TYPE_ID), AMMO_QUANTITY);
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 0);
            assert_eq!(vault::total_supply(&collection, AMMO_TYPE_ID), AMMO_QUANTITY as u64);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        // Redeem AMMO
        ts::next_tx(&mut ts, depositor());
        {
            let ammo_receipt = ts::take_from_sender<Balance>(&ts);
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::redeem_receipt(
                ammo_receipt,
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Final state: both types back in owned inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);
            ts::return_shared(su);
        };

        ts::end(ts);
    }

    /// Test that total_supply tracks correctly across multiple deposits and partial redemptions.
    #[test]
    fun total_supply_tracks_correctly() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        // Mint 5 items
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        // Deposit 3
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                3,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, depositor());

            // Check total_supply after first deposit
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 3);

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Deposit remaining 2
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                2,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, depositor());

            // Check total_supply doubled
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 5);

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Redeem partial (split 2 from first receipt of 3)
        ts::next_tx(&mut ts, depositor());
        {
            let mut receipt_a = ts::take_from_sender<Balance>(&ts);
            let receipt_b = ts::take_from_sender<Balance>(&ts);
            let partial = receipt_a.split(2, ts.ctx());
            transfer::public_transfer(receipt_a, depositor());
            transfer::public_transfer(receipt_b, depositor());

            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::redeem_receipt(
                partial,
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            // Supply decreased by 2
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 3);

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        ts::end(ts);
    }

    /// Test two independent SSUs with their own vaults operating without interference.
    #[test]
    fun multiple_independent_vaults() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

        // Create and fully set up SSU1 (vault init) BEFORE creating SSU2,
        // so there's only one OwnerCap<StorageUnit> when we borrow.
        let (storage_id_1, nwn_id_1) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id_1, nwn_id_1);

        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut su1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            su1.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&su1, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(su1);
        };

        // Now create SSU2
        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let nwn_2 = network_node::anchor(
            &mut registry,
            &character,
            &admin_acl,
            NWN_ITEM_ID + 10,
            NWN_TYPE_ID,
            LOCATION_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        let nwn_id_2 = object::id(&nwn_2);
        nwn_2.share_network_node(&admin_acl, ts.ctx());
        ts::return_shared(character);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);

        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let mut nwn_2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id_2);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let storage_id_2 = {
            let admin_acl = ts::take_shared<AdminACL>(&ts);
            let su = storage_unit::anchor(
                &mut registry,
                &mut nwn_2,
                &character,
                &admin_acl,
                STORAGE_ITEM_ID + 10,
                STORAGE_TYPE_ID,
                MAX_CAPACITY,
                LOCATION_HASH,
                ts.ctx(),
            );
            let id = object::id(&su);
            su.share_storage_unit(&admin_acl, ts.ctx());
            ts::return_shared(admin_acl);
            id
        };
        ts::return_shared(character);
        ts::return_shared(registry);
        ts::return_shared(nwn_2);

        online_storage_unit(&mut ts, owner(), owner_id, storage_id_2, nwn_id_2);

        // Authorize and initialize vault on SSU2 (SSU2's cap is now most recent)
        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut su2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
            su2.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&su2, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(su2);
        };

        // Mint items to depositor at both SSUs
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id_1,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id_2,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
        );

        // Deposit LENS at SSU1 (must disambiguate vault configs since two exist)
        ts::next_tx(&mut ts, depositor());
        {
            let mut su1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vc_a = ts::take_shared<VaultConfig>(&ts);
            let vc_b = ts::take_shared<VaultConfig>(&ts);
            let (vault_config_1, vault_config_2) = if (vc_a.storage_unit_id() == storage_id_1) {
                (vc_a, vc_b)
            } else {
                (vc_b, vc_a)
            };
            let mut col_a = ts::take_shared<Collection>(&ts);
            let mut col_b = ts::take_shared<Collection>(&ts);
            let collection_id_1 = vault_config_1.collection_id();
            let (collection_1, _collection_2) = if (object::id(&col_a) == collection_id_1) {
                (&mut col_a, &mut col_b)
            } else {
                (&mut col_b, &mut col_a)
            };

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut su1,
                &depositor_char,
                &owner_cap,
                &vault_config_1,
                collection_1,
                LENS_TYPE_ID,
                LENS_QUANTITY,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, depositor());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(su1);
            ts::return_shared(vault_config_1);
            ts::return_shared(vault_config_2);
            ts::return_shared(col_a);
            ts::return_shared(col_b);
        };

        // Deposit AMMO at SSU2 — need to use the correct vault_config (SSU2's)
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            // Take both vault configs; one belongs to SSU1, one to SSU2
            let vc_a = ts::take_shared<VaultConfig>(&ts);
            let vc_b = ts::take_shared<VaultConfig>(&ts);
            let (vault_config_2, vault_config_1) = if (vc_a.storage_unit_id() == storage_id_2) {
                (vc_a, vc_b)
            } else {
                (vc_b, vc_a)
            };

            let mut col_a = ts::take_shared<Collection>(&ts);
            let mut col_b = ts::take_shared<Collection>(&ts);
            // Determine which collection belongs to SSU2
            let collection_id_2 = vault_config_2.collection_id();
            let (collection_2, _collection_1) = if (object::id(&col_a) == collection_id_2) {
                (&mut col_a, &mut col_b)
            } else {
                (&mut col_b, &mut col_a)
            };

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config_2,
                collection_2,
                AMMO_TYPE_ID,
                AMMO_QUANTITY,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, depositor());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config_1);
            ts::return_shared(vault_config_2);
            ts::return_shared(col_a);
            ts::return_shared(col_b);
        };

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Assert: each SSU has its items in open inventory, depositor's owned inventories are empty
        ts::next_tx(&mut ts, admin());
        {
            let su1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            let su2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
            assert_eq!(su1.item_quantity(su1.open_storage_key(), LENS_TYPE_ID), LENS_QUANTITY);
            assert!(!su1.contains_item(depositor_owner_cap_id, LENS_TYPE_ID));
            assert_eq!(su2.item_quantity(su2.open_storage_key(), AMMO_TYPE_ID), AMMO_QUANTITY);
            assert!(!su2.contains_item(depositor_owner_cap_id, AMMO_TYPE_ID));
            ts::return_shared(su1);
            ts::return_shared(su2);
        };

        ts::end(ts);
    }

    /// Test deposit all items and redeem all — original state fully restored.
    #[test]
    fun deposit_all_then_redeem_all_restores_state() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Deposit all
        deposit_and_keep_receipt(&mut ts, depositor_id, storage_id, LENS_TYPE_ID, LENS_QUANTITY);

        // Verify: owned empty, open has items
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert!(!su.contains_item(depositor_owner_cap_id, LENS_TYPE_ID));
            assert_eq!(su.item_quantity(su.open_storage_key(), LENS_TYPE_ID), LENS_QUANTITY);
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), LENS_QUANTITY as u64);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        // Redeem all
        ts::next_tx(&mut ts, depositor());
        {
            let deposit_receipt = ts::take_from_sender<Balance>(&ts);
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::redeem_receipt(
                deposit_receipt,
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Verify: state fully restored
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 0);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        ts::end(ts);
    }

    // === Failure / Security Tests ===

    /// Test deposit with wrong VaultConfig (SSU2's config used against SSU1's storage unit).
    #[test]
    #[
        expected_failure(
            abort_code = receipt::EStorageUnitMismatch,
            location = warehouse_receipts::receipt,
        ),
    ]
    fun deposit_with_wrong_vault_config_aborts() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

        // Create SSU1 with vault
        let (storage_id_1, nwn_id_1) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id_1, nwn_id_1);

        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut su1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            su1.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&su1, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(su1);
        };

        // Create SSU2 with vault
        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let nwn_2 = network_node::anchor(
            &mut registry,
            &character,
            &admin_acl,
            NWN_ITEM_ID + 20,
            NWN_TYPE_ID,
            LOCATION_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        let nwn_id_2 = object::id(&nwn_2);
        nwn_2.share_network_node(&admin_acl, ts.ctx());
        ts::return_shared(character);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);

        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let mut nwn_2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id_2);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let storage_id_2 = {
            let admin_acl = ts::take_shared<AdminACL>(&ts);
            let su = storage_unit::anchor(
                &mut registry,
                &mut nwn_2,
                &character,
                &admin_acl,
                STORAGE_ITEM_ID + 20,
                STORAGE_TYPE_ID,
                MAX_CAPACITY,
                LOCATION_HASH,
                ts.ctx(),
            );
            let id = object::id(&su);
            su.share_storage_unit(&admin_acl, ts.ctx());
            ts::return_shared(admin_acl);
            id
        };
        ts::return_shared(character);
        ts::return_shared(registry);
        ts::return_shared(nwn_2);

        online_storage_unit(&mut ts, owner(), owner_id, storage_id_2, nwn_id_2);

        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut su2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
            su2.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&su2, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(su2);
        };

        // Mint items at SSU1
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id_1,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        // Try to deposit at SSU1 but use SSU2's VaultConfig — should abort with EStorageUnitMismatch
        ts::next_tx(&mut ts, depositor());
        let mut su1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, _cap_receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );
        let vc_a = ts::take_shared<VaultConfig>(&ts);
        let vc_b = ts::take_shared<VaultConfig>(&ts);
        // Use SSU2's vault config with SSU1
        let (vault_config_2, _vault_config_1) = if (vc_a.storage_unit_id() == storage_id_2) {
            (vc_a, vc_b)
        } else {
            (vc_b, vc_a)
        };
        let mut collection = ts::take_shared<Collection>(&ts);

        let _receipt = receipt::deposit_for_receipt(
            &mut su1,
            &depositor_char,
            &owner_cap,
            &vault_config_2,
            &mut collection,
            LENS_TYPE_ID,
            LENS_QUANTITY,
            ts.ctx(),
        );

        abort 0
    }

    /// Test that depositing without authorizing VaultAuth extension aborts.
    #[test]
    #[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
    fun deposit_without_extension_authorization_aborts() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

        let (storage_id, nwn_id) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id, nwn_id);

        // Initialize vault but DO NOT call authorize_extension<VaultAuth>
        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            receipt::initialize_vault(&storage_unit, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(storage_unit);
        };

        // Mint items
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        // Try to deposit — extension not authorized, should abort
        ts::next_tx(&mut ts, depositor());
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, _receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );
        let vault_config = ts::take_shared<VaultConfig>(&ts);
        let mut collection = ts::take_shared<Collection>(&ts);

        let _receipt = receipt::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            &vault_config,
            &mut collection,
            LENS_TYPE_ID,
            LENS_QUANTITY,
            ts.ctx(),
        );

        abort 0
    }

    /// Test depositing more items than owned aborts.
    #[test]
    #[expected_failure(abort_code = inventory::EInventoryInsufficientQuantity)]
    fun deposit_more_than_owned_aborts() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        // Mint 5 items
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        // Try to deposit 10 (more than the 5 owned)
        ts::next_tx(&mut ts, depositor());
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, _receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );
        let vault_config = ts::take_shared<VaultConfig>(&ts);
        let mut collection = ts::take_shared<Collection>(&ts);

        let _receipt = receipt::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            &vault_config,
            &mut collection,
            LENS_TYPE_ID,
            10, // more than LENS_QUANTITY (5)
            ts.ctx(),
        );

        abort 0
    }

    /// Test that a non-owner cannot initialize the vault.
    /// Creates two SSUs, tries to use SSU2's owner_cap to initialize vault on SSU1.
    #[test]
    #[
        expected_failure(
            abort_code = receipt::EStorageUnitMismatch,
            location = warehouse_receipts::receipt,
        ),
    ]
    fun non_owner_cannot_initialize_vault() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let _depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

        // Create SSU1 owned by owner
        let (storage_id_1, nwn_id_1) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id_1, nwn_id_1);

        // Create SSU2 (also owned by same owner, but separate cap)
        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let nwn_2 = network_node::anchor(
            &mut registry,
            &character,
            &admin_acl,
            NWN_ITEM_ID + 40,
            NWN_TYPE_ID,
            LOCATION_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        let nwn_id_2 = object::id(&nwn_2);
        nwn_2.share_network_node(&admin_acl, ts.ctx());
        ts::return_shared(character);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);

        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let mut nwn_2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id_2);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let _storage_id_2 = {
            let admin_acl = ts::take_shared<AdminACL>(&ts);
            let su = storage_unit::anchor(
                &mut registry,
                &mut nwn_2,
                &character,
                &admin_acl,
                STORAGE_ITEM_ID + 40,
                STORAGE_TYPE_ID,
                MAX_CAPACITY,
                LOCATION_HASH,
                ts.ctx(),
            );
            let id = object::id(&su);
            su.share_storage_unit(&admin_acl, ts.ctx());
            ts::return_shared(admin_acl);
            id
        };
        ts::return_shared(character);
        ts::return_shared(registry);
        ts::return_shared(nwn_2);

        // Owner borrows OwnerCap<StorageUnit> for SSU2, tries to use on SSU1
        ts::next_tx(&mut ts, owner());
        let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let (owner_cap, _receipt) = character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
            ts.ctx(),
        );
        let storage_unit_1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);

        // This should abort: owner_cap is for SSU2, not SSU1
        receipt::initialize_vault(&storage_unit_1, &owner_cap, ts.ctx());

        abort 0
    }

    /// Test redeem with mismatched vault config aborts (SSU2's config used to redeem receipt from SSU1).
    /// The vault::burn detects the balance's collection doesn't match the config's collection_cap.
    #[test]
    #[expected_failure(abort_code = vault::EWrongStorageUnit, location = warehouse_receipts::vault)]
    fun redeem_with_mismatched_collection_aborts() {
        let mut ts = ts::begin(governor());
        setup_world(&mut ts);

        let owner_id = create_character(&mut ts, owner(), OWNER_ITEM_ID);
        let depositor_id = create_character(&mut ts, depositor(), DEPOSITOR_ITEM_ID);

        // Create two SSUs with vaults
        let (storage_id_1, nwn_id_1) = create_storage_unit(&mut ts, owner_id);
        online_storage_unit(&mut ts, owner(), owner_id, storage_id_1, nwn_id_1);

        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut su1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            su1.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&su1, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(su1);
        };

        // Create SSU2
        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let nwn_2 = network_node::anchor(
            &mut registry,
            &character,
            &admin_acl,
            NWN_ITEM_ID + 30,
            NWN_TYPE_ID,
            LOCATION_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        let nwn_id_2 = object::id(&nwn_2);
        nwn_2.share_network_node(&admin_acl, ts.ctx());
        ts::return_shared(character);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);

        ts::next_tx(&mut ts, admin());
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let mut nwn_2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id_2);
        let character = ts::take_shared_by_id<Character>(&ts, owner_id);
        let storage_id_2 = {
            let admin_acl = ts::take_shared<AdminACL>(&ts);
            let su = storage_unit::anchor(
                &mut registry,
                &mut nwn_2,
                &character,
                &admin_acl,
                STORAGE_ITEM_ID + 30,
                STORAGE_TYPE_ID,
                MAX_CAPACITY,
                LOCATION_HASH,
                ts.ctx(),
            );
            let id = object::id(&su);
            su.share_storage_unit(&admin_acl, ts.ctx());
            ts::return_shared(admin_acl);
            id
        };
        ts::return_shared(character);
        ts::return_shared(registry);
        ts::return_shared(nwn_2);

        online_storage_unit(&mut ts, owner(), owner_id, storage_id_2, nwn_id_2);

        ts::next_tx(&mut ts, owner());
        {
            let mut character = ts::take_shared_by_id<Character>(&ts, owner_id);
            let (owner_cap, receipt) = character.borrow_owner_cap<StorageUnit>(
                ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&owner_id),
                ts.ctx(),
            );
            let mut su2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_2);
            su2.authorize_extension<VaultAuth>(&owner_cap);
            receipt::initialize_vault(&su2, &owner_cap, ts.ctx());
            character.return_owner_cap(owner_cap, receipt);
            ts::return_shared(character);
            ts::return_shared(su2);
        };

        // Mint and deposit at SSU1 (must manually pick SSU1's vault config since two exist)
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id_1,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        ts::next_tx(&mut ts, depositor());
        {
            let mut su1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vc_a = ts::take_shared<VaultConfig>(&ts);
            let vc_b = ts::take_shared<VaultConfig>(&ts);
            let (vault_config_1, vault_config_2) = if (vc_a.storage_unit_id() == storage_id_1) {
                (vc_a, vc_b)
            } else {
                (vc_b, vc_a)
            };
            let mut col_a = ts::take_shared<Collection>(&ts);
            let mut col_b = ts::take_shared<Collection>(&ts);
            let collection_id_1 = vault_config_1.collection_id();
            let (collection_1, _collection_2) = if (object::id(&col_a) == collection_id_1) {
                (&mut col_a, &mut col_b)
            } else {
                (&mut col_b, &mut col_a)
            };

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut su1,
                &depositor_char,
                &owner_cap,
                &vault_config_1,
                collection_1,
                LENS_TYPE_ID,
                LENS_QUANTITY,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, depositor());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(su1);
            ts::return_shared(vault_config_1);
            ts::return_shared(vault_config_2);
            ts::return_shared(col_a);
            ts::return_shared(col_b);
        };

        // Try to redeem at SSU1 but use SSU2's vault config — storage_unit_id mismatch
        ts::next_tx(&mut ts, depositor());
        let deposit_receipt = ts::take_from_sender<Balance>(&ts);
        let mut su1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_id_1);
        let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let vc_a = ts::take_shared<VaultConfig>(&ts);
        let vc_b = ts::take_shared<VaultConfig>(&ts);
        let (vault_config_2, _vault_config_1) = if (vc_a.storage_unit_id() == storage_id_2) {
            (vc_a, vc_b)
        } else {
            (vc_b, vc_a)
        };
        let mut collection = ts::take_shared<Collection>(&ts);

        // This should abort: vault_config_2's storage_unit_id won't match SSU1
        receipt::redeem_receipt(
            deposit_receipt,
            &mut su1,
            &depositor_char,
            &vault_config_2,
            &mut collection,
            ts.ctx(),
        );

        abort 0
    }

    /// Test depositing zero quantity aborts.
    #[test]
    #[expected_failure]
    fun zero_quantity_deposit_aborts() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        // Mint items so the player has something
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        // Try to deposit 0
        ts::next_tx(&mut ts, depositor());
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, _receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );
        let vault_config = ts::take_shared<VaultConfig>(&ts);
        let mut collection = ts::take_shared<Collection>(&ts);

        let _receipt = receipt::deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            &vault_config,
            &mut collection,
            LENS_TYPE_ID,
            0,
            ts.ctx(),
        );

        abort 0
    }

    // === Composability Tests ===

    /// Test that a receipt survives a multi-hop transfer chain: A → B → C, then C redeems.
    #[test]
    fun receipt_survives_transfer_chain() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);
        let _redeemer_id = create_character(&mut ts, redeemer(), REDEEMER_ITEM_ID);
        let final_holder_id = create_character(&mut ts, @0xF, 4000u32);

        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        // Depositor deposits and sends receipt to redeemer (hop 1)
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let deposit_receipt = receipt::deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                LENS_TYPE_ID,
                LENS_QUANTITY,
                ts.ctx(),
            );
            transfer::public_transfer(deposit_receipt, redeemer());

            depositor_char.return_owner_cap(owner_cap, receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Redeemer forwards receipt to final holder (hop 2)
        ts::next_tx(&mut ts, redeemer());
        {
            let deposit_receipt = ts::take_from_sender<Balance>(&ts);
            transfer::public_transfer(deposit_receipt, @0xF);
        };

        let final_holder_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, final_holder_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Final holder redeems (hop 3)
        ts::next_tx(&mut ts, @0xF);
        {
            let deposit_receipt = ts::take_from_sender<Balance>(&ts);
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let final_char = ts::take_shared_by_id<Character>(&ts, final_holder_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::redeem_receipt(
                deposit_receipt,
                &mut storage_unit,
                &final_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(final_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Assert: items in final holder's owned inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            assert_eq!(su.item_quantity(final_holder_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
            ts::return_shared(su);
        };

        ts::end(ts);
    }

    /// Test split-and-recombine algebra: deposit 5, split 2+3, split 3 into 1+2,
    /// join 2+2=4, redeem 4. Verify 1 remaining in receipt, 1 in open inventory.
    #[test]
    fun split_and_recombine_then_redeem() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );
        deposit_and_keep_receipt(&mut ts, depositor_id, storage_id, LENS_TYPE_ID, LENS_QUANTITY);

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Split and recombine: 5 → split(2) → 3+2 → split 3 into (1) → 2+2+1 → join 2+2=4
        ts::next_tx(&mut ts, depositor());
        {
            let mut original = ts::take_from_sender<Balance>(&ts); // value=5
            let part_a = original.split(2, ts.ctx()); // original=3, part_a=2
            let part_b = original.split(1, ts.ctx()); // original=2, part_b=1
            // Now: original=2, part_a=2, part_b=1

            // Join original(2) + part_a(2) = 4
            original.join(part_a, ts.ctx());
            assert_eq!(original.value(), 4);

            // Keep part_b(1) for later
            transfer::public_transfer(part_b, depositor());

            // Redeem the combined 4
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::redeem_receipt(
                original,
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Assert: 4 items in owned inventory, 1 still in open, supply = 1
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), 4);
            assert_eq!(su.item_quantity(su.open_storage_key(), LENS_TYPE_ID), 1);
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 1);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        // Verify remaining receipt
        ts::next_tx(&mut ts, depositor());
        {
            let remaining = ts::take_from_sender<Balance>(&ts);
            assert_eq!(remaining.value(), 1);
            transfer::public_transfer(remaining, depositor());
        };

        ts::end(ts);
    }

    // === Batch Tests ===

    /// Test batch deposit of multiple item types and verify all receipts are returned.
    #[test]
    fun batch_deposit_multiple_types() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        // Mint both item types
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
        );

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Batch deposit both types
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, cap_receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let receipts = receipt::batch_deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                vector[LENS_TYPE_ID, AMMO_TYPE_ID],
                vector[LENS_QUANTITY, AMMO_QUANTITY],
                ts.ctx(),
            );

            // Verify we got 2 receipts
            assert_eq!(receipts.length(), 2);

            // Transfer all receipts to depositor
            let mut receipts = receipts;
            while (!receipts.is_empty()) {
                transfer::public_transfer(receipts.pop_back(), depositor());
            };
            receipts.destroy_empty();

            depositor_char.return_owner_cap(owner_cap, cap_receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Verify items moved to open inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(su.open_storage_key(), LENS_TYPE_ID), LENS_QUANTITY);
            assert_eq!(su.item_quantity(su.open_storage_key(), AMMO_TYPE_ID), AMMO_QUANTITY);
            assert!(!su.contains_item(depositor_owner_cap_id, LENS_TYPE_ID));
            assert!(!su.contains_item(depositor_owner_cap_id, AMMO_TYPE_ID));
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), LENS_QUANTITY as u64);
            assert_eq!(vault::total_supply(&collection, AMMO_TYPE_ID), AMMO_QUANTITY as u64);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        ts::end(ts);
    }

    /// Test batch redeem of multiple receipts in a single call.
    #[test]
    fun batch_redeem_multiple_receipts() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        // Mint both item types
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
        );

        // Batch deposit both types
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, cap_receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let receipts = receipt::batch_deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                vector[LENS_TYPE_ID, AMMO_TYPE_ID],
                vector[LENS_QUANTITY, AMMO_QUANTITY],
                ts.ctx(),
            );

            let mut receipts = receipts;
            while (!receipts.is_empty()) {
                transfer::public_transfer(receipts.pop_back(), depositor());
            };
            receipts.destroy_empty();

            depositor_char.return_owner_cap(owner_cap, cap_receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Batch redeem both receipts
        ts::next_tx(&mut ts, depositor());
        {
            let receipt_1 = ts::take_from_sender<Balance>(&ts);
            let receipt_2 = ts::take_from_sender<Balance>(&ts);

            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::batch_redeem_receipt(
                vector[receipt_1, receipt_2],
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Verify all items returned to owned inventory
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);
            assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
            assert!(!su.contains_item(su.open_storage_key(), AMMO_TYPE_ID));
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 0);
            assert_eq!(vault::total_supply(&collection, AMMO_TYPE_ID), 0);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        ts::end(ts);
    }

    /// Test full batch round-trip: batch deposit then batch redeem restores original state.
    #[test]
    fun batch_deposit_then_batch_redeem_round_trip() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );
        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
        );

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Batch deposit
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, cap_receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let receipts = receipt::batch_deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                vector[LENS_TYPE_ID, AMMO_TYPE_ID],
                vector[LENS_QUANTITY, AMMO_QUANTITY],
                ts.ctx(),
            );

            let mut receipts = receipts;
            while (!receipts.is_empty()) {
                transfer::public_transfer(receipts.pop_back(), depositor());
            };
            receipts.destroy_empty();

            depositor_char.return_owner_cap(owner_cap, cap_receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Batch redeem
        ts::next_tx(&mut ts, depositor());
        {
            let receipt_1 = ts::take_from_sender<Balance>(&ts);
            let receipt_2 = ts::take_from_sender<Balance>(&ts);

            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            receipt::batch_redeem_receipt(
                vector[receipt_1, receipt_2],
                &mut storage_unit,
                &depositor_char,
                &vault_config,
                &mut collection,
                ts.ctx(),
            );

            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Verify state fully restored
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let collection = ts::take_shared<Collection>(&ts);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
            assert_eq!(su.item_quantity(depositor_owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);
            assert!(!su.contains_item(su.open_storage_key(), LENS_TYPE_ID));
            assert!(!su.contains_item(su.open_storage_key(), AMMO_TYPE_ID));
            assert_eq!(vault::total_supply(&collection, LENS_TYPE_ID), 0);
            assert_eq!(vault::total_supply(&collection, AMMO_TYPE_ID), 0);
            ts::return_shared(su);
            ts::return_shared(collection);
        };

        ts::end(ts);
    }

    /// Test batch deposit with mismatched vector lengths aborts.
    #[test]
    #[
        expected_failure(
            abort_code = receipt::EBatchLengthMismatch,
            location = warehouse_receipts::receipt,
        ),
    ]
    fun batch_deposit_mismatched_lengths_aborts() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        ts::next_tx(&mut ts, depositor());
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
        let (owner_cap, _cap_receipt) = depositor_char.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
            ts.ctx(),
        );
        let vault_config = ts::take_shared<VaultConfig>(&ts);
        let mut collection = ts::take_shared<Collection>(&ts);

        // 2 type_ids but only 1 quantity — should abort
        let _receipts = receipt::batch_deposit_for_receipt(
            &mut storage_unit,
            &depositor_char,
            &owner_cap,
            &vault_config,
            &mut collection,
            vector[LENS_TYPE_ID, AMMO_TYPE_ID],
            vector[LENS_QUANTITY],
            ts.ctx(),
        );

        abort 0
    }

    /// Test batch deposit with a single item (degenerate case).
    #[test]
    fun batch_deposit_single_item() {
        let mut ts = ts::begin(governor());
        let (_owner_id, depositor_id, storage_id, _nwn_id) = setup_vault_scenario(&mut ts);

        mint_items_to_depositor(
            &mut ts,
            depositor_id,
            storage_id,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
        );

        let depositor_owner_cap_id = {
            ts::next_tx(&mut ts, admin());
            let c = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let id = c.owner_cap_id();
            ts::return_shared(c);
            id
        };

        // Batch deposit with single entry
        ts::next_tx(&mut ts, depositor());
        {
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            let mut depositor_char = ts::take_shared_by_id<Character>(&ts, depositor_id);
            let (owner_cap, cap_receipt) = depositor_char.borrow_owner_cap<Character>(
                ts::most_recent_receiving_ticket<OwnerCap<Character>>(&depositor_id),
                ts.ctx(),
            );
            let vault_config = ts::take_shared<VaultConfig>(&ts);
            let mut collection = ts::take_shared<Collection>(&ts);

            let receipts = receipt::batch_deposit_for_receipt(
                &mut storage_unit,
                &depositor_char,
                &owner_cap,
                &vault_config,
                &mut collection,
                vector[LENS_TYPE_ID],
                vector[LENS_QUANTITY],
                ts.ctx(),
            );

            assert_eq!(receipts.length(), 1);

            let mut receipts = receipts;
            transfer::public_transfer(receipts.pop_back(), depositor());
            receipts.destroy_empty();

            depositor_char.return_owner_cap(owner_cap, cap_receipt);
            ts::return_shared(depositor_char);
            ts::return_shared(storage_unit);
            ts::return_shared(vault_config);
            ts::return_shared(collection);
        };

        // Verify
        ts::next_tx(&mut ts, admin());
        {
            let su = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
            assert_eq!(su.item_quantity(su.open_storage_key(), LENS_TYPE_ID), LENS_QUANTITY);
            assert!(!su.contains_item(depositor_owner_cap_id, LENS_TYPE_ID));
            ts::return_shared(su);
        };

        ts::end(ts);
    }
}
