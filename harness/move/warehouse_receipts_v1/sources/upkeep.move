/// Upkeep for a sealed receipt vault: anyone can refuel it and switch it back on.
///
/// `create_vault` hands the vault entity to `vault::VaultController`, so no
/// `AccessCap` exists for it. This module is the only code that acts as that
/// controller. Each function runs one game-defined power action on the vault
/// entity, satisfies the owner check that action's handler adds with
/// `entity::verify_controller`, and completes the request before returning, so
/// the controller's authority covers nothing but the handler called here.
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

use core::{admin_service::{Self, AdminACL}, entity::Entity, request::Request};
use power::{grid_fuel, grid_generator, grid_load, power_grid};
use std::string::String;
use sui::clock::Clock;
use variant::variant::Variant;
use warehouse_receipts::vault::{Self, VaultConfig};

// === Errors ===

#[error(code = 0)]
const EWrongEntity: vector<u8> = b"Vault is bound to a different entity";

// === Public Functions ===

/// Load `amount` of `fuel` into the vault's bay `fuel_bay_id`. The transaction's
/// gas sponsor (or sender) must be an `AdminACL` sponsor.
public fun refuel(
    config: &VaultConfig,
    entity: &mut Entity,
    acl: &AdminACL,
    action: String,
    fuel_bay_id: u64,
    fuel: &Variant,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    grid_fuel::deposit_fuel(entity, &mut req, fuel_bay_id, fuel, amount, clock);
    as_controller(entity, &mut req);
    admin_service::verify_sponsor(&mut req, acl, ctx);
    entity.complete_request(req);
}

/// Switch the vault's grid on. Running out of fuel trips the grid, and new fuel
/// alone doesn't bring it back, so this is the step after `refuel`.
public fun power_on(
    config: &VaultConfig,
    entity: &mut Entity,
    action: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    power_grid::set_power_grid(entity, &mut req, true, clock);
    finish(entity, req);
}

/// Bring a generator back online (e.g. after the game shut the grid down).
public fun generator_on(
    config: &VaultConfig,
    entity: &mut Entity,
    action: String,
    generator_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    grid_generator::set_generator(entity, &mut req, generator_id, true, clock);
    finish(entity, req);
}

/// Bring a fuel bay back online (e.g. after the game shut the grid down).
public fun fuel_bay_on(
    config: &VaultConfig,
    entity: &mut Entity,
    action: String,
    fuel_bay_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    grid_fuel::set_fuel_bay(entity, &mut req, fuel_bay_id, true, clock);
    finish(entity, req);
}

/// Ask for the vault's airlock to be powered. Only the airlock: switching other
/// modules on could overload the grid and trip it.
public fun airlock_on(
    config: &VaultConfig,
    entity: &mut Entity,
    action: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut req = start(config, entity, action, ctx);
    grid_load::set_desired_state(entity, &mut req, config.inventory_id(), true, clock);
    finish(entity, req);
}

// === Private Functions ===

fun start(config: &VaultConfig, entity: &mut Entity, action: String, ctx: &mut TxContext): Request {
    assert!(config.entity_id() == entity.id(), EWrongEntity);
    entity.interact(action, ctx)
}

fun finish(entity: &mut Entity, mut req: Request) {
    as_controller(entity, &mut req);
    entity.complete_request(req);
}

/// Satisfy the owner requirement the handler just pushed, as the vault's controller.
fun as_controller(entity: &Entity, req: &mut Request) {
    entity.verify_controller(req, vault::control_permit());
}
