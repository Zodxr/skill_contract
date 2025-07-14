// CredentialNFT Contract
// Issues and manages NFT-based credentials

use starknet::ContractAddress;
use super::Credential;

#[starknet::interface]
pub trait ICredentialNFT<TContractState> {
    // Credential Management Functions
    fn issue_credential(
        ref self: TContractState,
        student_address: ContractAddress,
        course_id: u256,
        skill_achieved: felt252,
        competency_level: u8,
        assessment_score: u256,
        expiry_date: u64
    ) -> u256;
    
    fn verify_credential(self: @TContractState, token_id: u256) -> bool;
    fn revoke_credential(ref self: TContractState, token_id: u256) -> bool;
    fn extend_credential(ref self: TContractState, token_id: u256, new_expiry: u64) -> bool;
    
    // View Functions
    fn get_credential(self: @TContractState, token_id: u256) -> Credential;
    fn get_student_credentials(self: @TContractState, student_address: ContractAddress) -> Array<u256>;
    fn get_course_credentials(self: @TContractState, course_id: u256) -> Array<u256>;
    fn is_credential_valid(self: @TContractState, token_id: u256) -> bool;
    fn get_credential_count(self: @TContractState) -> u256;
    
    // NFT Functions (from ERC721)
    fn balance_of(self: @TContractState, owner: ContractAddress) -> u256;
    fn owner_of(self: @TContractState, token_id: u256) -> ContractAddress;
    fn token_uri(self: @TContractState, token_id: u256) -> ByteArray;
}

