/// Warehouse receipts on a world-contracts v1 Inventory (the Airlock).
///
/// Minting a receipt locks items in the vault entity's Inventory, and burning a
/// receipt is the only way to free them:
///
/// - `create_vault` takes the entity's `AccessCap` by value, enables exactly two
///   owner actions, `wr_deposit = [Mint, Deposit(C)]` and
///   `wr_redeem = [Redeem, Withdraw(C)]`, then parks the cap on the entity itself.
///   A parked cap can only be borrowed by presenting the entity's current cap,
///   which is that same parked cap, so no owner can ever enable, disable, or
///   rewrite an action again. The action set is frozen.
/// - `Mint` and `Redeem` are requirement types only this module can satisfy
///   (it alone can mint their `Permit`). Each handler pops its marker and then
///   does the inventory move itself, so the receipt amount and the item amount
///   are bound inside one Move call. Nothing else can pop the marker, so the
///   Deposit/Withdraw behind it can't be reached on its own.
///
/// What this cannot stop (world-contracts `dev` exposes no way to check or
/// prevent it): owner actions that already existed before `create_vault`, and
/// the game admin (admin actions shadow owner actions; `inventory::uninstall`,
/// `migrate`, `revoke_access` + `mint_access`, `entity::delete`).
module warehouse_receipts::receipt;

use core::{
    access_cap::{Self, AccessCap},
    action,
    entity::Entity,
    request::Request,
    requirement::{Self, Requirement}
};
use inventory::{inventory::{Self, Inventory}, item::Item};
use multicoin::multicoin::{Balance, Collection};
use power::grid_load;
use std::{internal, string::{Self, String}};
use sui::{clock::Clock, event};
use warehouse_receipts::vault::{Self, VaultConfig, VaultRegistry};

// === Errors ===

#[error(code = 0)]
const ENotOwner: vector<u8> = b"AccessCap is not the entity's current cap";
#[error(code = 1)]
const ECapNotTransferable: vector<u8> = b"AccessCap must be transferable so it can be sealed";
#[error(code = 2)]
const ENoInventory: vector<u8> = b"Entity has no Inventory at this component id";
#[error(code = 3)]
const EWrongEntity: vector<u8> = b"Vault is bound to a different entity";

// === Constants ===

const DEPOSIT_ACTION: vector<u8> = b"wr_deposit";
const REDEEM_ACTION: vector<u8> = b"wr_redeem";

// === Structs ===

/// Requirement marker: a receipt must be minted for this deposit.
public struct Mint() has drop;

/// Requirement marker: a receipt must be burned for this withdrawal.
public struct Redeem() has drop;

/// A vault created by `create_vault` that the same transaction must share.
/// No abilities, so it can only be consumed by `share_vault`.
public struct PendingVault {
    config: VaultConfig,
    collection: Collection,
}

// === Events ===

public struct VaultInitializedEvent has copy, drop {
    entity_id: ID,
    inventory_id: u64,
    collection_id: ID,
    vault_config_id: ID,
}

public struct ReceiptMintedEvent has copy, drop {
    entity_id: ID,
    collection_id: ID,
    balance_id: ID,
    type_id: u64,
    quantity: u64,
    depositor: address,
}

public struct ReceiptRedeemedEvent has copy, drop {
    entity_id: ID,
    collection_id: ID,
    type_id: u64,
    quantity: u64,
    redeemer: address,
}

// === Public Functions ===

