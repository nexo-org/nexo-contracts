module credit_protocol::lending_pool {
    use std::signer;
    use std::error;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::account;
    use aptos_framework::table::{Self, Table};

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 3;
    const E_INVALID_AMOUNT: u64 = 4;
    const E_ALREADY_INITIALIZED: u64 = 5;
    const E_NOT_INITIALIZED: u64 = 6;
    const E_INVALID_ADDRESS: u64 = 7;

    /// Constants
    const BASIS_POINTS: u256 = 10000;
    const PROTOCOL_FEE_RATE: u256 = 1000; // 10%

    /// Lender information structure
    struct LenderInfo has copy, store, drop {
        deposited_amount: u64,
        earned_interest: u64,
        deposit_timestamp: u64,
    }

    /// Lending pool resource
    struct LendingPool has key {
        admin: address,
        credit_manager: address,
        total_deposited: u64,
        total_borrowed: u64,
        total_repaid: u64,
        protocol_fees_collected: u64,
        lenders: Table<address, LenderInfo>,
        lenders_list: vector<address>,
        usdc_reserve: Coin<AptosCoin>, // Using AptosCoin as placeholder for USDC
        is_paused: bool,
    }

    /// Events
    #[event]
    struct DepositEvent has drop, store {
        lender: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct WithdrawEvent has drop, store {
        lender: address,
        amount: u64,
        interest: u64,
        timestamp: u64,
    }

    #[event]
    struct BorrowEvent has drop, store {
        borrower: address,
        amount: u64,
        timestamp: u64,
    }

    #[event]
    struct RepayEvent has drop, store {
        borrower: address,
        principal: u64,
        interest: u64,
        timestamp: u64,
    }

    #[event]
    struct CreditManagerUpdatedEvent has drop, store {
        old_manager: address,
        new_manager: address,
        timestamp: u64,
    }

    /// Initialize the lending pool
    public entry fun initialize(
        admin: &signer,
        credit_manager: address,
    ) {
        let admin_addr = signer::address_of(admin);

        assert!(!exists<LendingPool>(admin_addr), error::already_exists(E_ALREADY_INITIALIZED));

        let lending_pool = LendingPool {
            admin: admin_addr,
            credit_manager,
            total_deposited: 0,
            total_borrowed: 0,
            total_repaid: 0,
            protocol_fees_collected: 0,
            lenders: table::new(),
            lenders_list: vector::empty(),
            usdc_reserve: coin::zero<AptosCoin>(),
            is_paused: false,
        };

        move_to(admin, lending_pool);
    }

    /// Deposit funds into the lending pool
    public entry fun deposit(
        lender: &signer,
        pool_addr: address,
        amount: u64,
    ) acquires LendingPool {
        let lender_addr = signer::address_of(lender);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(!pool.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));

        // Transfer coins from lender to pool
        let deposit_coins = coin::withdraw<AptosCoin>(lender, amount);
        coin::merge(&mut pool.usdc_reserve, deposit_coins);

        // Update or create lender info
        if (table::contains(&pool.lenders, lender_addr)) {
            let lender_info = table::borrow_mut(&mut pool.lenders, lender_addr);
            lender_info.deposited_amount = lender_info.deposited_amount + amount;
            lender_info.deposit_timestamp = timestamp::now_seconds();
        } else {
            let lender_info = LenderInfo {
                deposited_amount: amount,
                earned_interest: 0,
                deposit_timestamp: timestamp::now_seconds(),
            };
            table::add(&mut pool.lenders, lender_addr, lender_info);
            vector::push_back(&mut pool.lenders_list, lender_addr);
        };

        pool.total_deposited = pool.total_deposited + amount;

        event::emit(DepositEvent {
            lender: lender_addr,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Withdraw funds from the lending pool
    public entry fun withdraw(
        lender: &signer,
        pool_addr: address,
        amount: u64,
    ) acquires LendingPool {
        let lender_addr = signer::address_of(lender);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(!pool.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(table::contains(&pool.lenders, lender_addr), error::not_found(E_NOT_INITIALIZED));

        // Check available liquidity first
        let available_liquidity = coin::value(&pool.usdc_reserve) - pool.protocol_fees_collected;
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        let lender_info = table::borrow_mut(&mut pool.lenders, lender_addr);
        assert!(lender_info.deposited_amount >= amount, error::invalid_argument(E_INSUFFICIENT_BALANCE));

        // Update lender info
        lender_info.deposited_amount = lender_info.deposited_amount - amount;
        pool.total_deposited = pool.total_deposited - amount;

        // Remove lender if balance is zero
        if (lender_info.deposited_amount == 0) {
            remove_lender_from_list(pool, lender_addr);
            table::remove(&mut pool.lenders, lender_addr);
        };

        // Transfer coins to lender
        let withdraw_coins = coin::extract(&mut pool.usdc_reserve, amount);
        coin::deposit(lender_addr, withdraw_coins);

        event::emit(WithdrawEvent {
            lender: lender_addr,
            amount,
            interest: 0, // Interest handling would be more complex in practice
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Borrow funds from the lending pool (only by credit manager)
    public entry fun borrow(
        credit_manager: &signer,
        pool_addr: address,
        borrower: address,
        amount: u64,
    ) acquires LendingPool {
        let manager_addr = signer::address_of(credit_manager);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.credit_manager == manager_addr, error::permission_denied(E_NOT_AUTHORIZED));

        // Check available liquidity inline
        let available_liquidity = coin::value(&pool.usdc_reserve) - pool.protocol_fees_collected;
        assert!(available_liquidity >= amount, error::invalid_state(E_INSUFFICIENT_LIQUIDITY));

        pool.total_borrowed = pool.total_borrowed + amount;

        // Transfer coins to borrower
        let borrow_coins = coin::extract(&mut pool.usdc_reserve, amount);
        coin::deposit(borrower, borrow_coins);

        event::emit(BorrowEvent {
            borrower,
            amount,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Repay borrowed funds (only by credit manager)
    public entry fun repay(
        credit_manager: &signer,
        pool_addr: address,
        borrower: address,
        principal: u64,
        interest: u64,
    ) acquires LendingPool {
        let manager_addr = signer::address_of(credit_manager);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.credit_manager == manager_addr, error::permission_denied(E_NOT_AUTHORIZED));

        // Calculate protocol fee
        let protocol_fee = ((interest as u256) * PROTOCOL_FEE_RATE / BASIS_POINTS as u64);
        let lender_interest = interest - protocol_fee;

        pool.total_repaid = pool.total_repaid + principal;
        pool.protocol_fees_collected = pool.protocol_fees_collected + protocol_fee;

        // Distribute interest to lenders
        if (lender_interest > 0 && pool.total_deposited > 0) {
            distribute_interest(pool, lender_interest);
        };

        // Receive repayment coins
        let repay_coins = coin::withdraw<AptosCoin>(credit_manager, principal + interest);
        coin::merge(&mut pool.usdc_reserve, repay_coins);

        event::emit(RepayEvent {
            borrower,
            principal,
            interest,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Get available liquidity in the pool
    public fun get_available_liquidity(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        let total_balance = coin::value(&pool.usdc_reserve);
        if (total_balance > pool.protocol_fees_collected) {
            total_balance - pool.protocol_fees_collected
        } else {
            0
        }
    }

    /// Get utilization rate of the pool
    public fun get_utilization_rate(pool_addr: address): u256 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        if (pool.total_deposited == 0) return 0;

        let current_borrowed = if (pool.total_borrowed > pool.total_repaid) {
            pool.total_borrowed - pool.total_repaid
        } else {
            0
        };

        ((current_borrowed as u256) * BASIS_POINTS) / (pool.total_deposited as u256)
    }

    /// Get lender information
    public fun get_lender_info(
        pool_addr: address,
        lender: address,
    ): (u64, u64, u64) acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);

        if (table::contains(&pool.lenders, lender)) {
            let lender_info = table::borrow(&pool.lenders, lender);
            (lender_info.deposited_amount, lender_info.earned_interest, lender_info.deposit_timestamp)
        } else {
            (0, 0, 0)
        }
    }

    /// Update credit manager (only by admin)
    public entry fun update_credit_manager(
        admin: &signer,
        pool_addr: address,
        new_credit_manager: address,
    ) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(new_credit_manager != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let old_manager = pool.credit_manager;
        pool.credit_manager = new_credit_manager;

        event::emit(CreditManagerUpdatedEvent {
            old_manager,
            new_manager: new_credit_manager,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Withdraw protocol fees (only by admin)
    public entry fun withdraw_protocol_fees(
        admin: &signer,
        pool_addr: address,
        to: address,
        amount: u64,
    ) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(to != @0x0, error::invalid_argument(E_INVALID_ADDRESS));

        let withdraw_amount = if (amount == 0) {
            pool.protocol_fees_collected
        } else {
            amount
        };

        assert!(
            withdraw_amount <= pool.protocol_fees_collected,
            error::invalid_argument(E_INSUFFICIENT_BALANCE)
        );

        pool.protocol_fees_collected = pool.protocol_fees_collected - withdraw_amount;

        // Transfer fees to specified address
        let fee_coins = coin::extract(&mut pool.usdc_reserve, withdraw_amount);
        coin::deposit(to, fee_coins);
    }

    /// Get all lenders
    public fun get_all_lenders(pool_addr: address): vector<address> acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.lenders_list
    }

    /// Pause the lending pool
    public entry fun pause(admin: &signer, pool_addr: address) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.is_paused = true;
    }

    /// Unpause the lending pool
    public entry fun unpause(admin: &signer, pool_addr: address) acquires LendingPool {
        let admin_addr = signer::address_of(admin);
        let pool = borrow_global_mut<LendingPool>(pool_addr);

        assert!(pool.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        pool.is_paused = false;
    }

    /// Internal function to distribute interest to lenders
    fun distribute_interest(pool: &mut LendingPool, interest_amount: u64) {
        let i = 0;
        let len = vector::length(&pool.lenders_list);

        while (i < len) {
            let lender_addr = *vector::borrow(&pool.lenders_list, i);
            let lender_info = table::borrow_mut(&mut pool.lenders, lender_addr);

            if (lender_info.deposited_amount > 0) {
                let lender_share = ((lender_info.deposited_amount as u256) * (interest_amount as u256))
                    / (pool.total_deposited as u256);
                lender_info.earned_interest = lender_info.earned_interest + (lender_share as u64);
            };

            i = i + 1;
        };
    }

    /// Internal function to remove lender from list
    fun remove_lender_from_list(pool: &mut LendingPool, lender: address) {
        let i = 0;
        let len = vector::length(&pool.lenders_list);
        let found = false;

        while (i < len && !found) {
            if (*vector::borrow(&pool.lenders_list, i) == lender) {
                vector::swap_remove(&mut pool.lenders_list, i);
                found = true;
            } else {
                i = i + 1;
            };
        };
    }

    /// View functions
    public fun get_total_deposited(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.total_deposited
    }

    public fun get_total_borrowed(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.total_borrowed
    }

    public fun get_total_repaid(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.total_repaid
    }

    public fun get_protocol_fees_collected(pool_addr: address): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.protocol_fees_collected
    }

    public fun is_paused(pool_addr: address): bool acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.is_paused
    }

    public fun get_admin(pool_addr: address): address acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.admin
    }

    public fun get_credit_manager(pool_addr: address): address acquires LendingPool {
        let pool = borrow_global<LendingPool>(pool_addr);
        pool.credit_manager
    }
}