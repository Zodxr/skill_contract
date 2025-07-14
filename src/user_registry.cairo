// UserRegistry Contract
// Manages user accounts, roles, and reputation system

use starknet::ContractAddress;
use super::{User, UserRole};

#[starknet::interface]
pub trait IUserRegistry<TContractState> {
    // User Management Functions
    fn register_user(ref self: TContractState, role: UserRole, profile_hash: felt252) -> bool;
    fn verify_user(ref self: TContractState, user_address: ContractAddress) -> bool;
    fn update_reputation(
        ref self: TContractState, user_address: ContractAddress, score_delta: i256,
    ) -> bool;
    fn authorize_contract(ref self: TContractState, contract_address: ContractAddress) -> bool;

    // View Functions
    fn get_user(self: @TContractState, user_address: ContractAddress) -> User;
    fn is_user_verified(self: @TContractState, user_address: ContractAddress) -> bool;
    fn get_user_role(self: @TContractState, user_address: ContractAddress) -> UserRole;
    fn get_reputation_score(self: @TContractState, user_address: ContractAddress) -> u256;
    fn get_user_count(self: @TContractState) -> u256;
    fn get_role_count(self: @TContractState, role: UserRole) -> u256;
    fn is_contract_authorized(self: @TContractState, contract_address: ContractAddress) -> bool;
}

#[starknet::contract]
pub mod UserRegistry {
    use core::starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use super::{IUserRegistry, User, UserRole};

    #[storage]
    struct Storage {
        // Core user data
        users: Map<ContractAddress, User>,
        user_count: u256,
        // Access control
        admin: ContractAddress,
        authorized_contracts: Map<ContractAddress, bool>,
        // Role tracking
        role_counts: Map<UserRole, u256>,
        // Contract state
        is_paused: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        UserRegistered: UserRegistered,
        UserVerified: UserVerified,
        ReputationUpdated: ReputationUpdated,
        ContractAuthorized: ContractAuthorized,
        AdminChanged: AdminChanged,
    }