/// Turn `entity` into a receipt vault over its Inventory `inventory_id`, and seal
/// it. Consumes the owner's `AccessCap`: after this call nobody holds a usable
/// owner cap for `entity`. One vault per entity (TRIEX-160).
public fun create_vault(
    registry: &mut VaultRegistry,
    entity: &mut Entity,
    cap: AccessCap,
    inventory_id: u64,
    ctx: &mut TxContext,
): PendingVault {
    let entity_id = entity.id();
    assert!(
        cap.entity() == entity_id && entity.access_cap_id() == option::some(object::id(&cap)),
        ENotOwner,
    );
    assert!(cap.is_transferable(), ECapNotTransferable);
    assert!(entity.has_component_with_type<Inventory>(inventory_id), ENoInventory);

    let (config, collection) = vault::create(registry, entity_id, inventory_id, ctx);

    let deposit = action::new(vector[
        mint_requirement(),
        inventory::deposit_requirement(inventory_id, option::none(), option::none(), option::none()),
    ]);
    let mut req = entity.enable_action(deposit_action(), deposit, ctx);
    entity.verify_owner(&mut req, &cap);
    entity.complete_request(req);

    let redeem = action::new(vector[
        redeem_requirement(),
        inventory::withdraw_requirement(inventory_id, option::none(), option::none(), option::none()),
    ]);
    let mut req = entity.enable_action(redeem_action(), redeem, ctx);
    entity.verify_owner(&mut req, &cap);
    entity.complete_request(req);

    // Seal: park the cap on the entity it controls.
    access_cap::transfer_access(cap, entity_id.to_address());

    event::emit(VaultInitializedEvent {
        entity_id,
        inventory_id,
        collection_id: vault::collection_id(&config),
        vault_config_id: object::id(&config),
    });
    PendingVault { config, collection }
}

/// Share a pending vault's `Collection` and `VaultConfig`. The collection was
/// created in `create_vault` in this same transaction, so the share can't abort.
#[allow(lint(share_owned))]
public fun share_vault(self: PendingVault) {
    let PendingVault { config, collection } = self;
    transfer::public_share_object(collection);
    vault::share(config);
}

public fun pending_vault_config(self: &PendingVault): &VaultConfig { &self.config }

public fun pending_vault_collection(self: &PendingVault): &Collection { &self.collection }

/// Handler for `wr_deposit`: lock `item` in the vault Inventory and mint a
/// receipt for exactly its type and quantity. `req` comes from
/// `entity.interact("wr_deposit")`. The transaction must already hold a docking
/// proof linking the vault and `item`'s source.
public fun deposit_for_receipt(
    config: &VaultConfig,
    collection: &mut Collection,
    entity: &mut Entity,
    req: &mut Request,
    item: Item,
    clock: &Clock,
    ctx: &mut TxContext,
): Balance {
    assert!(config.entity_id() == entity.id(), EWrongEntity);
    let (_requirement, frame) = req.take_next(internal::permit<Mint>());
    frame.destroy_empty_frame();

    let type_id = item.type_id();
    let quantity = item.quantity();
    inventory::deposit(entity, req, item, ctx);
    grid_load::assert_online(entity, req, clock);

    let receipt = vault::mint(config, collection, type_id, quantity, ctx);
    event::emit(ReceiptMintedEvent {
        entity_id: entity.id(),
        collection_id: config.collection_id(),
        balance_id: object::id(&receipt),
        type_id,
        quantity,
        depositor: ctx.sender(),
    });
    receipt
}

/// Handler for `wr_redeem`: burn `receipt` and free exactly its type and
/// quantity from the vault Inventory as an `Item`. The caller must deposit the
/// `Item` somewhere in the same transaction (e.g. its docked ship).
public fun redeem(
    config: &VaultConfig,
    collection: &mut Collection,
    entity: &mut Entity,
    req: &mut Request,
    receipt: Balance,
    clock: &Clock,
    ctx: &mut TxContext,
): Item {
    assert!(config.entity_id() == entity.id(), EWrongEntity);
    let (_requirement, frame) = req.take_next(internal::permit<Redeem>());
    frame.destroy_empty_frame();

    let (type_id, quantity) = vault::burn(config, collection, receipt, ctx);
    let item = inventory::withdraw(entity, req, type_id, quantity, ctx);
    grid_load::assert_online(entity, req, clock);

    event::emit(ReceiptRedeemedEvent {
        entity_id: entity.id(),
        collection_id: config.collection_id(),
        type_id,
        quantity,
        redeemer: ctx.sender(),
    });
    item
}

// === View Functions ===

public fun mint_requirement(): Requirement {
    requirement::from_config(option::none(), Mint())
}

public fun redeem_requirement(): Requirement {
    requirement::from_config(option::none(), Redeem())
}

public fun deposit_action(): String { string::utf8(DEPOSIT_ACTION) }

public fun redeem_action(): String { string::utf8(REDEEM_ACTION) }
