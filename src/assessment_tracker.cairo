// AssessmentTracker Contract
// Records assessments and learning analytics

use starknet::ContractAddress;
use super::Assessment;

#[starknet::interface]
pub trait IAssessmentTracker<TContractState> {
    // Assessment Management Functions
    fn record_assessment(
        ref self: TContractState,
        student_address: ContractAddress,
        course_id: u256,
        assessment_type: felt252,
        score: u256,
        max_score: u256,
        time_taken: u64,
    ) -> u256;

    fn track_interaction(
        ref self: TContractState,
        student_address: ContractAddress,
        course_id: u256,
        interaction_type: felt252,
        interaction_data: felt252,
    ) -> bool;

    fn calculate_competency(
        ref self: TContractState, student_address: ContractAddress, skill: felt252,
    ) -> u8;

    // View Functions
    fn get_assessment(self: @TContractState, assessment_id: u256) -> Assessment;
    fn get_student_assessments(
        self: @TContractState, student_address: ContractAddress,
    ) -> Array<u256>;
    fn get_course_assessments(self: @TContractState, course_id: u256) -> Array<u256>;
    fn get_competency_score(
        self: @TContractState, student_address: ContractAddress, skill: felt252,
    ) -> u8;
    fn get_assessment_count(self: @TContractState) -> u256;
    fn get_student_analytics(
        self: @TContractState, student_address: ContractAddress,
    ) -> (u256, u256, u64); // total_assessments, avg_score, total_time
}

#[starknet::contract]
pub mod AssessmentTracker {
    use core::starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use skill_contract::course_manager::{ICourseManagerDispatcher, ICourseManagerDispatcherTrait};
    use skill_contract::user_registry::{IUserRegistryDispatcher, IUserRegistryDispatcherTrait};
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use super::{Assessment, IAssessmentTracker};

    #[derive(Drop, Serde, starknet::Store)]
    struct LearningInteraction {
        student_address: ContractAddress,
        course_id: u256,
        interaction_type: felt252,
        interaction_data: felt252,
        timestamp: u64,
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct StudentAnalytics {
        total_assessments: u256,
        total_score: u256,
        total_time: u64,
        last_activity: u64,
    }

