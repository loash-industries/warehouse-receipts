/// # MultiCoin - ERC-1155 Style Multi-Asset Standard for Sui
///
/// This module implements a fungible multi-asset system similar to Ethereum's ERC-1155 standard,
/// allowing a single collection to manage multiple asset types with independent balances and supplies.
///
/// ## Core Concepts
///
/// - **Collection**: A shared object representing a asset collection (similar to an ERC-1155 contract).
///   Each collection can contain (2^64)-1 asset types identified by u64 asset IDs.
///
/// - **asset ID**: A 64-bit (u64) identifier uniquely identifying each asset type within a collection.
///   Applications can choose any scheme for asset IDs - sequential, random, or encoded with semantic meaning.
///
/// - **Balance**: An owned object representing a user's balance of a specific asset type.
///   Similar to Sui's Coin type, balances can be split, merged, and transferred independently.
///
/// - **CollectionCap**: Admin capability for minting assets and managing metadata.
///   Only the holder of this capability can mint new assets or set metadata.
///
/// ## Key Features
///
/// - **Flexible asset IDs**: u64 IDs provide 2^64 unique asset types per collection
/// - **Independent Balances**: Each asset type has its own supply and owned balance objects
/// - **Coin-like Operations**: Split, merge, and transfer balances with type safety
/// - **Metadata Support**: Optional on-chain metadata storage per asset type
/// - **Batch Operations**: Mint and transfer multiple asset types efficiently
/// - **Event Emission**: Track all mints, burns, and transfers on-chain
///
/// ## Usage Example
///
/// ```move
/// // Create collection
/// let (collection, cap) = multicoin::new_collection(ctx);
///
/// // Define asset ID (any u64 value)
/// let asset_id: u64 = 1;
///
/// // Mint 100 assets
/// let balance = multicoin::mint_balance(&cap, &mut collection, asset_id, 100, ctx);
///
/// // Split and transfer 30 assets
/// let split_balance = balance.split(30, ctx);
/// transfer::transfer(split_balance, recipient);
/// ```
///
/// ## asset ID Design
///
/// asset IDs are arbitrary u64 values. Applications can choose their own schemes:
/// - **Sequential**: 1, 2, 3, ...
/// - **Random**: Generated UUIDs or hashes
/// - **Encoded**: Bit-pack multiple attributes (e.g., category + subcategory)
/// - **Hash-based**: Hash of asset attributes
module multicoin::multicoin {
    use sui::{balance::{Self, Supply, Balance as SuiBalance}, event, table::{Self, Table}};

    /*********************************
 * Errors
 *********************************/
    const EWrongCollection: u64 = 0;
    const EWrongAssetId: u64 = 1;
    const EInsufficientBalance: u64 = 2;
    const EInvalidArg: u64 = 3;
    const EZeroAmount: u64 = 4;
    const ESupplyNotInitialized: u64 = 5;

    /*********************************
 * Core Objects
 *********************************/

    /// Phantom type marker for collection asset supply tracking
    public struct CollectionAsset has drop {}

    /// Supply tracker with balance sink for safe supply management
    public struct SupplyTracker has store {
        supply: Supply<CollectionAsset>,
        /// Accumulated balance from all mints, used as source for burns
        balance_sink: SuiBalance<CollectionAsset>,
    }

    /// Shared collection (ERC-1155 "contract")
    public struct Collection has key, store {
        id: UID,
        metadata: Table<u64, vector<u8>>, // Optional metadata per asset ID
        supply: Table<u64, SupplyTracker>, // Supply tracker per asset ID
    }

    /// Admin capability for minting / control
    public struct CollectionCap has key, store {
        id: UID,
        collection: ID,
    }

    /// Owned balance object (Coin-like)
    public struct Balance has key, store {
        id: UID,
        collection: ID,
        asset_id: u64,
        amount: u64,
    }

    /*********************************
 * Events
 *********************************/

    /// Emitted when assets are transferred
    public struct TransferEvent has copy, drop {
        collection: ID,
        asset_id: u64,
        from: address,
        to: address,
        amount: u64,
    }

