# warehouse-receipts × world-contracts v1 harness

Checks whether warehouse-receipts works on world-contracts `dev` under this rule:
**a receipt is minted only by locking items in a contract-controlled Inventory, and burned only by freeing them, and the structure owner can't rug it.**

This branch needs one addition to world-contracts: entity **controllers** (`entity::hand_over_control` /
`entity::verify_controller`), on branch `feat/entity-controller` (dev @ b4fd826 + one commit). Check that branch out
in `$WC` before building. No `AccessCap` is sent, parked or borrowed anywhere, and no admin step is involved.

```bash
./run.sh            # start the localnet if it isn't running, deploy, run the suite
./run.sh --fresh    # restart from genesis and redeploy everything
./run.sh --down     # stop the localnet
```

Needs Docker, `jq`, and the world-contracts checkout at `../../../world-contracts` (override with `WC=`).
The results go to `out/report.json`.

## What gets deployed

| Package | Source |
|---|---|
| world-contracts `feat/entity-controller` (core, power, inventory, variant, …) | `$WC`, through its own `localnet-integration` skill (sui 1.78 image) |
| multicoin | `move/multicoin`: the sources are byte-identical to Algorithmic-Warfare/multicoin@2772c26. Only the manifest changed: it drops the explicit Sui git dependency. |
| warehouse_receipts (v1 port + TRIEX-160) | `move/warehouse_receipts_v1` |

`scripts/deploy.sh` test-publishes inside the pinned image, in a sibling container that shares `world-localnet`'s network. It uses a copy of world's pubfile, so world-contracts files are never written to.

## Design under test

- **`create_vault(registry, entity, AccessCap, inventory_id)`** takes the owner's cap by value, aborts with `EOwnerActionsExist` if the entity already has owner actions, and enables exactly two:
  - `wr_deposit = [Mint, Deposit(C)]`
  - `wr_redeem = [Redeem, Withdraw(C)]`

  It then calls `entity::hand_over_control(cap, Permit<VaultController>)`. The cap is **destroyed**, and the entity records `warehouse_receipts::vault::VaultController` as its owner. Only this package can mint that `Permit`, so only it can satisfy owner checks on the vault (`entity::verify_controller`). No owner can ever enable, disable or rewrite an action again, because there is no cap left.
- **`upkeep`** is the only code that acts as the controller. Each function runs one game-defined power action on the vault, satisfies the owner check that action's handler adds, and completes the request before returning the cap. All of them only add fuel or switch something on, so none is gated:
  - `refuel` (`deposit_fuel`; needs a game sponsor, like any fuel deposit, until fuel is backed by an on-chain item)
  - `power_on` (`set_power_grid(true)`: running dry trips the grid, and fuel alone doesn't bring it back)
  - `generator_on`, `fuel_bay_on`, `airlock_on` (for recovery after the game's `shut_down`; `airlock_on` only touches the vault's own Inventory, so nobody can overload the grid)

  There's no cap to receive, so a stranger can refuel and power on in one transaction.
- **`Mint` and `Redeem`** are requirement types that only `warehouse_receipts::receipt` can satisfy. Each handler pops its marker and then does the inventory move itself, so the item amount and the receipt amount are tied together inside one Move call.
- **Receipt asset ids:** items are keyed by `VariantKey` (tenant, type, variant). A receipt's multicoin `asset_id` is the first 8 bytes (LE) of `blake2b256(bcs(key))`, and `VaultConfig` keeps the reverse map for redeem.
- **TRIEX-160:** the `VaultConfig` UID is claimed from `VaultRegistry` under a key derived from the entity ID. A second vault for the same entity aborts with `EVaultExists`, and `vault_address(entity_id)` lets anyone find the vault without an indexer.

## Results (world-contracts 284f270 = dev b4fd826 + entity controllers, 16/16 tests pass)

| | Claim | Result |
|---|---|---|
| ✅ | Mint only when items are locked; burn frees exactly the burned amount | holds |
| ✅ | The receipt is a bearer token (split, transfer, redeem by a third party) | holds |
| ✅ | Sealing destroys the cap; `VaultController` becomes the owner | holds (`access_cap_id` is none, `controller()` is `VaultController`) |
| ✅ | After sealing, the owner can't add, disable or rewrite actions | holds (their cap no longer exists) |
| ✅ | You can't reach the withdraw or deposit behind the receipt actions without the handler | holds (`ERequirementNotComponentScoped`) |
| ✅ | An owner who planted an action before sealing can't seal | holds (`EOwnerActionsExist`); this was a confirmed rug before |
| ✅ | A vault rejects another vault's receipts | holds (`EWrongCollection`) |
| ✅ | One vault per entity (TRIEX-160), even when a new cap is minted | holds (`EVaultExists`) |
| ✅ | **After a sealed vault runs dry, anyone can refuel it and switch it back on, and receipts redeem again** | holds: redeem aborts with `EOutOfFuel`; a stranger runs `upkeep::refuel` + `upkeep::power_on` in one game-sponsored transaction; the holder redeems 3/3; the vault is still controller-owned with no cap. Before, receipts were stuck for good. |
| ✅ | The controller only satisfies the power handler `upkeep` itself runs | holds: pointing `power_on` at `wr_redeem` aborts |
| ℹ️ | `upkeep::refuel` needs a game sponsor | `EUnauthorizedSponsor` without one, as for any `deposit_fuel` |
| ℹ️ | Redeeming needs the ship docked at the vault (admin-recorded state) | `EWrongSource` otherwise; remote settlement depends on the game server |
| ⚠️ | Admin `revoke_access` + `mint_access` clears the controller and gives full owner control back | admin trust |
| ⚠️ | An admin action with the same name shadows `wr_redeem` | **the admin can drain the vault** |

## Trust that remains

1. **The game admin**, as before: re-minting the cap, shadowing `wr_redeem`, `inventory::uninstall`, `entity::delete`. Closing this needs a way to freeze admin actions per entity.
2. **Whoever can upgrade `warehouse_receipts`.** An upgrade can add code that mints `Permit<VaultController>` and acts as the vault's owner (the controller is recorded by original package id, so it survives upgrades). Publish the package immutable, or put the `UpgradeCap` behind a policy holders can rely on.
3. **The game sponsor for fuel**, until fuel deposits are backed by an on-chain item.

The indexer can check whether a vault is sealed: `entity::controller` is `<warehouse_receipts>::vault::VaultController` and `entity::access_cap_id` is none. `ControlHandedOver` / `ControlCleared` events mark the transitions.
