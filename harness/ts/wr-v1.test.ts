/**
 * warehouse-receipts on world-contracts v1 (dev): can receipts be minted and burned
 * only by locking and freeing items in a contract-controlled Inventory that the
 * structure owner can't rug?
 *
 * Every `it` is one claim. "EXPECT-FAIL" claims pass when the attack aborts.
 * "RISK" claims pass when the attack SUCCEEDS: they show a gap the design can't
 * close on dev. Findings are written to harness/out/report.json.
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { bcs } from '@mysten/sui/bcs'
import type { Signer } from '@mysten/sui/cryptography'
import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type { ExecutedTransaction } from '../../../../world-contracts/sdk/world-sdk/src/client.js'
import {
  addSponsors,
  completeRequest,
  deriveObjectId,
  dock,
  enableAction,
  enableAdminAction,
  entityNew,
  interact,
  mintAccess,
  ownerRequirement,
  revokeAccess,
  shareEntity,
  undock,
  verifyAdmin,
  verifyOwner,
} from '../../../../world-contracts/sdk/world-sdk/src/packages/core.js'
import {
  bridgeInRequirement,
  deposit,
  depositRequirement,
  gameItemToChain,
  installInventory,
  withdraw,
  withdrawRequirement,
} from '../../../../world-contracts/sdk/world-sdk/src/packages/inventory.js'
import {
  depositFuel,
  depositFuelRequirement,
  installFuelBay,
  installGenerator,
  installPowerGrid,
  operateGridRequirement,
  POWER_SCALE,
  projectedFuel,
  setDesiredState,
  setFuelBay,
  setGenerator,
  setPowerGrid,
} from '../../../../world-contracts/sdk/world-sdk/src/packages/power.js'
import { MASS_UNIT } from '../../../../world-contracts/sdk/world-sdk/src/packages/variant.js'
import {
  capObjectId,
  expectSponsored,
  expectSuccess,
  fuelVariant,
  genesisAccount,
  itemVariant,
  loadLocalnetWorld,
  readBalance,
  requirePackage,
  seatShell,
  signer as adminAddr,
} from '../../../../world-contracts/sdk/world-sdk/src/__integration__/helpers.js'

// ── harness manifest ───────────────────────────────────────────────────────
const OUT = fileURLToPath(new URL('../out/', import.meta.url))
const wr = JSON.parse(readFileSync(`${OUT}wr.localnet.json`, 'utf8')) as {
  multicoin: string
  warehouseReceipts: string
  vaultRegistry: string
  worldContractsRev: string
}
const WR = wr.warehouseReceipts

// ── fixture constants ──────────────────────────────────────────────────────
const TENANT = `wr-harness-${Date.now()}`
const INV = 0x51n
const GEN = 0x52n
const BAY = 0x53n
const ORE = 88834n
const ORE_KEY = { tenant: TENANT, typeId: ORE, variantId: 0n }
const VOL = 1n
// 20 MW generator, 10 MW firm airlock. Impulse-10 fuel at a 10 MW draw burns
// about 1 kg a second.
const OUTPUT = 20n
const INV_DRAW = 10n
const FUEL_TYPE = 7n
const FUEL_IMPULSE = 10n * POWER_SCALE
const FUEL_CAPACITY = 1_000_000n * POWER_SCALE
const LONG_FUEL = 100_000n // kg, ~28h
const SHORT_FUEL = 25n // kg, ~25s

type Finding = { claim: string; kind: 'guarantee' | 'risk' | 'flow'; result: string; detail?: string }
const findings: Finding[] = []
const record = (f: Finding) => findings.push(f)

describe('warehouse-receipts on world-contracts dev (localnet)', () => {
  const { config, client } = loadLocalnetWorld()
  const coreId = requirePackage(config, 'core')
  const variantId = requirePackage(config, 'variant')

  const A = genesisAccount('PLAYER_A') // structure owner
  const B = genesisAccount('PLAYER_B') // depositor
  const C = genesisAccount('PLAYER_C') // receipt buyer / attacker

  const id = (n: bigint) => deriveObjectId(config, { id: n, tenant: TENANT })
  const V = id(1n) // the vault
  const VB = id(2n) // vault whose owner left a backdoor action before sealing
  const VS = id(3n) // vault with ~25s of fuel
  const VT = id(4n) // TRIEX-160 target
  const SHIP_B = id(10n)
  const SHIP_C = id(11n)

  const caps: Record<string, string> = {}
  const vaults: Record<string, { config: string; collection: string }> = {}
  let receiptB = '' // B's receipt from V
  let fuel = '' // fuel Variant id
  let ore = '' // ORE item Variant id

  // ── helpers ──────────────────────────────────────────────────────────────
  function created(res: ExecutedTransaction, suffix: string): string {
    const hit = res.effects.changedObjects.find(
      (o) => o.idOperation === 'Created' && (res.objectTypes[o.objectId] ?? '').endsWith(suffix),
    )
    if (!hit) throw new Error(`no created object of type *${suffix}`)
    return hit.objectId
  }

  /** Simulate as `sender`; pass if it fails (abort or build error), returning the message. */
  async function expectFails(tx: Transaction, sender: string, re?: RegExp): Promise<string> {
    tx.setSender(sender)
    let msg: string
    try {
      const res = await client.simulateTransaction({ transaction: tx })
      if (!res.FailedTransaction) throw new Error('UNEXPECTED_SUCCESS')
      msg = res.FailedTransaction.status.error?.message ?? 'failed (no message)'
    } catch (e) {
      const m = (e as Error).message
      if (m === 'UNEXPECTED_SUCCESS') throw new Error('expected the transaction to fail, but it succeeded')
      msg = m
    }
    if (re) expect(msg).toMatch(re)
    return msg
  }

  async function view(build: (tx: Transaction) => void): Promise<Uint8Array> {
    const tx = new Transaction()
    tx.setSender(adminAddr)
    build(tx)
    const res = await client.simulateTransaction({ transaction: tx, include: { commandResults: true } })
    if (res.FailedTransaction) throw new Error(res.FailedTransaction.status.error?.message ?? 'view failed')
    const rv = res.commandResults.at(-1)?.returnValues[0]
    if (!rv) throw new Error('view returned nothing')
    return rv.bcs
  }

  /** Outstanding ORE receipts of vault `v` (asset id derived from ORE's VariantKey). */
  const supply = async (v: string) =>
    BigInt(
      bcs.u64().parse(
        await view((tx) => {
          const key = tx.moveCall({
            target: `${variantId}::variant::new_key`,
            arguments: [tx.pure.string(ORE_KEY.tenant), tx.pure.u64(ORE_KEY.typeId), tx.pure.u64(ORE_KEY.variantId)],
          })
          const asset = tx.moveCall({ target: `${WR}::vault::asset_id`, arguments: [key] })
          tx.moveCall({
            target: `${WR}::vault::total_supply`,
            arguments: [tx.object(vaults[v].collection), asset],
          })
        }),
      ),
    )
  const bal = (entity: string) => readBalance(client, config, { entity, componentId: INV, key: ORE_KEY })
  const fuelOf = async (entity: string) =>
    BigInt(bcs.u64().parse(await view((tx) => projectedFuel(tx, config, tx.object(entity)))))

  async function ownerOf(objectId: string): Promise<string> {
    const { object } = await client.getObject({ objectId })
    return JSON.stringify(object.owner)
  }

  /** Admin: claim a creation with a Shell, grid, generator, fuel bay and an Inventory. */
  function buildCreation(tx: Transaction, inGameId: bigint, inventoryType: bigint) {
    const [e, claim] = entityNew(tx, config, { inGameId, tenant: TENANT })
    verifyAdmin(tx, config, claim)
    completeRequest(tx, config, e, claim)
    installPowerGrid(tx, config, e)
    seatShell(tx, config, e)
    installGenerator(tx, config, e, {
      componentId: GEN,
      name: 'generator',
      maxOutputMw: OUTPUT,
      fuelType: FUEL_TYPE,
      impulseLimit: 100n * POWER_SCALE,
      volatilityLimit: 1n,
    })
    installFuelBay(tx, config, e, { componentId: BAY, name: 'fuel bay', capacity: FUEL_CAPACITY })
    installInventory(tx, config, e, {
      componentId: INV,
      typeId: inventoryType,
      name: 'airlock',
      capacity: 100_000n,
      power: { powerReq: INV_DRAW, drawKind: 'firm' },
    })
    shareEntity(tx, config, e)
  }

  /** Admin: the game-defined power actions every creation gets. */
  function enablePowerActions(tx: Transaction, entityId: string) {
    const e = tx.object(entityId)
    for (const name of ['set_power_grid', 'set_generator', 'set_fuel_bay', 'set_desired_state'])
      enableAdminAction(tx, config, e, name, [operateGridRequirement(tx, config)])
    enableAdminAction(tx, config, e, 'deposit_fuel', [depositFuelRequirement(tx, config)])
  }

  function refuel(tx: Transaction, entityId: string, cap: string, kg: bigint) {
    const e = tx.object(entityId)
    const r = interact(tx, config, e, 'deposit_fuel')
    depositFuel(tx, config, e, r, cap, { fuelBayId: BAY, variant: fuel, amount: kg * MASS_UNIT })
    completeRequest(tx, config, e, r)
  }

  function switchGridOn(tx: Transaction, entityId: string, cap: string) {
    const e = tx.object(entityId)
    const r = interact(tx, config, e, 'set_power_grid')
    setPowerGrid(tx, config, e, r, cap, true)
    completeRequest(tx, config, e, r)
  }

  /** Owner (sponsored): fuel, bay online, grid on, generator on, airlock desired online. */
  async function powerOn(owner: Signer, entityId: string, cap: string, kg: bigint) {
    const tx = new Transaction()
    const e = tx.object(entityId)
    refuel(tx, entityId, cap, kg)
    let r = interact(tx, config, e, 'set_fuel_bay')
    setFuelBay(tx, config, e, r, cap, BAY, true)
    completeRequest(tx, config, e, r)
    switchGridOn(tx, entityId, cap)
    r = interact(tx, config, e, 'set_generator')
    setGenerator(tx, config, e, r, cap, GEN, true)
    completeRequest(tx, config, e, r)
    r = interact(tx, config, e, 'set_desired_state')
    setDesiredState(tx, config, e, r, cap, INV, true)
    completeRequest(tx, config, e, r)
    await expectSponsored(client, tx, owner)
  }

  /** Ship owner: owner-only withdraw / deposit / bridge_in on the ship's airlock. */
  async function enableShipActions(owner: Signer, shipId: string, cap: string) {
    const tx = new Transaction()
    const e = tx.object(shipId)
    enableAction(tx, config, e, 'withdraw', [ownerRequirement(tx, config), withdrawRequirement(tx, config, INV, {})], cap)
    enableAction(tx, config, e, 'deposit', [ownerRequirement(tx, config), depositRequirement(tx, config, INV, {})], cap)
    enableAction(tx, config, e, 'bridge_in', [ownerRequirement(tx, config), bridgeInRequirement(tx, config, INV, {})], cap)
    await expectSuccess(client, tx, owner)
  }

  /** Ship owner withdraws `qty` ORE from their docked ship. Returns the Item. */
  function unloadShip(tx: Transaction, shipId: string, cap: string, qty: bigint): TransactionArgument {
    const ship = tx.object(shipId)
    const r = interact(tx, config, ship, 'withdraw')
    verifyOwner(tx, config, ship, r, cap)
    const item = withdraw(tx, config, ship, r, { key: ORE_KEY, quantity: qty })
    completeRequest(tx, config, ship, r)
    return item
  }

  function loadShip(tx: Transaction, shipId: string, cap: string, item: TransactionArgument) {
    const ship = tx.object(shipId)
    const r = interact(tx, config, ship, 'deposit')
    verifyOwner(tx, config, ship, r, cap)
    deposit(tx, config, ship, r, item)
    completeRequest(tx, config, ship, r)
  }

  function createVault(tx: Transaction, entityId: string, cap: string) {
    const pending = tx.moveCall({
      target: `${WR}::receipt::create_vault`,
      arguments: [tx.object(wr.vaultRegistry), tx.object(entityId), tx.object(cap), tx.pure.u64(INV)],
    })
    tx.moveCall({ target: `${WR}::receipt::share_vault`, arguments: [pending] })
  }

  function depositForReceipt(tx: Transaction, v: string, item: TransactionArgument): TransactionArgument {
    const e = tx.object(v)
    const r = interact(tx, config, e, 'wr_deposit')
    const receipt = tx.moveCall({
      target: `${WR}::receipt::deposit_for_receipt`,
      arguments: [tx.object(vaults[v].config), tx.object(vaults[v].collection), e, r, item, tx.object.clock()],
    })
    completeRequest(tx, config, e, r)
    return receipt
  }

  function redeem(tx: Transaction, v: string, receipt: TransactionArgument): TransactionArgument {
    const e = tx.object(v)
    const r = interact(tx, config, e, 'wr_redeem')
    const item = tx.moveCall({
      target: `${WR}::receipt::redeem`,
      arguments: [tx.object(vaults[v].config), tx.object(vaults[v].collection), e, r, receipt, tx.object.clock()],
    })
    completeRequest(tx, config, e, r)
    return item
  }

  async function mintCap(entity: string, owner: string): Promise<string> {
    const tx = new Transaction()
    mintAccess(tx, config, { entity, owner, transferable: true })
    return capObjectId(await expectSuccess(client, tx), coreId)
  }

  async function sealVault(owner: Signer, v: string, cap: string) {
    const tx = new Transaction()
    createVault(tx, v, cap)
    const res = await expectSuccess(client, tx, owner)
    vaults[v] = { config: created(res, '::vault::VaultConfig'), collection: created(res, '::multicoin::Collection') }
  }

  /** B deposits `qty` ORE from SHIP_B into vault `v`; returns B's receipt id. */
  async function depositFromB(v: string, qty: bigint): Promise<string> {
    const tx = new Transaction()
    const receipt = depositForReceipt(tx, v, unloadShip(tx, SHIP_B, caps.SHIP_B, qty))
    tx.transferObjects([receipt], B.toSuiAddress())
    return created(await expectSuccess(client, tx, B), '::multicoin::Balance')
  }

  // ── setup: the game builds the structures ──────────────────────────────────
  beforeAll(async () => {
    const sponsorTx = new Transaction()
    addSponsors(sponsorTx, config, [adminAddr])
    await expectSuccess(client, sponsorTx)

    fuel = await fuelVariant(client, config, {
      tenant: TENANT,
      fuelType: FUEL_TYPE,
      impulse: FUEL_IMPULSE,
      containmentBurden: 0n,
      volatility: 1n * POWER_SCALE,
    })
    ore = await itemVariant(client, config, { tenant: TENANT, typeId: ORE, unitVolume: VOL })

    const build = new Transaction()
    buildCreation(build, 1n, 1n)
    buildCreation(build, 2n, 1n)
    buildCreation(build, 3n, 1n)
    buildCreation(build, 4n, 1n)
    buildCreation(build, 10n, 2n)
    buildCreation(build, 11n, 2n)
    await expectSuccess(client, build)

    const actions = new Transaction()
    for (const e of [V, VB, VS, VT, SHIP_B, SHIP_C]) enablePowerActions(actions, e)
    await expectSuccess(client, actions)

    // Both ships are docked at every vault (docking is admin-recorded state).
    const docking = new Transaction()
    for (const v of [V, VB, VS, VT])
      for (const ship of [SHIP_B, SHIP_C]) dock(docking, config, docking.object(v), docking.object(ship))
    await expectSuccess(client, docking)

    for (const [k, e, o] of [
      ['V', V, A], ['VB', VB, A], ['VS', VS, A], ['VT', VT, A], ['SHIP_B', SHIP_B, B], ['SHIP_C', SHIP_C, C],
    ] as const)
      caps[k] = await mintCap(e, o.toSuiAddress())

    for (const [e, o, cap, kg] of [
      [V, A, caps.V, LONG_FUEL], [VB, A, caps.VB, LONG_FUEL], [VT, A, caps.VT, LONG_FUEL],
      [SHIP_B, B, caps.SHIP_B, LONG_FUEL], [SHIP_C, C, caps.SHIP_C, LONG_FUEL],
    ] as const)
      await powerOn(o, e, cap, kg)

    await enableShipActions(B, SHIP_B, caps.SHIP_B)
    await enableShipActions(C, SHIP_C, caps.SHIP_C)

    // B brings 100 ORE from the game onto their ship (server-sponsored bridge).
    const bridge = new Transaction()
    const ship = bridge.object(SHIP_B)
    const r = interact(bridge, config, ship, 'bridge_in')
    verifyOwner(bridge, config, ship, r, caps.SHIP_B)
    gameItemToChain(bridge, config, ship, r, { variant: ore, quantity: 100n })
    completeRequest(bridge, config, ship, r)
    await expectSponsored(client, bridge, B)
    expect(await bal(SHIP_B)).toBe(100n)
  }, 300_000)

  afterAll(() => {
    writeFileSync(
      `${OUT}report.json`,
      JSON.stringify({ worldContractsRev: wr.worldContractsRev, tenant: TENANT, packages: wr, findings }, null, 2),
    )
  })

  // ── 1. vault creation + seal + TRIEX-160 ────────────────────────────────────
  it('owner turns their storage unit into a sealed vault; its key ends up parked on the entity', async () => {
    await sealVault(A, V, caps.V)
    const owner = await ownerOf(caps.V)
    expect(owner.toLowerCase()).toContain(V.slice(2).toLowerCase())

    const addr = bcs.Address.parse(
      await view((tx) =>
        tx.moveCall({
          target: `${WR}::vault::vault_address`,
          arguments: [tx.object(wr.vaultRegistry), tx.pure.id(V)],
        }),
      ),
    )
    expect(addr).toBe(vaults[V].config)
    record({ claim: 'create_vault seals the entity (AccessCap object-owned by the entity itself)', kind: 'guarantee', result: 'PASS', detail: `cap owner ${owner}` })
    record({ claim: 'VaultConfig id is derivable from entity id (TRIEX-160 derived object)', kind: 'guarantee', result: 'PASS' })
  })

  it('TRIEX-160: a second vault for the same entity aborts, even with a freshly minted cap', async () => {
    await sealVault(A, VT, caps.VT)
    // The old bug: any further authorized cap could mint another collection.
    const revoke = new Transaction()
    revokeAccess(revoke, config, VT)
    await expectSuccess(client, revoke)
    const fresh = await mintCap(VT, A.toSuiAddress())
    caps.VT2 = fresh
    const tx = new Transaction()
    createVault(tx, VT, fresh)
    const msg = await expectFails(tx, A.toSuiAddress(), /EVaultExists/)
    record({ claim: 'one vault/collection per entity (TRIEX-160)', kind: 'guarantee', result: 'PASS', detail: msg })
  })

  // ── 2. happy path ─────────────────────────────────────────────────────────
  it('depositor locks 10 ORE from their docked ship and receives a 10-ORE receipt', async () => {
    receiptB = await depositFromB(V, 10n)
    expect(await bal(V)).toBe(10n)
    expect(await bal(SHIP_B)).toBe(90n)
    expect(await supply(V)).toBe(10n)
    record({ claim: 'mint is tied to locking items in the vault Inventory', kind: 'flow', result: 'PASS', detail: 'vault 10, supply 10' })
  })

  it('receipt is a bearer token: B sends 4 to C, C redeems 4 ORE into their own docked ship', async () => {
    const split = new Transaction()
    const part = split.moveCall({
      target: `${wr.multicoin}::multicoin::split`,
      arguments: [split.object(receiptB), split.pure.u64(4n)],
    })
    split.transferObjects([part], C.toSuiAddress())
    const res = await expectSuccess(client, split, B)
    const receiptC = created(res, '::multicoin::Balance')

    const tx = new Transaction()
    const item = redeem(tx, V, tx.object(receiptC))
    loadShip(tx, SHIP_C, caps.SHIP_C, item)
    await expectSuccess(client, tx, C)
    expect(await bal(V)).toBe(6n)
    expect(await bal(SHIP_C)).toBe(4n)
    expect(await supply(V)).toBe(6n)
    record({ claim: 'burn is tied to freeing exactly the burned amount', kind: 'flow', result: 'PASS', detail: 'vault 6, supply 6, C ship 4' })
  })

  // ── 3. owner / third-party bypass attempts (all must fail) ──────────────────
  it('EXPECT-FAIL: the former owner cannot add a "steal" action (cap is parked)', async () => {
    const tx = new Transaction()
    const e = tx.object(V)
    enableAction(tx, config, e, 'steal', [withdrawRequirement(tx, config, INV, {})], caps.V)
    const msg = await expectFails(tx, A.toSuiAddress())
    record({ claim: 'owner cannot enable new actions after seal', kind: 'guarantee', result: 'PASS', detail: msg.slice(0, 200) })
  })

  it('EXPECT-FAIL: the former owner cannot disable wr_redeem to freeze redemptions', async () => {
    const tx = new Transaction()
    const e = tx.object(V)
    const r = tx.moveCall({ target: `${coreId}::entity::disable_action`, arguments: [e, tx.pure.string('wr_redeem')] })
    verifyOwner(tx, config, e, r, caps.V)
    completeRequest(tx, config, e, r)
    const msg = await expectFails(tx, A.toSuiAddress())
    record({ claim: 'owner cannot disable or rewrite receipt actions after seal', kind: 'guarantee', result: 'PASS', detail: msg.slice(0, 200) })
  })

  it('EXPECT-FAIL: anyone calling wr_redeem but withdrawing directly (skipping the burn) aborts', async () => {
    const tx = new Transaction()
    const e = tx.object(V)
    const r = interact(tx, config, e, 'wr_redeem')
    const item = withdraw(tx, config, e, r, { key: ORE_KEY, quantity: 6n })
    completeRequest(tx, config, e, r)
    loadShip(tx, SHIP_C, caps.SHIP_C, item)
    const msg = await expectFails(tx, C.toSuiAddress(), /ERequirementNotComponentScoped|EWrongRequirementType/)
    record({ claim: 'withdraw behind wr_redeem is unreachable without burning a receipt', kind: 'guarantee', result: 'PASS', detail: msg.slice(0, 200) })
  })

  it('EXPECT-FAIL: anyone calling wr_deposit but depositing directly (to dodge or fake a mint) aborts', async () => {
    const tx = new Transaction()
    const item = unloadShip(tx, SHIP_B, caps.SHIP_B, 1n)
    const e = tx.object(V)
    const r = interact(tx, config, e, 'wr_deposit')
    deposit(tx, config, e, r, item)
    completeRequest(tx, config, e, r)
    const msg = await expectFails(tx, B.toSuiAddress(), /ERequirementNotComponentScoped|EWrongRequirementType/)
    record({ claim: 'deposit behind wr_deposit only runs through the minting handler', kind: 'guarantee', result: 'PASS', detail: msg.slice(0, 200) })
  })

  it('EXPECT-FAIL: redeeming into a ship that is not docked at the vault aborts (physics still applies)', async () => {
    const off = new Transaction()
    undock(off, config, off.object(V), off.object(SHIP_B))
    await expectSuccess(client, off)

    const tx = new Transaction()
    loadShip(tx, SHIP_B, caps.SHIP_B, redeem(tx, V, tx.object(receiptB)))
    const msg = await expectFails(tx, B.toSuiAddress(), /ENotDocked|EWrongSource/)

    const on = new Transaction()
    dock(on, config, on.object(V), on.object(SHIP_B))
    await expectSuccess(client, on)
    record({ claim: 'redemption requires the ship to be docked at the vault (admin-recorded state)', kind: 'flow', result: 'PASS', detail: msg.slice(0, 160) })
  })

  // ── 4. residual risks the design cannot close on dev ────────────────────────
  it('RISK: an owner action created BEFORE sealing survives the seal and drains receipt-backed items', async () => {
    // Owner A plants a public withdraw action on VB, then seals it as a vault.
    const plant = new Transaction()
    enableAction(plant, config, plant.object(VB), 'backdoor', [withdrawRequirement(plant, config, INV, {})], caps.VB)
    await expectSuccess(client, plant, A)
    await sealVault(A, VB, caps.VB)

    // B deposits 5 ORE into VB and gets a receipt. Everything looks normal on-chain.
    const receiptVB = await depositFromB(VB, 5n)

    // C (not the owner, holds no receipt) drains VB through the backdoor.
    const drain = new Transaction()
    const e = drain.object(VB)
    const r = interact(drain, config, e, 'backdoor')
    const loot = withdraw(drain, config, e, r, { key: ORE_KEY, quantity: 5n })
    completeRequest(drain, config, e, r)
    loadShip(drain, SHIP_C, caps.SHIP_C, loot)
    await expectSuccess(client, drain, C)
    expect(await bal(VB)).toBe(0n)
    expect(await supply(VB)).toBe(5n) // 5 receipts, 0 backing

    // B's receipt is now unredeemable.
    const tx = new Transaction()
    loadShip(tx, SHIP_B, caps.SHIP_B, redeem(tx, VB, tx.object(receiptVB)))
    const msg = await expectFails(tx, B.toSuiAddress())
    record({
      claim: 'pre-existing owner actions are invisible to warehouse_receipts and survive the seal',
      kind: 'risk',
      result: 'RISK_CONFIRMED',
      detail: `VB drained 5/5 with 5 receipts outstanding; redeem now fails: ${msg.slice(0, 160)}`,
    })

    // Cross-vault check while we have a foreign receipt: VB's receipt can't redeem at V.
    const cross = new Transaction()
    loadShip(cross, SHIP_B, caps.SHIP_B, redeem(cross, V, cross.object(receiptVB)))
    const crossMsg = await expectFails(cross, B.toSuiAddress(), /EWrongCollection/)
    record({ claim: "a vault rejects another vault's receipts", kind: 'guarantee', result: 'PASS', detail: crossMsg.slice(0, 160) })
  })

  it('RISK: a sealed vault cannot be refueled by anyone; when fuel runs out receipts are unredeemable', async () => {
    await powerOn(A, VS, caps.VS, SHORT_FUEL)
    await sealVault(A, VS, caps.VS)
    const receiptVS = await depositFromB(VS, 3n)

    const deadline = Date.now() + 90_000
    while ((await fuelOf(VS)) > 0n && Date.now() < deadline) await new Promise((r) => setTimeout(r, 2_000))
    expect(await fuelOf(VS)).toBe(0n)

    const tx = new Transaction()
    loadShip(tx, SHIP_B, caps.SHIP_B, redeem(tx, VS, tx.object(receiptVS)))
    const redeemMsg = await expectFails(tx, B.toSuiAddress())

    // deposit_fuel pushes an owner requirement from inside the handler; the cap is parked.
    const refuelOwner = new Transaction()
    refuel(refuelOwner, VS, caps.VS, LONG_FUEL)
    const ownerMsg = await expectFails(refuelOwner, A.toSuiAddress())
    record({
      claim: 'sealed vault liveness: nobody can refuel it (deposit_fuel hard-codes the owner check)',
      kind: 'risk',
      result: 'RISK_CONFIRMED',
      detail: `redeem after fuel-out: ${redeemMsg.slice(0, 120)} | refuel by former owner: ${ownerMsg.slice(0, 120)}`,
    })

    // The only recovery is admin revoke + re-mint, which un-seals the vault (next test).
    const revoke = new Transaction()
    revokeAccess(revoke, config, VS)
    await expectSuccess(client, revoke)
    const fresh = await mintCap(VS, A.toSuiAddress())
    const re = new Transaction()
    refuel(re, VS, fresh, LONG_FUEL)
    switchGridOn(re, VS, fresh) // running dry tripped the grid
    await expectSponsored(client, re, A)
    const retry = new Transaction()
    loadShip(retry, SHIP_B, caps.SHIP_B, redeem(retry, VS, retry.object(receiptVS)))
    await expectSuccess(client, retry, B)
    record({ claim: 'recovery from fuel-out requires the admin to re-mint an owner cap', kind: 'risk', result: 'RISK_CONFIRMED', detail: 'revoke + mint_access + refuel + grid on, then redeem succeeds' })
  }, 180_000)

  it('RISK: admin re-mint un-seals a vault; the new owner can add a drain action', async () => {
    // VT was re-minted to A in the TRIEX-160 test.
    const tx = new Transaction()
    enableAction(tx, config, tx.object(VT), 'steal', [withdrawRequirement(tx, config, INV, {})], caps.VT2)
    await expectSuccess(client, tx, A)
    record({ claim: 'admin revoke_access + mint_access hands back full owner control', kind: 'risk', result: 'RISK_CONFIRMED' })
  })

  it('RISK: an admin action with the same name shadows wr_redeem and drains without receipts', async () => {
    const shadow = new Transaction()
    enableAdminAction(shadow, config, shadow.object(V), 'wr_redeem', [withdrawRequirement(shadow, config, INV, {})])
    await expectSuccess(client, shadow)

    const drain = new Transaction()
    const e = drain.object(V)
    const r = interact(drain, config, e, 'wr_redeem')
    const loot = withdraw(drain, config, e, r, { key: ORE_KEY, quantity: 6n })
    completeRequest(drain, config, e, r)
    loadShip(drain, SHIP_C, caps.SHIP_C, loot)
    await expectSuccess(client, drain, C)
    expect(await bal(V)).toBe(0n)
    expect(await supply(V)).toBe(6n)
    record({ claim: 'admin actions shadow owner actions; game admin can drain a sealed vault', kind: 'risk', result: 'RISK_CONFIRMED', detail: 'V drained 6/6 with 6 receipts outstanding' })
  })
})