    /// Emitted when assets are minted
    public struct MintEvent has copy, drop {
        collection: ID,
        asset_id: u64,
        to: address,
        amount: u64,
    }

    /// Emitted when assets are burned
    public struct BurnEvent has copy, drop {
        collection: ID,
        asset_id: u64,
        from: address,
        amount: u64,
    }

    /// Emitted when a balance is split
    public struct SplitEvent has copy, drop {
        collection: ID,
        asset_id: u64,
        owner: address,
        original_amount: u64,
        split_amount: u64,
    }

    /// Emitted when balances are joined
    public struct JoinEvent has copy, drop {
        collection: ID,
        asset_id: u64,
        owner: address,
        amount_kept: u64,
        amount_joined: u64,
    }

    /*********************************
 * Creation
 *********************************/

    /// Create a new collection and return cap, transferring collection to sender
    entry fun create_collection(ctx: &mut TxContext) {
        let collection = Collection {
            id: object::new(ctx),
            metadata: table::new(ctx),
            supply: table::new(ctx),
        };

        let cap = CollectionCap {
            id: object::new(ctx),
            collection: object::id(&collection),
        };

        transfer::share_object(collection);
        transfer::transfer(cap, ctx.sender());
    }

    /// Create a new collection (programmatic version)
    public fun new_collection(ctx: &mut TxContext): (Collection, CollectionCap) {
        let collection = Collection {
            id: object::new(ctx),
            metadata: table::new(ctx),
            supply: table::new(ctx),
        };

        let cap = CollectionCap {
            id: object::new(ctx),
            collection: object::id(&collection),
        };

        (collection, cap)
    }

    /*********************************
 * Metadata (optional)
 *********************************/

    /// Set metadata for a asset type (requires CollectionCap)
    public fun set_metadata(
        cap: &CollectionCap,
        collection: &mut Collection,
        asset_id: u64,
        data: vector<u8>,
    ) {
        assert!(cap.collection == object::id(collection), EWrongCollection);
        if (collection.metadata.contains(asset_id)) {
            *collection.metadata.borrow_mut(asset_id) = data;
        } else {
            collection.metadata.add(asset_id, data);
        };
    }

    /// Get metadata for a asset type
    public fun get_metadata(collection: &Collection, asset_id: u64): &vector<u8> {
        collection.metadata.borrow(asset_id)
    }

    /// Check if metadata exists for a asset type
    public fun has_metadata(collection: &Collection, asset_id: u64): bool {
        collection.metadata.contains(asset_id)
    }

    /*********************************
 * Minting
 *********************************/

    /// Mint assets and transfer to recipient
    entry fun mint(
        cap: &CollectionCap,
        collection: &mut Collection,
        asset_id: u64,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, EZeroAmount);
        let balance = mint_balance(cap, collection, asset_id, amount, ctx);

        event::emit(MintEvent {
            collection: object::id(collection),
            asset_id,
            to: recipient,
            amount,
        });