    #[derive(Drop, starknet::Event)]
    pub struct UserRegistered {
        pub user_address: ContractAddress,
        pub role: UserRole,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct UserVerified {
        pub user_address: ContractAddress,
        pub verified_by: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ReputationUpdated {
        pub user_address: ContractAddress,
        pub old_score: u256,
        pub new_score: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractAuthorized {
        pub contract_address: ContractAddress,
        pub authorized_by: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AdminChanged {
        pub old_admin: ContractAddress,
        pub new_admin: ContractAddress,
        pub timestamp: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.admin.write(admin);
        self.user_count.write(0);
        self.is_paused.write(false);
    }

    // Modifiers
    fn assert_only_admin(self: @ContractState) {
        let caller = get_caller_address();
        let admin = self.admin.read();
        assert(caller == admin, 'Only admin can call this function');
    }

    fn assert_not_paused(self: @ContractState) {
        assert(!self.is_paused.read(), 'Contract is paused');
    }

    fn assert_authorized(self: @ContractState) {
        let caller = get_caller_address();
        let admin = self.admin.read();
        let is_authorized = self.authorized_contracts.read(caller);
        assert(caller == admin || is_authorized, 'Caller not authorized');
    }

    #[abi(embed_v0)]
    impl UserRegistryImpl of IUserRegistry<ContractState> {
        fn register_user(ref self: ContractState, role: UserRole, profile_hash: felt252) -> bool {
            self.assert_not_paused();
            let caller = get_caller_address();

            // Check if user already exists
            let existing_user = self.users.read(caller);
            assert(existing_user.address.is_zero(), 'User already registered');

            // Create new user
            let timestamp = get_block_timestamp();
            let initial_reputation = match role {
                UserRole::Student => 100_u256,
                UserRole::Tutor => 500_u256,
                UserRole::University => 1000_u256,
                UserRole::Verifier => 750_u256,
            };

            let new_user = User {
                address: caller,
                role: role,
                reputation_score: initial_reputation,
                is_verified: false,
                profile_hash: profile_hash,
                created_at: timestamp,
            };

            // Store user data
            self.users.write(caller, new_user);

            // Update counters
            let current_count = self.user_count.read();
            self.user_count.write(current_count + 1);

            let role_count = self.role_counts.read(role);
            self.role_counts.write(role, role_count + 1);

            // Emit event
            self.emit(UserRegistered { user_address: caller, role: role, timestamp: timestamp });

            true
        }

        fn verify_user(ref self: ContractState, user_address: ContractAddress) -> bool {
            self.assert_not_paused();
            let caller = get_caller_address();
            let caller_user = self.users.read(caller);

            // Only admin or universities can verify users
            let admin = self.admin.read();
            assert(
                caller == admin || caller_user.role == UserRole::University,
                'Not authorized to verify users',
            );

            let mut user = self.users.read(user_address);
            assert(!user.address.is_zero(), 'User does not exist');
            assert(!user.is_verified, 'User already verified');

            user.is_verified = true;
            self.users.write(user_address, user);

            // Emit event
            self
                .emit(
                    UserVerified {
                        user_address: user_address,
                        verified_by: caller,
                        timestamp: get_block_timestamp(),
                    },
                );

            true
        }

        fn update_reputation(
            ref self: ContractState, user_address: ContractAddress, score_delta: i256,
        ) -> bool {
            self.assert_authorized();

            let mut user = self.users.read(user_address);
            assert(!user.address.is_zero(), 'User does not exist');

            let old_score = user.reputation_score;

            // Handle reputation changes (prevent underflow)
            if score_delta < 0 {
                let delta_abs = (-score_delta).try_into().unwrap();
                if delta_abs > old_score {
                    user.reputation_score = 0;
                } else {
                    user.reputation_score = old_score - delta_abs;
                }
            } else {
                let delta_pos = score_delta.try_into().unwrap();
                user.reputation_score = old_score + delta_pos;
            }

            self.users.write(user_address, user);

            // Emit event
            self
                .emit(
                    ReputationUpdated {
                        user_address: user_address,
                        old_score: old_score,
                        new_score: user.reputation_score,
                        timestamp: get_block_timestamp(),
                    },
                );

            true
        }

        fn authorize_contract(ref self: ContractState, contract_address: ContractAddress) -> bool {
            self.assert_only_admin();

            self.authorized_contracts.write(contract_address, true);

            // Emit event
            self
                .emit(
                    ContractAuthorized {
                        contract_address: contract_address,
                        authorized_by: get_caller_address(),
                        timestamp: get_block_timestamp(),
                    },
                );

            true
        }

        // View Functions
        fn get_user(self: @ContractState, user_address: ContractAddress) -> User {
            self.users.read(user_address)
        }

        fn is_user_verified(self: @ContractState, user_address: ContractAddress) -> bool {
            let user = self.users.read(user_address);
            user.is_verified
        }

        fn get_user_role(self: @ContractState, user_address: ContractAddress) -> UserRole {
            let user = self.users.read(user_address);
            user.role
        }

        fn get_reputation_score(self: @ContractState, user_address: ContractAddress) -> u256 {
            let user = self.users.read(user_address);
            user.reputation_score
        }

        fn get_user_count(self: @ContractState) -> u256 {
            self.user_count.read()
        }

        fn get_role_count(self: @ContractState, role: UserRole) -> u256 {
            self.role_counts.read(role)
        }

        fn is_contract_authorized(self: @ContractState, contract_address: ContractAddress) -> bool {
            self.authorized_contracts.read(contract_address)
        }
    }

    // Admin functions (internal)
    #[generate_trait]
    impl AdminImpl of AdminTrait {
        fn pause(ref self: ContractState) {
            self.assert_only_admin();
            self.is_paused.write(true);
        }

        fn unpause(ref self: ContractState) {
            self.assert_only_admin();
            self.is_paused.write(false);
        }

        fn change_admin(ref self: ContractState, new_admin: ContractAddress) {
            self.assert_only_admin();
            let old_admin = self.admin.read();
            self.admin.write(new_admin);

            self
                .emit(
                    AdminChanged {
                        old_admin: old_admin,
                        new_admin: new_admin,
                        timestamp: get_block_timestamp(),
                    },
                );
        }
    }
}