#[starknet::contract]
pub mod CredentialNFT {
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};
    use core::starknet::storage::{
        StoragePointerReadAccess, StoragePointerWriteAccess,
        Map, StoragePathEntry
    };
    use super::{Credential, ICredentialNFT};
    use skill_contract::user_registry::{IUserRegistryDispatcher, IUserRegistryDispatcherTrait};
    use skill_contract::course_manager::{ICourseManagerDispatcher, ICourseManagerDispatcherTrait};
    
    // OpenZeppelin ERC721 component
    use openzeppelin::token::erc721::{ERC721Component, ERC721HooksEmptyImpl};
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::access::ownable::OwnableComponent;

    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    // ERC721 Mixin
    #[abi(embed_v0)]
    impl ERC721MixinImpl = ERC721Component::ERC721MixinImpl<ContractState>;
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;

    // Ownable
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        
        // Credential specific storage
        credentials: Map<u256, Credential>,
        credential_count: u256,
        student_credentials: Map<ContractAddress, Array<u256>>,
        course_credentials: Map<u256, Array<u256>>,
        revoked_credentials: Map<u256, bool>,
        
        // External contracts
        user_registry: ContractAddress,
        course_manager: ContractAddress,
        
        // Base URI for metadata
        base_uri: ByteArray,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        
        CredentialIssued: CredentialIssued,
        CredentialVerified: CredentialVerified,
        CredentialRevoked: CredentialRevoked,
        CredentialExtended: CredentialExtended,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CredentialIssued {
        pub token_id: u256,
        pub student_address: ContractAddress,
        pub course_id: u256,
        pub skill_achieved: felt252,
        pub competency_level: u8,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CredentialVerified {
        pub token_id: u256,
        pub verifier: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CredentialRevoked {
        pub token_id: u256,
        pub revoked_by: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CredentialExtended {
        pub token_id: u256,
        pub old_expiry: u64,
        pub new_expiry: u64,
        pub timestamp: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        user_registry: ContractAddress,
        course_manager: ContractAddress,
        base_uri: ByteArray
    ) {
        self.erc721.initializer("SkillCert Credentials", "SKILLCERT", base_uri.clone());
        self.ownable.initializer(owner);
        
        self.user_registry.write(user_registry);
        self.course_manager.write(course_manager);
        self.base_uri.write(base_uri);
        self.credential_count.write(0);
    }

    // Modifiers
    fn assert_authorized_issuer(self: @ContractState) {
        let caller = get_caller_address();
        let user_registry = IUserRegistryDispatcher { contract_address: self.user_registry.read() };
        
        // Check if caller is authorized contract or admin
        let owner = self.ownable.owner();
        let is_authorized = user_registry.is_contract_authorized(caller);
        
        assert(caller == owner || is_authorized, 'Not authorized to issue credentials');
    }

    fn generate_verification_hash(
        student: ContractAddress,
        course_id: u256,
        skill: felt252,
        competency: u8,
        score: u256,
        timestamp: u64
    ) -> felt252 {
        // Simple hash generation - in production use more robust cryptographic methods
        let mut data = ArrayTrait::new();
        data.append(student.into());
        data.append(course_id.low.into());
        data.append(skill);
        data.append(competency.into());
        data.append(score.low.into());
        data.append(timestamp.into());
        
        poseidon::poseidon_hash_span(data.span())
    }

    #[abi(embed_v0)]
    impl CredentialNFTImpl of ICredentialNFT<ContractState> {
        fn issue_credential(
            ref self: ContractState,
            student_address: ContractAddress,
            course_id: u256,
            skill_achieved: felt252,
            competency_level: u8,
            assessment_score: u256,
            expiry_date: u64
        ) -> u256 {
            self.assert_authorized_issuer();
            
            // Validate inputs
            assert(competency_level >= 1 && competency_level <= 100, 'Invalid competency level');
            
            // Verify course completion
            let course_manager = ICourseManagerDispatcher { contract_address: self.course_manager.read() };
            let enrollment = course_manager.get_enrollment(student_address, course_id);
            assert(enrollment.is_completed, 'Course not completed');
            
            let token_id = self.credential_count.read() + 1;
            let timestamp = get_block_timestamp();
            
            // Generate verification hash
            let verification_hash = generate_verification_hash(
                student_address,
                course_id,
                skill_achieved,
                competency_level,
                assessment_score,
                timestamp
            );
            
            let new_credential = Credential {
                token_id: token_id,
                student_address: student_address,
                course_id: course_id,
                skill_achieved: skill_achieved,
                competency_level: competency_level,
                issue_date: timestamp,
                expiry_date: expiry_date,
                verification_hash: verification_hash,
                assessment_score: assessment_score,
                is_revoked: false,
            };
            
            // Store credential
            self.credentials.write(token_id, new_credential);
            self.credential_count.write(token_id);
            
            // Mint NFT to student (soulbound - non-transferable)
            self.erc721._mint(student_address, token_id);
            
            // Update reputation
            let user_registry = IUserRegistryDispatcher { contract_address: self.user_registry.read() };
            let reputation_boost = (competency_level.into() * 10_u256); // 10-1000 points based on competency
            user_registry.update_reputation(student_address, reputation_boost.try_into().unwrap());
            
            // Emit event
            self.emit(CredentialIssued {
                token_id: token_id,
                student_address: student_address,
                course_id: course_id,
                skill_achieved: skill_achieved,
                competency_level: competency_level,
                timestamp: timestamp,
            });
            
            token_id
        }

        fn verify_credential(self: @ContractState, token_id: u256) -> bool {
            let credential = self.credentials.read(token_id);
            assert(credential.token_id != 0, 'Credential does not exist');
            
            // Check if revoked
            if credential.is_revoked {
                return false;
            }
            
            // Check if expired
            let current_time = get_block_timestamp();
            if credential.expiry_date != 0 && current_time > credential.expiry_date {
                return false;
            }
            
            // Emit verification event
            self.emit(CredentialVerified {
                token_id: token_id,
                verifier: get_caller_address(),
                timestamp: current_time,
            });
            
            true
        }

        fn revoke_credential(ref self: ContractState, token_id: u256) -> bool {
            let caller = get_caller_address();
            let mut credential = self.credentials.read(token_id);
            assert(credential.token_id != 0, 'Credential does not exist');
            
            // Only admin, course tutor, or university can revoke
            let owner = self.ownable.owner();
            let course_manager = ICourseManagerDispatcher { contract_address: self.course_manager.read() };
            let course = course_manager.get_course(credential.course_id);
            
            assert(
                caller == owner ||
                caller == course.tutor_address ||
                caller == course.university_address,
                'Not authorized to revoke'
            );
            
            credential.is_revoked = true;
            self.credentials.write(token_id, credential);
            
            // Emit event
            self.emit(CredentialRevoked {
                token_id: token_id,
                revoked_by: caller,
                timestamp: get_block_timestamp(),
            });
            
            true
        }

        fn extend_credential(ref self: ContractState, token_id: u256, new_expiry: u64) -> bool {
            self.ownable.assert_only_owner();
            
            let mut credential = self.credentials.read(token_id);
            assert(credential.token_id != 0, 'Credential does not exist');
            assert(!credential.is_revoked, 'Credential is revoked');
            
            let old_expiry = credential.expiry_date;
            credential.expiry_date = new_expiry;
            self.credentials.write(token_id, credential);
            
            // Emit event
            self.emit(CredentialExtended {
                token_id: token_id,
                old_expiry: old_expiry,
                new_expiry: new_expiry,
                timestamp: get_block_timestamp(),
            });
            
            true
        }

        // View Functions
        fn get_credential(self: @ContractState, token_id: u256) -> Credential {
            self.credentials.read(token_id)
        }

        fn get_student_credentials(self: @ContractState, student_address: ContractAddress) -> Array<u256> {
            // Simplified implementation - in production, maintain proper indexing
            ArrayTrait::new()
        }

        fn get_course_credentials(self: @ContractState, course_id: u256) -> Array<u256> {
            // Simplified implementation - in production, maintain proper indexing
            ArrayTrait::new()
        }

        fn is_credential_valid(self: @ContractState, token_id: u256) -> bool {
            self.verify_credential(token_id)
        }

        fn get_credential_count(self: @ContractState) -> u256 {
            self.credential_count.read()
        }

        // NFT Functions
        fn balance_of(self: @ContractState, owner: ContractAddress) -> u256 {
            self.erc721.balance_of(owner)
        }

        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self.erc721.owner_of(token_id)
        }

        fn token_uri(self: @ContractState, token_id: u256) -> ByteArray {
            // Generate dynamic metadata based on credential
            let credential = self.credentials.read(token_id);
            if credential.token_id == 0 {
                return "";
            }
            
            // Return base URI + token_id for metadata endpoint
            let mut uri = self.base_uri.read();
            uri.append(@format!("{}", token_id));
            uri
        }
    }

    // Override transfer functions to make credentials soulbound (non-transferable)
    impl ERC721HooksImpl of ERC721Component::ERC721HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC721Component::ComponentState<ContractState>,
            to: ContractAddress,
            token_id: u256,
            auth: ContractAddress
        ) {
            // Allow minting (to != 0) but prevent transfers
            let current_owner = self._owner_of(token_id);
            assert(current_owner.is_zero(), 'Credentials are soulbound');
        }

        fn after_update(
            ref self: ERC721Component::ComponentState<ContractState>,
            to: ContractAddress,
            token_id: u256,
            auth: ContractAddress
        ) {
            // No additional logic needed after update
        }
    }
}
