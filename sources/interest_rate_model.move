module credit_protocol::interest_rate_model {
    use std::signer;
    use std::error;
    use std::option::{Self, Option};
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::account;

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INVALID_RATE: u64 = 2;
    const E_INVALID_UTILIZATION: u64 = 3;
    const E_INVALID_GRACE_PERIOD: u64 = 4;
    const E_ALREADY_INITIALIZED: u64 = 5;
    const E_NOT_INITIALIZED: u64 = 6;
    const E_INVALID_PARAMETERS: u64 = 7;

    /// Constants
    const BASIS_POINTS: u256 = 10000;
    const SECONDS_PER_YEAR: u64 = 31536000; // 365 * 24 * 60 * 60
    const PRECISION: u256 = 1000000000000000000; // 1e18
    const MAX_RATE_LIMIT: u256 = 10000; // 100%
    const MIN_GRACE_PERIOD: u64 = 86400; // 1 day
    const MAX_GRACE_PERIOD: u64 = 7776000; // 90 days

    /// Rate model types
    const RATE_MODEL_FIXED: u8 = 0;
    const RATE_MODEL_DYNAMIC: u8 = 1;

    /// Rate parameters structure
    struct RateParameters has copy, store, drop {
        base_rate: u256,           // Base interest rate in basis points
        max_rate: u256,            // Maximum interest rate in basis points
        penalty_rate: u256,        // Penalty rate for high utilization
        optimal_utilization: u256,  // Optimal utilization ratio
        penalty_utilization: u256,  // Penalty utilization threshold
        model_type: u8,            // Fixed or Dynamic
        is_active: bool,           // Whether the model is active
    }

    /// Interest rate model resource
    struct InterestRateModel has key {
        admin: address,
        credit_manager: address,
        lending_pool: Option<address>,
        rate_params: RateParameters,
        grace_period: u64,
        is_paused: bool,
    }

    /// Events
    #[event]
    struct RateUpdatedEvent has drop, store {
        old_rate: u256,
        new_rate: u256,
        model_type: u8,
        timestamp: u64,
    }

    #[event]
    struct GracePeriodChangedEvent has drop, store {
        old_period: u64,
        new_period: u64,
        timestamp: u64,
    }

    #[event]
    struct RateParametersUpdatedEvent has drop, store {
        base_rate: u256,
        max_rate: u256,
        penalty_rate: u256,
        optimal_utilization: u256,
        penalty_utilization: u256,
        model_type: u8,
        timestamp: u64,
    }

    #[event]
    struct LendingPoolUpdatedEvent has drop, store {
        old_pool: Option<address>,
        new_pool: Option<address>,
        timestamp: u64,
    }

    /// Initialize the interest rate model
    public entry fun initialize(
        admin: &signer,
        credit_manager: address,
        lending_pool: Option<address>,
    ) {
        let admin_addr = signer::address_of(admin);

        assert!(!exists<InterestRateModel>(admin_addr), error::already_exists(E_ALREADY_INITIALIZED));

        let rate_params = RateParameters {
            base_rate: 1500,  // 15%
            max_rate: 2000,   // 20%
            penalty_rate: 3000, // 30%
            optimal_utilization: 5000, // 50%
            penalty_utilization: 9000, // 90%
            model_type: RATE_MODEL_FIXED,
            is_active: true,
        };

        let interest_rate_model = InterestRateModel {
            admin: admin_addr,
            credit_manager,
            lending_pool,
            rate_params,
            grace_period: 2592000, // 30 days
            is_paused: false,
        };

        move_to(admin, interest_rate_model);
    }

    /// Get the current annual rate
    public fun get_annual_rate(model_addr: address): u256 acquires InterestRateModel {
        let model = borrow_global<InterestRateModel>(model_addr);
        assert!(!model.is_paused, error::invalid_state(E_NOT_AUTHORIZED));

        if (model.rate_params.model_type == RATE_MODEL_FIXED) {
            model.rate_params.base_rate
        } else {
            calculate_dynamic_rate(model_addr)
        }
    }

    /// Set annual rate (only for fixed rate model)
    public entry fun set_annual_rate(
        admin: &signer,
        model_addr: address,
        new_rate: u256,
    ) acquires InterestRateModel {
        let admin_addr = signer::address_of(admin);
        let model = borrow_global_mut<InterestRateModel>(model_addr);

        assert!(model.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(!model.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(new_rate <= MAX_RATE_LIMIT, error::invalid_argument(E_INVALID_RATE));

        let old_rate = model.rate_params.base_rate;
        model.rate_params.base_rate = new_rate;

        event::emit(RateUpdatedEvent {
            old_rate,
            new_rate,
            model_type: model.rate_params.model_type,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Calculate accrued interest for a loan
    public fun calculate_accrued_interest(
        model_addr: address,
        principal: u256,
        borrow_timestamp: u64,
    ): u256 acquires InterestRateModel {
        if (principal == 0 || borrow_timestamp == 0) {
            return 0
        };

        let current_time = timestamp::now_seconds();
        if (current_time <= borrow_timestamp) {
            return 0
        };

        let model = borrow_global<InterestRateModel>(model_addr);

        // Check if still in grace period
        if (current_time <= borrow_timestamp + model.grace_period) {
            return 0
        };

        let interest_start_time = borrow_timestamp + model.grace_period;
        let time_elapsed = current_time - interest_start_time;

        if (time_elapsed == 0) {
            return 0
        };

        let current_rate = if (model.rate_params.model_type == RATE_MODEL_FIXED) {
            model.rate_params.base_rate
        } else {
            calculate_dynamic_rate(model_addr)
        };

        // Calculate interest: principal * rate * time / (BASIS_POINTS * SECONDS_PER_YEAR)
        let daily_rate = (current_rate * PRECISION) / (BASIS_POINTS * (SECONDS_PER_YEAR as u256));
        (principal * daily_rate * (time_elapsed as u256)) / PRECISION
    }

    /// Set grace period
    public entry fun set_grace_period(
        admin: &signer,
        model_addr: address,
        duration: u64,
    ) acquires InterestRateModel {
        let admin_addr = signer::address_of(admin);
        let model = borrow_global_mut<InterestRateModel>(model_addr);

        assert!(model.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(!model.is_paused, error::invalid_state(E_NOT_AUTHORIZED));
        assert!(
            duration >= MIN_GRACE_PERIOD && duration <= MAX_GRACE_PERIOD,
            error::invalid_argument(E_INVALID_GRACE_PERIOD)
        );

        let old_period = model.grace_period;
        model.grace_period = duration;

        event::emit(GracePeriodChangedEvent {
            old_period,
            new_period: duration,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update rate parameters
    public entry fun update_rate_parameters(
        admin: &signer,
        model_addr: address,
        base_rate: u256,
        max_rate: u256,
        penalty_rate: u256,
        optimal_utilization: u256,
        penalty_utilization: u256,
        model_type: u8,
    ) acquires InterestRateModel {
        let admin_addr = signer::address_of(admin);
        let model = borrow_global_mut<InterestRateModel>(model_addr);

        assert!(model.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        assert!(!model.is_paused, error::invalid_state(E_NOT_AUTHORIZED));

        // Validate parameters
        assert!(base_rate <= MAX_RATE_LIMIT, error::invalid_argument(E_INVALID_RATE));
        assert!(max_rate <= MAX_RATE_LIMIT, error::invalid_argument(E_INVALID_RATE));
        assert!(penalty_rate <= MAX_RATE_LIMIT, error::invalid_argument(E_INVALID_RATE));
        assert!(optimal_utilization <= BASIS_POINTS, error::invalid_argument(E_INVALID_UTILIZATION));
        assert!(penalty_utilization <= BASIS_POINTS, error::invalid_argument(E_INVALID_UTILIZATION));
        assert!(base_rate <= max_rate, error::invalid_argument(E_INVALID_PARAMETERS));
        assert!(max_rate <= penalty_rate, error::invalid_argument(E_INVALID_PARAMETERS));
        assert!(optimal_utilization <= penalty_utilization, error::invalid_argument(E_INVALID_PARAMETERS));

        model.rate_params.base_rate = base_rate;
        model.rate_params.max_rate = max_rate;
        model.rate_params.penalty_rate = penalty_rate;
        model.rate_params.optimal_utilization = optimal_utilization;
        model.rate_params.penalty_utilization = penalty_utilization;
        model.rate_params.model_type = model_type;

        event::emit(RateParametersUpdatedEvent {
            base_rate,
            max_rate,
            penalty_rate,
            optimal_utilization,
            penalty_utilization,
            model_type,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Update lending pool address
    public entry fun update_lending_pool(
        admin: &signer,
        model_addr: address,
        new_lending_pool: Option<address>,
    ) acquires InterestRateModel {
        let admin_addr = signer::address_of(admin);
        let model = borrow_global_mut<InterestRateModel>(model_addr);

        assert!(model.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));

        let old_pool = model.lending_pool;
        model.lending_pool = new_lending_pool;

        event::emit(LendingPoolUpdatedEvent {
            old_pool,
            new_pool: new_lending_pool,
            timestamp: timestamp::now_seconds(),
        });
    }

    /// Check if grace period has ended
    public fun is_grace_period_ended(
        model_addr: address,
        borrow_timestamp: u64,
    ): bool acquires InterestRateModel {
        if (borrow_timestamp == 0) return false;

        let model = borrow_global<InterestRateModel>(model_addr);
        timestamp::now_seconds() > borrow_timestamp + model.grace_period
    }

    /// Get remaining grace period
    public fun get_remaining_grace_period(
        model_addr: address,
        borrow_timestamp: u64,
    ): u64 acquires InterestRateModel {
        if (borrow_timestamp == 0) return 0;

        let model = borrow_global<InterestRateModel>(model_addr);
        let grace_end = borrow_timestamp + model.grace_period;
        let current_time = timestamp::now_seconds();

        if (current_time >= grace_end) {
            0
        } else {
            grace_end - current_time
        }
    }

    /// Calculate interest for a specific period
    public fun calculate_interest_for_period(
        principal: u256,
        rate: u256,
        time_elapsed: u64,
    ): u256 {
        if (principal == 0 || rate == 0 || time_elapsed == 0) {
            return 0
        };

        let daily_rate = (rate * PRECISION) / (BASIS_POINTS * (SECONDS_PER_YEAR as u256));
        (principal * daily_rate * (time_elapsed as u256)) / PRECISION
    }

    /// Get rate parameters
    public fun get_rate_parameters(model_addr: address): RateParameters acquires InterestRateModel {
        let model = borrow_global<InterestRateModel>(model_addr);
        model.rate_params
    }

    /// Pause the interest rate model
    public entry fun pause(admin: &signer, model_addr: address) acquires InterestRateModel {
        let admin_addr = signer::address_of(admin);
        let model = borrow_global_mut<InterestRateModel>(model_addr);

        assert!(model.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        model.is_paused = true;
    }

    /// Unpause the interest rate model
    public entry fun unpause(admin: &signer, model_addr: address) acquires InterestRateModel {
        let admin_addr = signer::address_of(admin);
        let model = borrow_global_mut<InterestRateModel>(model_addr);

        assert!(model.admin == admin_addr, error::permission_denied(E_NOT_AUTHORIZED));
        model.is_paused = false;
    }

    /// Calculate dynamic rate based on utilization (internal function)
    fun calculate_dynamic_rate(model_addr: address): u256 acquires InterestRateModel {
        let model = borrow_global<InterestRateModel>(model_addr);

        // For now, return base rate if no lending pool is set
        // In a complete implementation, this would call the lending pool to get utilization
        if (option::is_none(&model.lending_pool)) {
            return model.rate_params.base_rate
        };

        // Simplified dynamic rate calculation - would need integration with lending pool
        // This is a placeholder implementation
        let utilization = 5000; // 50% - would be fetched from lending pool

        if (utilization <= model.rate_params.optimal_utilization) {
            let rate_increase = (utilization * (model.rate_params.max_rate - model.rate_params.base_rate)) /
                model.rate_params.optimal_utilization;
            model.rate_params.base_rate + rate_increase
        } else if (utilization <= model.rate_params.penalty_utilization) {
            let excess_utilization = utilization - model.rate_params.optimal_utilization;
            let utilization_range = model.rate_params.penalty_utilization - model.rate_params.optimal_utilization;
            let rate_increase = (excess_utilization * (model.rate_params.penalty_rate - model.rate_params.max_rate)) /
                utilization_range;
            model.rate_params.max_rate + rate_increase
        } else {
            model.rate_params.penalty_rate
        }
    }

    /// View functions
    public fun get_grace_period(model_addr: address): u64 acquires InterestRateModel {
        let model = borrow_global<InterestRateModel>(model_addr);
        model.grace_period
    }

    public fun is_paused(model_addr: address): bool acquires InterestRateModel {
        let model = borrow_global<InterestRateModel>(model_addr);
        model.is_paused
    }

    public fun get_admin(model_addr: address): address acquires InterestRateModel {
        let model = borrow_global<InterestRateModel>(model_addr);
        model.admin
    }
}