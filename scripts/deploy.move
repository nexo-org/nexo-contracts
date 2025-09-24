script {
    use std::signer;
    use std::option;
    use credit_protocol::interest_rate_model;
    use credit_protocol::lending_pool;
    use credit_protocol::collateral_vault;
    use credit_protocol::reputation_manager;
    use credit_protocol::credit_manager;

    /// Deploy and initialize all contracts
    fun deploy_credit_protocol(deployer: &signer) {
        // Initialize Interest Rate Model
        interest_rate_model::initialize(
            deployer,
            @0x0, // credit manager address - will be updated later
            option::none(), // lending pool address - will be updated later
        );

        // Initialize Reputation Manager
        reputation_manager::initialize(
            deployer,
            @0x0, // credit manager address - will be updated later
        );

        // Initialize Collateral Vault
        collateral_vault::initialize(
            deployer,
            @0x0, // credit manager address - will be updated later
        );

        // Initialize Lending Pool
        lending_pool::initialize(
            deployer,
            @0x0, // credit manager address - will be updated later
        );

        // Initialize Credit Manager with all component addresses
        let deployer_addr = signer::address_of(deployer);
        credit_manager::initialize(
            deployer,
            deployer_addr, // lending pool address
            deployer_addr, // collateral vault address
            deployer_addr, // reputation manager address
            deployer_addr, // interest rate model address
        );
    }
}