# warehouse-receipts × world-contracts v1 harness

Checks whether warehouse-receipts works with world-contracts `dev` without patching it, under this rule:
**a receipt is minted only by locking items in a contract-controlled Inventory, and burned only by freeing them, and the structure owner can't rug it.**

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
| world-contracts `dev` (core, power, inventory, …) | `$WC`, through its own `localnet-integration` skill (sui 1.78 image) |
| multicoin | `move/multicoin`: the sources are byte-identical to Algorithmic-Warfare/multicoin@2772c26. Only the manifest changed: it drops the explicit Sui git dependency. |
| warehouse_receipts (v1 port + TRIEX-160) | `move/warehouse_receipts_v1` |

`scripts/deploy.sh` test-publishes inside the pinned image, in a sibling container that shares `world-localnet`'s network. It uses a copy of world's pubfile, so world-contracts files are never written to.

## Design under test

- **`create_vault(registry, entity, AccessCap, inventory_id)`** takes the owner's cap by value and enables exactly two actions:
  - `wr_deposit = [Mint, Deposit(C)]`
  - `wr_redeem = [Redeem, Withdraw(C)]`

  It then sends the cap to the entity's own address. To borrow a parked cap you have to present the entity's current cap, which is that same parked cap, so the action set is frozen for good.
- **`Mint` and `Redeem`** are requirement types that only `warehouse_receipts::receipt` can satisfy. Each handler pops its marker and then does the inventory move itself, so the item amount and the receipt amount are tied together inside one Move call.
- **TRIEX-160:** the `VaultConfig` UID is claimed from `VaultRegistry` under a key derived from the entity ID. A second vault for the same entity aborts with `EVaultExists`, and `vault_address(entity_id)` lets anyone find the vault without an indexer.

## Results (world-contracts d87ebc1, 13/13 tests pass)

| | Claim | Result |
|---|---|---|
| ✅ | Mint only when items are locked; burn frees exactly the burned amount | holds |
| ✅ | The receipt is a bearer token (split, transfer, redeem by a third party) | holds |
| ✅ | After sealing, the owner can't add, disable or rewrite actions | holds |
| ✅ | You can't reach the withdraw or deposit behind the receipt actions without the handler | holds (`ERequirementNotComponentScoped`) |
| ✅ | A vault rejects another vault's receipts | holds |
| ✅ | One vault per entity (TRIEX-160), even when a new cap is minted | holds |
| ⚠️ | Owner actions created **before** `create_vault` survive the seal | **rug confirmed**: `warehouse_receipts` can't see the action map |
| ⚠️ | Nobody can refuel a sealed vault (`deposit_fuel` checks for the owner itself) | **receipts get stuck once fuel runs out** |
| ⚠️ | The only way to recover from running out of fuel is for the admin to revoke the cap and mint a new one | which un-seals the vault |
| ⚠️ | Admin `revoke_access` + `mint_access` gives full owner control back | admin trust |
| ⚠️ | An admin action with the same name shadows `wr_redeem` | **the admin can drain the vault** |
| ℹ️ | Redeeming needs a docking proof (or an admin/sponsor attestation) | remote settlement depends on the game server |

## What it would take to be plug and play

1. **Read access to actions** (`entity::action_names` or similar), so `create_vault` can check that the owner action map holds only `wr_*`. That closes the pre-seal backdoor on-chain.
2. **Refuelling without the owner**: let action config decide who can call `deposit_fuel`, instead of the handler always adding an owner check. Otherwise every sealed vault eventually becomes unredeemable.
3. **A real contract-controlled Airlock** (ADR-0003 TODO / Toniya's DAO-owned caps), or a way to freeze admin actions per entity. Until one of those exists, the game operator is a trusted party that can drain any vault.

The indexer can check whether a vault is sealed: the `AccessCap` owner is `AddressOwner(<entity id>)` and `entity.access_cap_id` equals that cap.