    #[storage]
    struct Storage {
        // Core assessment data
        assessments: Map<u256, Assessment>,
        assessment_count: u256,
        // Assessment tracking
        student_assessments: Map<ContractAddress, Array<u256>>,
        course_assessments: Map<u256, Array<u256>>,
        // Competency scoring
        competency_scores: Map<(ContractAddress, felt252), u8>,
        skill_assessments: Map<(ContractAddress, felt252), Array<u256>>,
        // Learning interactions
        interactions: Map<u256, LearningInteraction>,
        interaction_count: u256,
        // Analytics
        student_analytics: Map<ContractAddress, StudentAnalytics>,
        // External contracts
        user_registry: ContractAddress,
        course_manager: ContractAddress,
        // Access control
        admin: ContractAddress,
        authorized_assessors: Map<ContractAddress, bool>,
        is_paused: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        AssessmentRecorded: AssessmentRecorded,
        InteractionTracked: InteractionTracked,
        CompetencyUpdated: CompetencyUpdated,
        AssessorAuthorized: AssessorAuthorized,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssessmentRecorded {
        pub assessment_id: u256,
        pub student_address: ContractAddress,
        pub course_id: u256,
        pub assessment_type: felt252,
        pub score: u256,
        pub max_score: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct InteractionTracked {
        pub student_address: ContractAddress,
        pub course_id: u256,
        pub interaction_type: felt252,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CompetencyUpdated {
        pub student_address: ContractAddress,
        pub skill: felt252,
        pub old_score: u8,
        pub new_score: u8,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AssessorAuthorized {
        pub assessor_address: ContractAddress,
        pub authorized_by: ContractAddress,
        pub timestamp: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        user_registry: ContractAddress,
        course_manager: ContractAddress,
    ) {
        self.admin.write(admin);
        self.user_registry.write(user_registry);
        self.course_manager.write(course_manager);
        self.assessment_count.write(0);
        self.interaction_count.write(0);
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

    fn assert_authorized_assessor(self: @ContractState, course_id: u256) {
        let caller = get_caller_address();
        let admin = self.admin.read();
        let is_authorized = self.authorized_assessors.read(caller);

        // Get course tutor
        let course_manager = ICourseManagerDispatcher {
            contract_address: self.course_manager.read(),
        };
        let course = course_manager.get_course(course_id);

        assert(
            caller == admin
                || is_authorized
                || caller == course.tutor_address
                || caller == course.university_address,
            'Not authorized to record assessments',
        );
    }

    fn calculate_percentage(score: u256, max_score: u256) -> u8 {
        if max_score == 0 {
            return 0;
        }
        let percentage = (score * 100) / max_score;
        if percentage > 100 {
            100
        } else {
            percentage.try_into().unwrap()
        }
    }

    #[abi(embed_v0)]
    impl AssessmentTrackerImpl of IAssessmentTracker<ContractState> {
        fn record_assessment(
            ref self: ContractState,
            student_address: ContractAddress,
            course_id: u256,
            assessment_type: felt252,
            score: u256,
            max_score: u256,
            time_taken: u64,
        ) -> u256 {
            self.assert_not_paused();
            self.assert_authorized_assessor(course_id);

            // Validate inputs
            assert(max_score > 0, 'Max score must be positive');
            assert(score <= max_score, 'Score cannot exceed max score');

            // Verify student is enrolled in course
            let course_manager = ICourseManagerDispatcher {
                contract_address: self.course_manager.read(),
            };
            assert(
                course_manager.is_student_enrolled(student_address, course_id),
                'Student not enrolled in course',
            );

            let assessment_id = self.assessment_count.read() + 1;
            let timestamp = get_block_timestamp();

            let new_assessment = Assessment {
                assessment_id: assessment_id,
                student_address: student_address,
                course_id: course_id,
                assessment_type: assessment_type,
                score: score,
                max_score: max_score,
                completed_at: timestamp,
                time_taken: time_taken,
            };

            // Store assessment
            self.assessments.write(assessment_id, new_assessment);
            self.assessment_count.write(assessment_id);

            // Update student analytics
            let mut analytics = self.student_analytics.read(student_address);
            analytics.total_assessments += 1;
            analytics.total_score += score;
            analytics.total_time += time_taken;
            analytics.last_activity = timestamp;
            self.student_analytics.write(student_address, analytics);

            // Update progress in course manager
            let enrollment = course_manager.get_enrollment(student_address, course_id);
            if !enrollment.is_completed {
                // Calculate new progress based on assessment completion
                let new_progress = if enrollment.progress_percentage < 90 {
                    enrollment.progress_percentage + 10 // Simple progress increment
                } else {
                    enrollment.progress_percentage
                };

                course_manager.update_progress(student_address, course_id, new_progress);
            }

            // Emit event
            self
                .emit(
                    AssessmentRecorded {
                        assessment_id: assessment_id,
                        student_address: student_address,
                        course_id: course_id,
                        assessment_type: assessment_type,
                        score: score,
                        max_score: max_score,
                        timestamp: timestamp,
                    },
                );

            assessment_id
        }

        fn track_interaction(
            ref self: ContractState,
            student_address: ContractAddress,
            course_id: u256,
            interaction_type: felt252,
            interaction_data: felt252,
        ) -> bool {
            self.assert_not_paused();

            // Verify student is enrolled
            let course_manager = ICourseManagerDispatcher {
                contract_address: self.course_manager.read(),
            };
            assert(
                course_manager.is_student_enrolled(student_address, course_id),
                'Student not enrolled in course',
            );

            let interaction_id = self.interaction_count.read() + 1;
            let timestamp = get_block_timestamp();

            let new_interaction = LearningInteraction {
                student_address: student_address,
                course_id: course_id,
                interaction_type: interaction_type,
                interaction_data: interaction_data,
                timestamp: timestamp,
            };

            self.interactions.write(interaction_id, new_interaction);
            self.interaction_count.write(interaction_id);

            // Update last activity
            let mut analytics = self.student_analytics.read(student_address);
            analytics.last_activity = timestamp;
            self.student_analytics.write(student_address, analytics);

            // Emit event
            self
                .emit(
                    InteractionTracked {
                        student_address: student_address,
                        course_id: course_id,
                        interaction_type: interaction_type,
                        timestamp: timestamp,
                    },
                );

            true
        }

        fn calculate_competency(
            ref self: ContractState, student_address: ContractAddress, skill: felt252,
        ) -> u8 {
            self.assert_not_paused();

            // Get all assessments for this skill (simplified calculation)
            // In production, implement more sophisticated competency algorithms

            let current_competency = self.competency_scores.read((student_address, skill));

            // Simple competency calculation based on recent assessment performance
            // This is a placeholder - implement proper competency algorithms
            let analytics = self.student_analytics.read(student_address);

            let new_competency = if analytics.total_assessments > 0 {
                let avg_score = analytics.total_score / analytics.total_assessments;
                calculate_percentage(avg_score, 100_u256) // Assuming 100 is standard max
            } else {
                0
            };

            // Only update if competency changed
            if new_competency != current_competency {
                self.competency_scores.write((student_address, skill), new_competency);

                self
                    .emit(
                        CompetencyUpdated {
                            student_address: student_address,
                            skill: skill,
                            old_score: current_competency,
                            new_score: new_competency,
                            timestamp: get_block_timestamp(),
                        },
                    );
            }

            new_competency
        }

        // View Functions
        fn get_assessment(self: @ContractState, assessment_id: u256) -> Assessment {
            self.assessments.read(assessment_id)
        }

        fn get_student_assessments(
            self: @ContractState, student_address: ContractAddress,
        ) -> Array<u256> {
            // Simplified implementation - in production, maintain proper indexing
            ArrayTrait::new()
        }

        fn get_course_assessments(self: @ContractState, course_id: u256) -> Array<u256> {
            // Simplified implementation - in production, maintain proper indexing
            ArrayTrait::new()
        }

        fn get_competency_score(
            self: @ContractState, student_address: ContractAddress, skill: felt252,
        ) -> u8 {
            self.competency_scores.read((student_address, skill))
        }

        fn get_assessment_count(self: @ContractState) -> u256 {
            self.assessment_count.read()
        }

        fn get_student_analytics(
            self: @ContractState, student_address: ContractAddress,
        ) -> (u256, u256, u64) {
            let analytics = self.student_analytics.read(student_address);
            let avg_score = if analytics.total_assessments > 0 {
                analytics.total_score / analytics.total_assessments
            } else {
                0
            };
            (analytics.total_assessments, avg_score, analytics.total_time)
        }
    }

    // Admin functions
    #[generate_trait]
    impl AdminImpl of AdminTrait {
        fn authorize_assessor(ref self: ContractState, assessor_address: ContractAddress) {
            self.assert_only_admin();

            self.authorized_assessors.write(assessor_address, true);

            self
                .emit(
                    AssessorAuthorized {
                        assessor_address: assessor_address,
                        authorized_by: get_caller_address(),
                        timestamp: get_block_timestamp(),
                    },
                );
        }

        fn revoke_assessor(ref self: ContractState, assessor_address: ContractAddress) {
            self.assert_only_admin();
            self.authorized_assessors.write(assessor_address, false);
        }

        fn pause(ref self: ContractState) {
            self.assert_only_admin();
            self.is_paused.write(true);
        }

        fn unpause(ref self: ContractState) {
            self.assert_only_admin();
            self.is_paused.write(false);
        }
    }
}
