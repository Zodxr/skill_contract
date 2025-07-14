// CourseManager Contract
// Handles course creation, enrollment, and progress tracking

use starknet::ContractAddress;
use super::{Course, Enrollment, UserRole};

#[starknet::interface]
pub trait ICourseManager<TContractState> {
    // Course Management Functions
    fn create_course(
        ref self: TContractState,
        metadata_hash: felt252,
        skill_tags: Array<felt252>,
        difficulty_level: u8,
        estimated_duration: u64,
        university_endorsement: ContractAddress,
    ) -> u256;

    fn endorse_course(ref self: TContractState, course_id: u256) -> bool;
    fn deactivate_course(ref self: TContractState, course_id: u256) -> bool;

    // Enrollment Functions
    fn enroll_student(ref self: TContractState, course_id: u256) -> bool;
    fn update_progress(
        ref self: TContractState, student_address: ContractAddress, course_id: u256, progress: u8,
    ) -> bool;
    fn complete_course(
        ref self: TContractState,
        student_address: ContractAddress,
        course_id: u256,
        final_score: u256,
    ) -> bool;

    // View Functions
    fn get_course(self: @TContractState, course_id: u256) -> Course;
    fn get_enrollment(
        self: @TContractState, student_address: ContractAddress, course_id: u256,
    ) -> Enrollment;
    fn get_course_count(self: @TContractState) -> u256;
    fn get_student_courses(self: @TContractState, student_address: ContractAddress) -> Array<u256>;
    fn get_course_enrollments(self: @TContractState, course_id: u256) -> Array<ContractAddress>;
    fn is_student_enrolled(
        self: @TContractState, student_address: ContractAddress, course_id: u256,
    ) -> bool;
}

#[starknet::contract]
pub mod CourseManager {
    use core::starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use skill_contract::user_registry::{IUserRegistryDispatcher, IUserRegistryDispatcherTrait};
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
    use super::{Course, Enrollment, ICourseManager, UserRole};

