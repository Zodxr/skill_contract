// SkillCert Smart Contract System
// Decentralized Educational Credentialing Platform
// Version: 1.0

use starknet::ContractAddress;
pub mod assessment_tracker;
pub mod course_manager;
pub mod credential_nft;

// Re-export all contract modules
pub mod user_registry;
pub use assessment_tracker::{
    IAssessmentTracker, IAssessmentTrackerDispatcher, IAssessmentTrackerDispatcherTrait,
};
pub use course_manager::{ICourseManager, ICourseManagerDispatcher, ICourseManagerDispatcherTrait};
pub use credential_nft::{ICredentialNFT, ICredentialNFTDispatcher, ICredentialNFTDispatcherTrait};

// Export public interfaces
pub use user_registry::{IUserRegistry, IUserRegistryDispatcher, IUserRegistryDispatcherTrait};

// Common data structures used across the system
#[derive(Drop, Serde, starknet::Store)]
pub struct User {
    pub address: ContractAddress,
    pub role: UserRole,
    pub reputation_score: u256,
    pub is_verified: bool,
    pub profile_hash: felt252,
    pub created_at: u64,
}

#[derive(Drop, Serde, starknet::Store, PartialEq)]
pub enum UserRole {
    Student,
    Tutor,
    University,
    Verifier,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct Course {
    pub course_id: u256,
    pub tutor_address: ContractAddress,
    pub university_address: ContractAddress,
    pub metadata_hash: felt252,
    pub skill_tags: Array<felt252>,
    pub difficulty_level: u8,
    pub estimated_duration: u64,
    pub is_active: bool,
    pub created_at: u64,
    pub enrollment_count: u256,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct Enrollment {
    pub student_address: ContractAddress,
    pub course_id: u256,
    pub enrolled_at: u64,
    pub progress_percentage: u8,
    pub completion_date: u64,
    pub final_score: u256,
    pub is_completed: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct Credential {
    pub token_id: u256,
    pub student_address: ContractAddress,
    pub course_id: u256,
    pub skill_achieved: felt252,
    pub competency_level: u8,
    pub issue_date: u64,
    pub expiry_date: u64,
    pub verification_hash: felt252,
    pub assessment_score: u256,
    pub is_revoked: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct Assessment {
    pub assessment_id: u256,
    pub student_address: ContractAddress,
    pub course_id: u256,
    pub assessment_type: felt252,
    pub score: u256,
    pub max_score: u256,
    pub completed_at: u64,
    pub time_taken: u64,
}
