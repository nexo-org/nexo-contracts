module credit_protocol::credit_manager {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::{Self, String};
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::account;
    use aptos_framework::table::{Self, Table};

    // Import other modules
    use credit_protocol::interest_rate_model;
    use credit_protocol::lending_pool;
    use credit_protocol::collateral_vault;
    use credit_protocol::reputation_manager;

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INVALID_AMOUNT: u64 = 2;
    const E_CREDIT_LINE_EXISTS: u64 = 3;
    const E_CREDIT_LINE_NOT_ACTIVE: u64 = 4;
    const E_EXCEEDS_CREDIT_LIMIT: u64 = 5;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 6;
    const E_EXCEEDS_BORROWED_AMOUNT: u64 = 7;
    const E_EXCEEDS_INTEREST: u64 = 8;
    const E_LIQUIDATION_NOT_ALLOWED: u64 = 9;
    const E_ALREADY_INITIALIZED: u64 = 10;
    const E_INVALID_ADDRESS: u64 = 11;

    /// Constants
    const BASIS_POINTS: u256 = 10000;
    const SECONDS_PER_YEAR: u64 = 31536000; // 365 * 24 * 60 * 60
    const GRACE_PERIOD: u64 = 2592000; // 30 days
    const MAX_LTV: u256 = 10000; // 100%
    const LIQUIDATION_THRESHOLD: u256 = 11000; // 110%

    /// Credit line structure
    struct CreditLine has copy, store, drop {
        collateral_deposited: u64,
        credit_limit: u64,
        borrowed_amount: u64,
        last_borrowed_timestamp: u64,
        interest_accrued: u64,
        last_interest_update: u64,
        repayment_due_date: u64,
        is_active: bool,
        total_repaid: u64,
        on_time_repayments: u64,
        late_repayments: u64,
    }

    /// Credit manager resource
    struct CreditManager has key {
        admin: address,
        lending_pool_addr: address,
        collateral_vault_addr: address,
        reputation_manager_addr: address,
        interest_rate_model_addr: address,
        fixed_interest_rate: u256,      // basis points
        reputation_threshold: u256,      // reputation score threshold
        credit_increase_multiplier: u256, // basis points
        credit_lines: Table<address, CreditLine>,
        borrowers_list: vector<address>,
        collateral_reserve: Coin<AptosCoin>, // For handling collateral transfers
        is_paused: bool,
    }

    /// Events
    #[event]
    struct CreditOpenedEvent has drop, store {
        borrower: address,
        collateral_amount: u64,
        credit_limit: u64,
        timestamp: u64,
    }

    #[event]
    struct BorrowedEvent has drop, store {
        borrower: address,
        amount: u64,
        total_borrowed: u64,
        due_date: u64,
        timestamp: u64,
    }

    #[event]
    struct DirectPaymentEvent has drop, store {
        borrower: address,
        recipient: address,
        amount: u64,
        total_borrowed: u64,
        due_date: u64,
        timestamp: u64,
    }

    #[event]
    struct RepaidEvent has drop, store {
        borrower: address,
        principal_amount: u64,
        interest_amount: u64,
        remaining_balance: u64,
        timestamp: u64,
    }

    #[event]
    struct LiquidatedEvent has drop, store {
        borrower: address,
        collateral_liquidated: u64,
        debt_cleared: u64,
        reason: String,
        timestamp: u64,
    }

    #[event]
    struct CreditLimitIncreasedEvent has drop, store {
        borrower: address,
        old_limit: u64,
        new_limit: u64,
        reputation_score: u256,
        timestamp: u64,
    }

    #[event]
    struct CollateralAddedEvent has drop, store {
        borrower: address,
        amount: u64,
        total_collateral: u64,
        new_credit_limit: u64,
        timestamp: u64,
    }

    /// Initialize the credit manager
    public entry fun initialize(
        admin: &signer,
        lending_pool_addr: address,
        collateral_vault_addr: address,
        reputation_manager_addr: address,
        interest_rate_model_addr: address,
    ) {
        let admin_addr = signer::address_of(admin);

        assert!(!exists<CreditManager>(admin_addr), error::already_exists(E_ALREADY_INITIALIZED));

        let credit_manager = CreditManager {
            admin: admin_addr,
            lending_pool_addr,
            collateral_vault_addr,
            reputation_manager_addr,
            interest_rate_model_addr,
            fixed_interest_rate: 1500, // 15%
            reputation_threshold: 750,
            credit_increase_multiplier: 1200, // 20% increase
            credit_lines: table::new(),
            borrowers_list: vector::empty(),
            collateral_reserve: coin::zero<AptosCoin>(),
            is_paused: false,
        };

        move_to(admin, credit_manager);
    }

    /// Open a credit line
    public entry fun open_credit_line(
        borrower: &signer,
        manager_addr: address,
        collateral_amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(collateral_amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(
            !table::contains(&manager.credit_lines, borrower_addr),
            error::already_exists(E_CREDIT_LINE_EXISTS)
        );

        // Transfer collateral from borrower to manager
        let collateral_coins = coin::withdraw<AptosCoin>(borrower, collateral_amount);
        coin::merge(&mut manager.collateral_reserve, collateral_coins);

        // Deposit collateral to vault (in practice, this would call the vault module)
        // For now, we'll assume the collateral is managed internally

        let credit_limit = collateral_amount; // 1:1 ratio for simplicity

        let credit_line = CreditLine {
            collateral_deposited: collateral_amount,
            credit_limit,
            borrowed_amount: 0,
            last_borrowed_timestamp: 0,
            interest_accrued: 0,
            last_interest_update: timestamp::now_seconds(),
            repayment_due_date: 0,
            is_active: true,
            total_repaid: 0,
            on_time_repayments: 0,
            late_repayments: 0,
        };

        table::add(&mut manager.credit_lines, borrower_addr, credit_line);
        vector::push_back(&mut manager.borrowers_list, borrower_addr);

        event::emit(CreditOpenedEvent {
            borrower: borrower_addr,
            collateral_amount,
            credit_limit,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Add collateral to existing credit line
    public entry fun add_collateral(
        borrower: &signer,
        manager_addr: address,
        collateral_amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(collateral_amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        // Transfer additional collateral
        let collateral_coins = coin::withdraw<AptosCoin>(borrower, collateral_amount);
        coin::merge(&mut manager.collateral_reserve, collateral_coins);

        // Update credit line
        credit_line.collateral_deposited = credit_line.collateral_deposited + collateral_amount;
        credit_line.credit_limit = credit_line.credit_limit + collateral_amount;

        event::emit(CollateralAddedEvent {
            borrower: borrower_addr,
            amount: collateral_amount,
            total_collateral: credit_line.collateral_deposited,
            new_credit_limit: credit_line.credit_limit,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Borrow funds
    public entry fun borrow(
        borrower: &signer,
        manager_addr: address,
        amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before borrowing
        update_interest_internal(manager, borrower_addr);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        assert!(
            total_debt + amount <= credit_line.credit_limit,
            error::invalid_state(E_EXCEEDS_CREDIT_LIMIT)
        );

        // Check liquidity from lending pool (would call lending_pool module)
        // For now, we'll assume liquidity is available

        // Update credit line
        credit_line.borrowed_amount = credit_line.borrowed_amount + amount;
        credit_line.last_borrowed_timestamp = timestamp::now_seconds();
        credit_line.repayment_due_date = timestamp::now_seconds() + GRACE_PERIOD + 2592000; // 30 days

        // Transfer borrowed amount to borrower (this would be done via lending pool)
        // For demonstration, we'll assume the transfer happens

        event::emit(BorrowedEvent {
            borrower: borrower_addr,
            amount,
            total_borrowed: credit_line.borrowed_amount,
            due_date: credit_line.repayment_due_date,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Borrow funds and pay directly to recipient
    public entry fun borrow_and_pay(
        borrower: &signer,
        manager_addr: address,
        recipient: address,
        amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        assert!(recipient != borrower_addr, error::invalid_argument(E_INVALID_ADDRESS));
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before borrowing
        update_interest_internal(manager, borrower_addr);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        assert!(
            total_debt + amount <= credit_line.credit_limit,
            error::invalid_state(E_EXCEEDS_CREDIT_LIMIT)
        );

        // Get funds from lending pool
        let borrowed_coins = lending_pool::borrow_for_payment(
            borrower,
            manager.lending_pool_addr,
            borrower_addr,
            amount
        );

        // Transfer funds directly to recipient
        coin::deposit(recipient, borrowed_coins);

        // Update credit line
        credit_line.borrowed_amount = credit_line.borrowed_amount + amount;
        credit_line.last_borrowed_timestamp = timestamp::now_seconds();
        credit_line.repayment_due_date = timestamp::now_seconds() + GRACE_PERIOD + 2592000; // 30 days

        event::emit(DirectPaymentEvent {
            borrower: borrower_addr,
            recipient,
            amount,
            total_borrowed: credit_line.borrowed_amount,
            due_date: credit_line.repayment_due_date,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Repay loan
    public entry fun repay(
        borrower: &signer,
        manager_addr: address,
        principal_amount: u64,
        interest_amount: u64,
    ) acquires CreditManager {
        let borrower_addr = signer::address_of(borrower);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(!manager.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(
            principal_amount > 0 || interest_amount > 0,
            error::invalid_argument(E_INVALID_AMOUNT)
        );
        assert!(
            table::contains(&manager.credit_lines, borrower_addr),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before repayment
        update_interest_internal(manager, borrower_addr);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower_addr);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));
        assert!(
            principal_amount <= credit_line.borrowed_amount,
            error::invalid_argument(E_EXCEEDS_BORROWED_AMOUNT)
        );
        assert!(
            interest_amount <= credit_line.interest_accrued,
            error::invalid_argument(E_EXCEEDS_INTEREST)
        );

        let total_repayment = principal_amount + interest_amount;

        // Transfer repayment from borrower (this would go through lending pool)
        let repayment_coins = coin::withdraw<AptosCoin>(borrower, total_repayment);
        coin::merge(&mut manager.collateral_reserve, repayment_coins);

        // Update credit line
        credit_line.borrowed_amount = credit_line.borrowed_amount - principal_amount;
        credit_line.interest_accrued = credit_line.interest_accrued - interest_amount;
        credit_line.total_repaid = credit_line.total_repaid + total_repayment;

        // Check if payment is on time
        let current_time = timestamp::now_seconds();
        let is_on_time = current_time <= credit_line.repayment_due_date;

        if (is_on_time) {
            credit_line.on_time_repayments = credit_line.on_time_repayments + 1;
        } else {
            credit_line.late_repayments = credit_line.late_repayments + 1;
        };

        // Update reputation (would call reputation manager module)
        // reputation_manager::update_reputation(manager.reputation_manager_addr, borrower_addr, is_on_time, total_repayment);

        // Store remaining balance before checking credit limit increase
        let remaining_balance = credit_line.borrowed_amount;

        // Check for credit limit increase
        check_credit_limit_increase_internal(manager, borrower_addr);

        event::emit(RepaidEvent {
            borrower: borrower_addr,
            principal_amount,
            interest_amount,
            remaining_balance,
            timestamp: current_time,
        });
    }

    /// Liquidate a borrower's position
    public entry fun liquidate(
        admin: &signer,
        manager_addr: address,
        borrower: address,
    ) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(
            table::contains(&manager.credit_lines, borrower),
            error::not_found(E_CREDIT_LINE_NOT_ACTIVE)
        );

        // Update interest before liquidation
        update_interest_internal(manager, borrower);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower);
        assert!(credit_line.is_active, error::invalid_state(E_CREDIT_LINE_NOT_ACTIVE));

        let is_over_ltv = is_over_ltv_internal(credit_line);
        let is_overdue = is_overdue_internal(credit_line);

        assert!(is_over_ltv || is_overdue, error::invalid_state(E_LIQUIDATION_NOT_ALLOWED));

        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        let collateral_to_liquidate = if (total_debt < credit_line.collateral_deposited) {
            total_debt
        } else {
            credit_line.collateral_deposited
        };

        // Liquidate collateral (would call collateral vault module)
        // collateral_vault::liquidate_collateral(manager.collateral_vault_addr, borrower, collateral_to_liquidate);

        // Update credit line
        credit_line.borrowed_amount = 0;
        credit_line.interest_accrued = 0;
        credit_line.collateral_deposited = credit_line.collateral_deposited - collateral_to_liquidate;

        // Update reputation (negative impact)
        // reputation_manager::record_default(manager.reputation_manager_addr, borrower, total_debt);

        if (credit_line.collateral_deposited == 0) {
            credit_line.is_active = false;
        };

        let reason = if (is_over_ltv) {
            string::utf8(b"Over LTV")
        } else {
            string::utf8(b"Overdue")
        };

        event::emit(LiquidatedEvent {
            borrower,
            collateral_liquidated: collateral_to_liquidate,
            debt_cleared: total_debt,
            reason,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Get credit information for a borrower
    public fun get_credit_info(
        manager_addr: address,
        borrower: address,
    ): (u64, u64, u64, u64, u64, u64, bool) acquires CreditManager {
        let manager = borrow_global<CreditManager>(manager_addr);

        if (table::contains(&manager.credit_lines, borrower)) {
            let credit_line = table::borrow(&manager.credit_lines, borrower);
            let current_interest = calculate_interest_internal(manager, borrower);
            let total_interest = credit_line.interest_accrued + current_interest;

            (
                credit_line.collateral_deposited,
                credit_line.credit_limit,
                credit_line.borrowed_amount,
                total_interest,
                credit_line.borrowed_amount + total_interest,
                credit_line.repayment_due_date,
                credit_line.is_active
            )
        } else {
            (0, 0, 0, 0, 0, 0, false)
        }
    }

    /// Get repayment history for a borrower
    public fun get_repayment_history(
        manager_addr: address,
        borrower: address,
    ): (u64, u64, u64) acquires CreditManager {
        let manager = borrow_global<CreditManager>(manager_addr);

        if (table::contains(&manager.credit_lines, borrower)) {
            let credit_line = table::borrow(&manager.credit_lines, borrower);
            (credit_line.on_time_repayments, credit_line.late_repayments, credit_line.total_repaid)
        } else {
            (0, 0, 0)
        }
    }

    /// Check credit increase eligibility
    public fun check_credit_increase_eligibility(
        manager_addr: address,
        borrower: address,
    ): (bool, u64) acquires CreditManager {
        let manager = borrow_global<CreditManager>(manager_addr);

        if (!table::contains(&manager.credit_lines, borrower)) {
            return (false, 0)
        };

        let credit_line = table::borrow(&manager.credit_lines, borrower);
        if (!credit_line.is_active) {
            return (false, 0)
        };

        // Get reputation score (would call reputation manager module)
        // let reputation_score = reputation_manager::get_reputation_score(manager.reputation_manager_addr, borrower);
        let reputation_score = 800; // Placeholder

        let has_good_reputation = reputation_score >= manager.reputation_threshold;
        let has_repayment_history = credit_line.on_time_repayments > 0;
        let no_current_debt = credit_line.borrowed_amount == 0;

        let eligible = has_good_reputation && has_repayment_history && no_current_debt;
        let new_limit = if (eligible) {
            ((credit_line.credit_limit as u256) * manager.credit_increase_multiplier / BASIS_POINTS as u64)
        } else {
            0
        };

        (eligible, new_limit)
    }

    /// Get all borrowers
    public fun get_all_borrowers(manager_addr: address): vector<address> acquires CreditManager {
        let manager = borrow_global<CreditManager>(manager_addr);
        manager.borrowers_list
    }

    /// Pause the credit manager
    public entry fun pause(admin: &signer, manager_addr: address) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        manager.is_paused = true;
    }

    /// Unpause the credit manager
    public entry fun unpause(admin: &signer, manager_addr: address) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        manager.is_paused = false;
    }

    /// Update parameters
    public entry fun update_parameters(
        admin: &signer,
        manager_addr: address,
        fixed_interest_rate: u256,
        reputation_threshold: u256,
        credit_increase_multiplier: u256,
    ) acquires CreditManager {
        let admin_addr = signer::address_of(admin);
        let manager = borrow_global_mut<CreditManager>(manager_addr);

        assert!(manager.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));

        manager.fixed_interest_rate = fixed_interest_rate;
        manager.reputation_threshold = reputation_threshold;
        manager.credit_increase_multiplier = credit_increase_multiplier;
    }

    /// Internal function to update interest
    fun update_interest_internal(manager: &mut CreditManager, borrower: address) {
        if (!table::contains(&manager.credit_lines, borrower)) {
            return
        };

        // Calculate new interest first before borrowing mutably
        let new_interest = calculate_interest_internal(manager, borrower);

        let credit_line = table::borrow_mut(&mut manager.credit_lines, borrower);
        if (credit_line.borrowed_amount > 0 && credit_line.last_borrowed_timestamp > 0) {
            credit_line.interest_accrued = credit_line.interest_accrued + new_interest;
            credit_line.last_interest_update = timestamp::now_seconds();
        };
    }

    /// Internal function to calculate interest
    fun calculate_interest_internal(manager: &CreditManager, borrower: address): u64 {
        if (!table::contains(&manager.credit_lines, borrower)) {
            return 0
        };

        let credit_line = table::borrow(&manager.credit_lines, borrower);
        if (credit_line.borrowed_amount == 0 || credit_line.last_borrowed_timestamp == 0) {
            return 0
        };

        // Calculate interest using interest rate model (would call interest rate model module)
        // let total_accrued = interest_rate_model::calculate_accrued_interest(
        //     manager.interest_rate_model_addr,
        //     credit_line.borrowed_amount,
        //     credit_line.last_borrowed_timestamp
        // );

        // Simplified interest calculation for demonstration
        let current_time = timestamp::now_seconds();
        let time_elapsed = current_time - credit_line.last_interest_update;
        let annual_rate = manager.fixed_interest_rate;
        let interest_per_second = (annual_rate * (credit_line.borrowed_amount as u256)) /
            (BASIS_POINTS * (SECONDS_PER_YEAR as u256));
        let new_interest = (interest_per_second * (time_elapsed as u256)) as u64;

        new_interest
    }

    /// Internal function to check if over LTV
    fun is_over_ltv_internal(credit_line: &CreditLine): bool {
        if (credit_line.collateral_deposited == 0) return true;

        let total_debt = credit_line.borrowed_amount + credit_line.interest_accrued;
        let current_ltv = ((total_debt as u256) * BASIS_POINTS) / (credit_line.collateral_deposited as u256);
        current_ltv > LIQUIDATION_THRESHOLD
    }

    /// Internal function to check if overdue
    fun is_overdue_internal(credit_line: &CreditLine): bool {
        credit_line.borrowed_amount > 0 && timestamp::now_seconds() > credit_line.repayment_due_date
    }

    /// Internal function to check credit limit increase
    fun check_credit_limit_increase_internal(manager: &mut CreditManager, borrower: address) {
        // Check eligibility directly without acquiring global again
        if (!table::contains(&manager.credit_lines, borrower)) {
            return
        };

        let credit_line = table::borrow(&manager.credit_lines, borrower);
        if (!credit_line.is_active) {
            return
        };

        // Get reputation score (would call reputation manager module)
        let reputation_score = 800; // Placeholder

        let has_good_reputation = reputation_score >= manager.reputation_threshold;
        let has_repayment_history = credit_line.on_time_repayments > 0;
        let no_current_debt = credit_line.borrowed_amount == 0;

        let eligible = has_good_reputation && has_repayment_history && no_current_debt;

        if (eligible) {
            let new_limit = ((credit_line.credit_limit as u256) * manager.credit_increase_multiplier / BASIS_POINTS as u64);

            let credit_line_mut = table::borrow_mut(&mut manager.credit_lines, borrower);
            let old_limit = credit_line_mut.credit_limit;
            credit_line_mut.credit_limit = new_limit;

            event::emit(CreditLimitIncreasedEvent {
                borrower,
                old_limit,
                new_limit,
                reputation_score,
                timestamp: timestamp::now_seconds(),
            });
        };
    }

    /// View functions
    public fun is_paused(manager_addr: address): bool acquires CreditManager {
        let manager = borrow_global<CreditManager>(manager_addr);
        manager.is_paused
    }

    public fun get_admin(manager_addr: address): address acquires CreditManager {
        let manager = borrow_global<CreditManager>(manager_addr);
        manager.admin
    }

    public fun get_lending_pool_addr(manager_addr: address): address acquires CreditManager {
        let manager = borrow_global<CreditManager>(manager_addr);
        manager.lending_pool_addr
    }

    public fun get_fixed_interest_rate(manager_addr: address): u256 acquires CreditManager {
        let manager = borrow_global<CreditManager>(manager_addr);
        manager.fixed_interest_rate
    }
}