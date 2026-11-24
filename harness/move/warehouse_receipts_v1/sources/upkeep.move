/// Upkeep for a sealed receipt vault: anyone can refuel it and switch it back on.
///
/// `create_vault` parks the vault entity's `AccessCap` on its `VaultConfig`.
/// Only this package can borrow it back (`vault::borrow_cap`, over
/// `access_cap::borrow_parked`), and only this module does. Each function runs
/// one game-defined power action on the vault entity, satisfies the owner check
/// that action's handler adds with the parked cap, and completes the request
/// before returning. The cap never leaves this module and can't authorize
/// anything but the handler called here.
///
/// Every function only adds fuel or switches something on, so none of them is
/// gated: they can only keep receipts redeemable. `refuel` still needs a game
/// sponsor on the transaction, like any `deposit_fuel`, because fuel is not yet
/// backed by an on-chain item.
///
/// `action` is the name the game gave the power action on this entity (e.g.
/// `deposit_fuel`, `set_power_grid`). Naming any other action aborts: its first
/// requirement isn't the one the handler pops, or its remaining requirements
/// are left unsatisfied when the request completes.
module warehouse_receipts::upkeep;

use core::{access_cap::AccessCap, admin_service::{Self, AdminACL}, entity::Entity, request::Request};
use power::{grid_fuel, grid_generator, grid_load, power_grid};
use std::string::String;
use sui::{clock::Clock, transfer::Receiving};
use variant::variant::Variant;
use warehouse_receipts::vault::VaultConfig;

// === Errors ===

#[error(code = 0)]
const EWrongEntity: vector<u8> = b"Vault is bound to a different entity";

// === Public Functions ===

/// Load `amount` of `fuel` into the vault's bay `fuel_bay_id`. The transaction's
/// gas sponsor (or sender) must be an `AdminACL` sponsor.
public fun refuel(
    config: &mut VaultConfig,
    entity: &mut Entity,
    acl: &AdminACL,
    cap: Receiving<AccessCap>,
    action: String,
    fuel_bay_id: u64,
    fuel: &Variant,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    grid_fuel::deposit_fuel(entity, &mut req, fuel_bay_id, fuel, amount, clock);
    as_owner(config, entity, &mut req, cap);
    admin_service::verify_sponsor(&mut req, acl, ctx);
    entity.complete_request(req);
}

/// Switch the vault's grid on. Running out of fuel trips the grid, and new fuel
/// alone doesn't bring it back, so this is the step after `refuel`.
public fun power_on(
    config: &mut VaultConfig,
    entity: &mut Entity,
    cap: Receiving<AccessCap>,
    action: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    power_grid::set_power_grid(entity, &mut req, true, clock);
    finish(config, entity, req, cap);
}

/// Bring a generator back online (e.g. after the game shut the grid down).
public fun generator_on(
    config: &mut VaultConfig,
    entity: &mut Entity,
    cap: Receiving<AccessCap>,
    action: String,
    generator_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    grid_generator::set_generator(entity, &mut req, generator_id, true, clock);
    finish(config, entity, req, cap);
}

/// Bring a fuel bay back online (e.g. after the game shut the grid down).
public fun fuel_bay_on(
    config: &mut VaultConfig,
    entity: &mut Entity,
    cap: Receiving<AccessCap>,
    action: String,
    fuel_bay_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    grid_fuel::set_fuel_bay(entity, &mut req, fuel_bay_id, true, clock);
    finish(config, entity, req, cap);
}

/// Ask for the vault's airlock to be powered. Only the airlock: switching other
/// modules on could overload the grid and trip it.
public fun airlock_on(
    config: &mut VaultConfig,
    entity: &mut Entity,
    cap: Receiving<AccessCap>,
    action: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    grid_load::set_desired_state(entity, &mut req, config.inventory_id(), true, clock);
    finish(config, entity, req, cap);
}

// === Private Functions ===

fun start(config: &VaultConfig, entity: &mut Entity, action: String, ctx: &mut TxContext): Request {
    assert!(config.entity_id() == entity.id(), EWrongEntity);
    entity.interact(action, ctx)
}

fun finish(config: &mut VaultConfig, entity: &mut Entity, mut req: Request, cap: Receiving<AccessCap>) {
    as_owner(config, entity, &mut req, cap);
    entity.complete_request(req);
}

/// Satisfy the owner requirement the handler just pushed, with the parked cap.
fun as_owner(config: &mut VaultConfig, entity: &Entity, req: &mut Request, ticket: Receiving<AccessCap>) {
    let (cap, receipt) = config.borrow_cap(ticket);
    entity.verify_owner(req, &cap);
    config.return_cap(cap, receipt);
}