    #[storage]
    struct Storage {
        // Core course data
        courses: Map<u256, Course>,
        course_count: u256,
        // Enrollment tracking
        enrollments: Map<(ContractAddress, u256), Enrollment>,
        course_enrollments: Map<u256, Array<ContractAddress>>,
        student_courses: Map<ContractAddress, Array<u256>>,
        // External contracts
        user_registry: ContractAddress,
        // Access control
        admin: ContractAddress,
        is_paused: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        CourseCreated: CourseCreated,
        CourseEndorsed: CourseEndorsed,
        CourseDeactivated: CourseDeactivated,
        StudentEnrolled: StudentEnrolled,
        ProgressUpdated: ProgressUpdated,
        CourseCompleted: CourseCompleted,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CourseCreated {
        pub course_id: u256,
        pub tutor_address: ContractAddress,
        pub metadata_hash: felt252,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CourseEndorsed {
        pub course_id: u256,
        pub university_address: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CourseDeactivated {
        pub course_id: u256,
        pub deactivated_by: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct StudentEnrolled {
        pub student_address: ContractAddress,
        pub course_id: u256,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProgressUpdated {
        pub student_address: ContractAddress,
        pub course_id: u256,
        pub progress_percentage: u8,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CourseCompleted {
        pub student_address: ContractAddress,
        pub course_id: u256,
        pub final_score: u256,
        pub timestamp: u64,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, admin: ContractAddress, user_registry: ContractAddress,
    ) {
        self.admin.write(admin);
        self.user_registry.write(user_registry);
        self.course_count.write(0);
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

    fn assert_user_verified(self: @ContractState, user_address: ContractAddress) {
        let user_registry = IUserRegistryDispatcher { contract_address: self.user_registry.read() };
        assert(user_registry.is_user_verified(user_address), 'User not verified');
    }

    fn assert_user_role(
        self: @ContractState, user_address: ContractAddress, expected_role: UserRole,
    ) {
        let user_registry = IUserRegistryDispatcher { contract_address: self.user_registry.read() };
        let user_role = user_registry.get_user_role(user_address);
        assert(user_role == expected_role, 'Invalid user role');
    }

    #[abi(embed_v0)]
    impl CourseManagerImpl of ICourseManager<ContractState> {
        fn create_course(
            ref self: ContractState,
            metadata_hash: felt252,
            skill_tags: Array<felt252>,
            difficulty_level: u8,
            estimated_duration: u64,
            university_endorsement: ContractAddress,
        ) -> u256 {
            self.assert_not_paused();
            let caller = get_caller_address();

            // Verify tutor is verified and has correct role
            self.assert_user_verified(caller);
            self.assert_user_role(caller, UserRole::Tutor);

            // Validate inputs
            assert(difficulty_level >= 1 && difficulty_level <= 10, 'Invalid difficulty level');
            assert(estimated_duration > 0, 'Duration must be positive');

            let course_id = self.course_count.read() + 1;
            let timestamp = get_block_timestamp();

            let new_course = Course {
                course_id: course_id,
                tutor_address: caller,
                university_address: university_endorsement,
                metadata_hash: metadata_hash,
                skill_tags: skill_tags,
                difficulty_level: difficulty_level,
                estimated_duration: estimated_duration,
                is_active: true,
                created_at: timestamp,
                enrollment_count: 0,
            };

            // Store course
            self.courses.write(course_id, new_course);
            self.course_count.write(course_id);

            // Emit event
            self
                .emit(
                    CourseCreated {
                        course_id: course_id,
                        tutor_address: caller,
                        metadata_hash: metadata_hash,
                        timestamp: timestamp,
                    },
                );

            course_id
        }

        fn endorse_course(ref self: ContractState, course_id: u256) -> bool {
            self.assert_not_paused();
            let caller = get_caller_address();

            // Verify university role
            self.assert_user_verified(caller);
            self.assert_user_role(caller, UserRole::University);

            let mut course = self.courses.read(course_id);
            assert(course.course_id != 0, 'Course does not exist');
            assert(course.is_active, 'Course is not active');

            // Update university endorsement
            course.university_address = caller;
            self.courses.write(course_id, course);

            // Emit event
            self
                .emit(
                    CourseEndorsed {
                        course_id: course_id,
                        university_address: caller,
                        timestamp: get_block_timestamp(),
                    },
                );

            true
        }

        fn deactivate_course(ref self: ContractState, course_id: u256) -> bool {
            let caller = get_caller_address();
            let mut course = self.courses.read(course_id);

            assert(course.course_id != 0, 'Course does not exist');

            // Only tutor, university, or admin can deactivate
            let admin = self.admin.read();
            assert(
                caller == course.tutor_address
                    || caller == course.university_address
                    || caller == admin,
                'Not authorized to deactivate',
            );

            course.is_active = false;
            self.courses.write(course_id, course);

            // Emit event
            self
                .emit(
                    CourseDeactivated {
                        course_id: course_id,
                        deactivated_by: caller,
                        timestamp: get_block_timestamp(),
                    },
                );

            true
        }

        fn enroll_student(ref self: ContractState, course_id: u256) -> bool {
            self.assert_not_paused();
            let caller = get_caller_address();

            // Verify student is verified and has correct role
            self.assert_user_verified(caller);
            self.assert_user_role(caller, UserRole::Student);

            let course = self.courses.read(course_id);
            assert(course.course_id != 0, 'Course does not exist');
            assert(course.is_active, 'Course is not active');

            // Check if already enrolled
            let existing_enrollment = self.enrollments.read((caller, course_id));
            assert(existing_enrollment.student_address.is_zero(), 'Already enrolled');

            let timestamp = get_block_timestamp();

            let new_enrollment = Enrollment {
                student_address: caller,
                course_id: course_id,
                enrolled_at: timestamp,
                progress_percentage: 0,
                completion_date: 0,
                final_score: 0,
                is_completed: false,
            };

            // Store enrollment
            self.enrollments.write((caller, course_id), new_enrollment);

            // Update course enrollment count
            let mut updated_course = course;
            updated_course.enrollment_count += 1;
            self.courses.write(course_id, updated_course);

            // Update tracking arrays (simplified for basic implementation)
            // Note: In a production system, you'd implement proper array management

            // Emit event
            self
                .emit(
                    StudentEnrolled {
                        student_address: caller, course_id: course_id, timestamp: timestamp,
                    },
                );

            true
        }

        fn update_progress(
            ref self: ContractState,
            student_address: ContractAddress,
            course_id: u256,
            progress: u8,
        ) -> bool {
            let caller = get_caller_address();
            let course = self.courses.read(course_id);

            // Only tutor or admin can update progress
            let admin = self.admin.read();
            assert(
                caller == course.tutor_address || caller == admin,
                'Not authorized to update progress',
            );

            assert(progress <= 100, 'Progress cannot exceed 100%');

            let mut enrollment = self.enrollments.read((student_address, course_id));
            assert(!enrollment.student_address.is_zero(), 'Student not enrolled');
            assert(!enrollment.is_completed, 'Course already completed');

            enrollment.progress_percentage = progress;
            self.enrollments.write((student_address, course_id), enrollment);

            // Emit event
            self
                .emit(
                    ProgressUpdated {
                        student_address: student_address,
                        course_id: course_id,
                        progress_percentage: progress,
                        timestamp: get_block_timestamp(),
                    },
                );

            true
        }

        fn complete_course(
            ref self: ContractState,
            student_address: ContractAddress,
            course_id: u256,
            final_score: u256,
        ) -> bool {
            let caller = get_caller_address();
            let course = self.courses.read(course_id);

            // Only tutor or admin can mark completion
            let admin = self.admin.read();
            assert(
                caller == course.tutor_address || caller == admin,
                'Not authorized to complete course',
            );

            let mut enrollment = self.enrollments.read((student_address, course_id));
            assert(!enrollment.student_address.is_zero(), 'Student not enrolled');
            assert(!enrollment.is_completed, 'Course already completed');

            let timestamp = get_block_timestamp();

            enrollment.is_completed = true;
            enrollment.completion_date = timestamp;
            enrollment.final_score = final_score;
            enrollment.progress_percentage = 100;

            self.enrollments.write((student_address, course_id), enrollment);

            // Emit event
            self
                .emit(
                    CourseCompleted {
                        student_address: student_address,
                        course_id: course_id,
                        final_score: final_score,
                        timestamp: timestamp,
                    },
                );

            true
        }

        // View Functions
        fn get_course(self: @ContractState, course_id: u256) -> Course {
            self.courses.read(course_id)
        }

        fn get_enrollment(
            self: @ContractState, student_address: ContractAddress, course_id: u256,
        ) -> Enrollment {
            self.enrollments.read((student_address, course_id))
        }

        fn get_course_count(self: @ContractState) -> u256 {
            self.course_count.read()
        }

        fn get_student_courses(
            self: @ContractState, student_address: ContractAddress,
        ) -> Array<u256> {
            // Simplified implementation - in production, maintain proper indexing
            ArrayTrait::new()
        }

        fn get_course_enrollments(self: @ContractState, course_id: u256) -> Array<ContractAddress> {
            // Simplified implementation - in production, maintain proper indexing
            ArrayTrait::new()
        }

        fn is_student_enrolled(
            self: @ContractState, student_address: ContractAddress, course_id: u256,
        ) -> bool {
            let enrollment = self.enrollments.read((student_address, course_id));
            !enrollment.student_address.is_zero()
        }
    }
}