        transfer::transfer(balance, recipient);
    }

    /// Mint assets as a Balance object
    public fun mint_balance(
        cap: &CollectionCap,
        collection: &mut Collection,
        asset_id: u64,
        amount: u64,
        ctx: &mut TxContext,
    ): Balance {
        assert!(cap.collection == object::id(collection), EWrongCollection);
        assert!(amount > 0, EZeroAmount);

        // Initialize supply tracker if needed
        if (!collection.supply.contains(asset_id)) {
            let tracker = SupplyTracker {
                supply: balance::create_supply(CollectionAsset {}),
                balance_sink: balance::zero<CollectionAsset>(),
            };
            collection.supply.add(asset_id, tracker);
        };

        // Use Supply::increase_supply (has built-in overflow protection)
        let tracker = collection.supply.borrow_mut(asset_id);
        let minted_balance = tracker.supply.increase_supply(amount);
        // Store in balance sink for future burns
        tracker.balance_sink.join(minted_balance);

        // Note: MintEvent is emitted by caller (mint() or mint_and_keep())
        // to ensure correct recipient address is recorded

        Balance {
            id: object::new(ctx),
            collection: cap.collection,
            asset_id,
            amount,
        }
    }

    /// Batch mint multiple asset types to a single recipient
    entry fun batch_mint(
        cap: &CollectionCap,
        collection: &mut Collection,
        asset_ids: vector<u64>,
        amounts: vector<u64>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(asset_ids.length() == amounts.length(), EInvalidArg);
        assert!(asset_ids.length() > 0, EInvalidArg);

        asset_ids.zip_do!(amounts, |asset_id, amount| {
            mint(cap, collection, asset_id, amount, recipient, ctx);
        });
    }

    /// Mint assets and keep them (for composability)
    public fun mint_and_keep(
        cap: &CollectionCap,
        collection: &mut Collection,
        asset_id: u64,
        amount: u64,
        ctx: &mut TxContext,
    ): Balance {
        let balance = mint_balance(cap, collection, asset_id, amount, ctx);

        // Emit event with sender as recipient
        event::emit(MintEvent {
            collection: object::id(collection),
            asset_id,
            to: ctx.sender(),
            amount,
        });

        balance
    }

    /*********************************
 * Balance operations (Coin-like)
 *********************************/

    /// Split a balance into two
    public fun split(balance: &mut Balance, amount: u64, ctx: &mut TxContext): Balance {
        assert!(balance.amount >= amount, EInsufficientBalance);
        assert!(amount > 0, EZeroAmount);

        let original_amount = balance.amount;
        balance.amount = balance.amount - amount;

        event::emit(SplitEvent {
            collection: balance.collection,
            asset_id: balance.asset_id,
            owner: ctx.sender(),
            original_amount,
            split_amount: amount,
        });

        Balance {
            id: object::new(ctx),
            collection: balance.collection,
            asset_id: balance.asset_id,
            amount,
        }
    }

    /// Split and transfer to recipient
    entry fun split_and_transfer(
        balance: &mut Balance,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        let split_balance = balance.split(amount, ctx);

        event::emit(TransferEvent {
            collection: split_balance.collection,
            asset_id: split_balance.asset_id,
            from: ctx.sender(),
            to: recipient,
            amount,
        });

        transfer::transfer(split_balance, recipient);
    }

    /// Merge two balances of the same asset type
    /// Aborts if self.amount + other.amount > U64_MAX
    public fun join(self: &mut Balance, other: Balance, ctx: &TxContext) {
        assert!(self.collection == other.collection, EWrongCollection);
        assert!(self.asset_id == other.asset_id, EWrongAssetId);

        let amount_to_join = other.amount;
        let Balance { id, .. } = other;

        // Add with overflow protection (like coin.move's balance.join)
        self.amount = self.amount + amount_to_join;

        event::emit(JoinEvent {
            collection: self.collection,
            asset_id: self.asset_id,
            owner: ctx.sender(),
            amount_kept: self.amount - amount_to_join,
            amount_joined: amount_to_join,
        });

        id.delete();
    }

    #[allow(lint(custom_state_change))]
    /// Entry function wrapper for join - allows direct joining from transactions
    entry fun join_entry(self: &mut Balance, other: Balance, ctx: &TxContext) {
        self.join(other, ctx);
    }

    /// Create a zero balance (useful for initialization or empty withdrawals)
    public fun zero(collection_id: ID, asset_id: u64, ctx: &mut TxContext): Balance {
        Balance {
            id: object::new(ctx),
            collection: collection_id,
            asset_id,
            amount: 0,
        }
    }

    /// Destroy a zero balance
    public fun destroy_zero(balance: Balance) {
        assert!(balance.amount == 0, EInsufficientBalance);
        let Balance { id, .. } = balance;
        id.delete();
    }

    /*********************************
 * Burning
 *********************************/

    /// Burn assets
    public fun burn(collection: &mut Collection, balance: Balance, ctx: &TxContext): u64 {
        let Balance { id, collection: balance_collection, asset_id, amount } = balance;

        // Verify balance belongs to this collection
        assert!(object::id(collection) == balance_collection, EWrongCollection);

        // Supply tracker must exist for consistent accounting - fail fast if missing
        assert!(collection.supply.contains(asset_id), ESupplyNotInitialized);

        // Use Supply::decrease_supply (has built-in underflow protection)
        let tracker = collection.supply.borrow_mut(asset_id);
        // Split from balance sink and decrease supply
        let burn_balance = tracker.balance_sink.split(amount);
        tracker.supply.decrease_supply(burn_balance);

        // Check if supply reached zero and cleanup metadata
        // Note: SupplyTracker and Supply<T> remain in the table even at zero supply
        //
        // Why SupplyTracker cannot be destroyed:
        // - Supply<T> has `store` but NOT `drop` ability
        // - balance::destroy_supply() is `public(package)` (only callable within sui package)
        // - This is intentional design to:
        //   * Prevent accidental supply destruction
        //   * Maintain permanent supply history
        //   * Enable re-minting without re-initialization
        //
        // Storage cost: ~48 bytes per retired asset (acceptable for the guarantees provided)
        // If this package gets included in sui std lib, we can consider adding a `drop` ability
        let remaining_supply = tracker.supply.supply_value();
        if (remaining_supply == 0) {
            // Clean up metadata if it exists (free up storage)
            if (collection.metadata.contains(asset_id)) {
                collection.metadata.remove(asset_id);
            };

            // Verify balance_sink is empty (should be after decrease_supply)
            assert!(tracker.balance_sink.value() == 0, EInsufficientBalance);
        };

        event::emit(BurnEvent {
            collection: balance_collection,
            asset_id,
            from: ctx.sender(),
            amount,
        });

        id.delete();
        amount
    }

    /// Batch burn multiple balances
    entry fun batch_burn(collection: &mut Collection, balances: vector<Balance>, ctx: &TxContext) {
        balances.do!(|balance| {
            burn(collection, balance, ctx);
        });
    }

    /*********************************
 * Accessors
 *********************************/

    /// Get balance amount
    public fun value(balance: &Balance): u64 {
        balance.amount
    }

    /// Get asset ID
    public fun asset_id(balance: &Balance): u64 {
        balance.asset_id
    }

    /// Get collection ID
    public fun collection_id(balance: &Balance): ID {
        balance.collection
    }

    /// Get collection ID from cap
    public fun cap_collection_id(cap: &CollectionCap): ID {
        cap.collection
    }

    /// Get total supply for a asset type
    public fun total_supply(collection: &Collection, asset_id: u64): u64 {
        if (collection.supply.contains(asset_id)) {
            collection.supply.borrow(asset_id).supply.supply_value()
        } else {
            0
        }
    }

    /*********************************
 * Transfer functions
 *********************************/

    /// Transfer balance to recipient
    #[allow(lint(custom_state_change))]
    entry fun transfer(balance: Balance, recipient: address, ctx: &TxContext) {
        event::emit(TransferEvent {
            collection: balance.collection,
            asset_id: balance.asset_id,
            from: ctx.sender(),
            to: recipient,
            amount: balance.amount,
        });
        transfer::transfer(balance, recipient);
    }

    /// Batch transfer multiple balances to a single recipient
    entry fun batch_transfer(balances: vector<Balance>, recipient: address, ctx: &TxContext) {
        balances.do!(|balance| {
            transfer(balance, recipient, ctx);
        });
    }

    /*********************************
 * Test-only functions
 *********************************/

    #[test_only]
    /// Create a balance for testing
    ///
    /// WARNING: This bypasses supply tracking and should ONLY be used in tests
    /// to set up specific scenarios for testing underflow protection.
    public fun create_balance_for_testing(
        collection_id: ID,
        asset_id: u64,
        amount: u64,
        ctx: &mut TxContext,
    ): Balance {
        Balance {
            id: object::new(ctx),
            collection: collection_id,
            asset_id,
            amount,
        }
    }
}
