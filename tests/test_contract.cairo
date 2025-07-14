use skill_contract::{
    IAssessmentTrackerDispatcher, IAssessmentTrackerDispatcherTrait, ICourseManagerDispatcher,
    ICourseManagerDispatcherTrait, ICredentialNFTDispatcher, ICredentialNFTDispatcherTrait,
    IUserRegistryDispatcher, IUserRegistryDispatcherTrait, UserRole,
};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::ContractAddress;

fn deploy_user_registry(admin: ContractAddress) -> ContractAddress {
    let contract = declare("UserRegistry").unwrap().contract_class();
    let constructor_args = array![admin.into()];
    let (contract_address, _) = contract.deploy(@constructor_args).unwrap();
    contract_address
}

fn deploy_course_manager(
    admin: ContractAddress, user_registry: ContractAddress,
) -> ContractAddress {
    let contract = declare("CourseManager").unwrap().contract_class();
    let constructor_args = array![admin.into(), user_registry.into()];
    let (contract_address, _) = contract.deploy(@constructor_args).unwrap();
    contract_address
}

fn deploy_assessment_tracker(
    admin: ContractAddress, user_registry: ContractAddress, course_manager: ContractAddress,
) -> ContractAddress {
    let contract = declare("AssessmentTracker").unwrap().contract_class();
    let constructor_args = array![admin.into(), user_registry.into(), course_manager.into()];
    let (contract_address, _) = contract.deploy(@constructor_args).unwrap();
    contract_address
}

#[test]
fn test_user_registration() {
    let admin: ContractAddress = starknet::contract_address_const::<0x123>();
    let student: ContractAddress = starknet::contract_address_const::<0x456>();

    let user_registry_address = deploy_user_registry(admin);
    let user_registry = IUserRegistryDispatcher { contract_address: user_registry_address };

    // Test student registration
    start_cheat_caller_address(user_registry_address, student);
    let success = user_registry.register_user(UserRole::Student, 'profile_hash');
    assert(success, 'Registration should succeed');
    stop_cheat_caller_address(user_registry_address);

    // Verify user data
    let user = user_registry.get_user(student);
    assert(user.address == student, 'Wrong user address');
    assert(user.role == UserRole::Student, 'Wrong user role');
    assert(user.reputation_score == 100, 'Wrong initial reputation');
    assert(!user.is_verified, 'User should not be verified initially');

    // Test admin verification
    start_cheat_caller_address(user_registry_address, admin);
    let verified = user_registry.verify_user(student);
    assert(verified, 'Verification should succeed');
    stop_cheat_caller_address(user_registry_address);

    // Check verification status
    let is_verified = user_registry.is_user_verified(student);
    assert(is_verified, 'User should be verified');
}

#[test]
fn test_tutor_registration_and_course_creation() {
    let admin: ContractAddress = starknet::contract_address_const::<0x123>();
    let tutor: ContractAddress = starknet::contract_address_const::<0x789>();
    let university: ContractAddress = starknet::contract_address_const::<0xabc>();

    let user_registry_address = deploy_user_registry(admin);
    let user_registry = IUserRegistryDispatcher { contract_address: user_registry_address };

    let course_manager_address = deploy_course_manager(admin, user_registry_address);
    let course_manager = ICourseManagerDispatcher { contract_address: course_manager_address };

    // Register and verify tutor
    start_cheat_caller_address(user_registry_address, tutor);
    user_registry.register_user(UserRole::Tutor, 'tutor_profile');
    stop_cheat_caller_address(user_registry_address);

    start_cheat_caller_address(user_registry_address, admin);
    user_registry.verify_user(tutor);
    stop_cheat_caller_address(user_registry_address);

    // Register university
    start_cheat_caller_address(user_registry_address, university);
    user_registry.register_user(UserRole::University, 'university_profile');
    stop_cheat_caller_address(user_registry_address);

    start_cheat_caller_address(user_registry_address, admin);
    user_registry.verify_user(university);
    stop_cheat_caller_address(user_registry_address);

    // Create course
    start_cheat_caller_address(course_manager_address, tutor);
    let skill_tags = array!['blockchain', 'cairo'];
    let course_id = course_manager
        .create_course(
            'course_metadata_hash',
            skill_tags,
            5, // difficulty level
            40, // estimated duration
            university // university endorsement
        );
    stop_cheat_caller_address(course_manager_address);

    assert(course_id == 1, 'Course ID should be 1');

    // Verify course data
    let course = course_manager.get_course(course_id);
    assert(course.course_id == 1, 'Wrong course ID');
    assert(course.tutor_address == tutor, 'Wrong tutor address');
    assert(course.difficulty_level == 5, 'Wrong difficulty level');
    assert(course.is_active, 'Course should be active');
}

#[test]
fn test_student_enrollment_and_assessment() {
    let admin: ContractAddress = starknet::contract_address_const::<0x123>();
    let tutor: ContractAddress = starknet::contract_address_const::<0x789>();
    let student: ContractAddress = starknet::contract_address_const::<0x456>();
    let university: ContractAddress = starknet::contract_address_const::<0xabc>();

    // Deploy contracts
    let user_registry_address = deploy_user_registry(admin);
    let user_registry = IUserRegistryDispatcher { contract_address: user_registry_address };

    let course_manager_address = deploy_course_manager(admin, user_registry_address);
    let course_manager = ICourseManagerDispatcher { contract_address: course_manager_address };

    let assessment_tracker_address = deploy_assessment_tracker(
        admin, user_registry_address, course_manager_address,
    );
    let assessment_tracker = IAssessmentTrackerDispatcher {
        contract_address: assessment_tracker_address,
    };

    // Register users
    start_cheat_caller_address(user_registry_address, tutor);
    user_registry.register_user(UserRole::Tutor, 'tutor_profile');
    stop_cheat_caller_address(user_registry_address);

    start_cheat_caller_address(user_registry_address, student);
    user_registry.register_user(UserRole::Student, 'student_profile');
    stop_cheat_caller_address(user_registry_address);

    start_cheat_caller_address(user_registry_address, university);
    user_registry.register_user(UserRole::University, 'university_profile');
    stop_cheat_caller_address(user_registry_address);

    // Verify users
    start_cheat_caller_address(user_registry_address, admin);
    user_registry.verify_user(tutor);
    user_registry.verify_user(student);
    user_registry.verify_user(university);
    stop_cheat_caller_address(user_registry_address);

    // Create course
    start_cheat_caller_address(course_manager_address, tutor);
    let skill_tags = array!['programming', 'cairo'];
    let course_id = course_manager.create_course('course_metadata', skill_tags, 3, 20, university);
    stop_cheat_caller_address(course_manager_address);

    // Student enrolls
    start_cheat_caller_address(course_manager_address, student);
    let enrolled = course_manager.enroll_student(course_id);
    assert(enrolled, 'Enrollment should succeed');
    stop_cheat_caller_address(course_manager_address);

    // Verify enrollment
    let enrollment = course_manager.get_enrollment(student, course_id);
    assert(enrollment.student_address == student, 'Wrong student address');
    assert(enrollment.course_id == course_id, 'Wrong course ID');
    assert(!enrollment.is_completed, 'Course should not be completed yet');

    // Record assessment
    start_cheat_caller_address(assessment_tracker_address, tutor);
    let assessment_id = assessment_tracker
        .record_assessment(
            student, course_id, 'quiz', 85, // score
            100, // max score
            3600 // time taken (1 hour)
        );
    stop_cheat_caller_address(assessment_tracker_address);

    assert(assessment_id == 1, 'Assessment ID should be 1');

    // Verify assessment
    let assessment = assessment_tracker.get_assessment(assessment_id);
    assert(assessment.student_address == student, 'Wrong student in assessment');
    assert(assessment.score == 85, 'Wrong assessment score');
    assert(assessment.max_score == 100, 'Wrong max score');
}

#[test]
fn test_course_completion() {
    let admin: ContractAddress = starknet::contract_address_const::<0x123>();
    let tutor: ContractAddress = starknet::contract_address_const::<0x789>();
    let student: ContractAddress = starknet::contract_address_const::<0x456>();
    let university: ContractAddress = starknet::contract_address_const::<0xabc>();

    // Deploy and setup contracts (similar to previous test)
    let user_registry_address = deploy_user_registry(admin);
    let user_registry = IUserRegistryDispatcher { contract_address: user_registry_address };

    let course_manager_address = deploy_course_manager(admin, user_registry_address);
    let course_manager = ICourseManagerDispatcher { contract_address: course_manager_address };

    // Register and verify users
    start_cheat_caller_address(user_registry_address, tutor);
    user_registry.register_user(UserRole::Tutor, 'tutor_profile');
    stop_cheat_caller_address(user_registry_address);

    start_cheat_caller_address(user_registry_address, student);
    user_registry.register_user(UserRole::Student, 'student_profile');
    stop_cheat_caller_address(user_registry_address);

    start_cheat_caller_address(user_registry_address, university);
    user_registry.register_user(UserRole::University, 'university_profile');
    stop_cheat_caller_address(user_registry_address);

    start_cheat_caller_address(user_registry_address, admin);
    user_registry.verify_user(tutor);
    user_registry.verify_user(student);
    user_registry.verify_user(university);
    stop_cheat_caller_address(user_registry_address);

    // Create course and enroll student
    start_cheat_caller_address(course_manager_address, tutor);
    let skill_tags = array!['smart_contracts'];
    let course_id = course_manager.create_course('advanced_course', skill_tags, 8, 60, university);
    stop_cheat_caller_address(course_manager_address);

    start_cheat_caller_address(course_manager_address, student);
    course_manager.enroll_student(course_id);
    stop_cheat_caller_address(course_manager_address);

    // Complete course
    start_cheat_caller_address(course_manager_address, tutor);
    let completed = course_manager.complete_course(student, course_id, 92);
    assert(completed, 'Course completion should succeed');
    stop_cheat_caller_address(course_manager_address);

    // Verify completion
    let enrollment = course_manager.get_enrollment(student, course_id);
    assert(enrollment.is_completed, 'Course should be completed');
    assert(enrollment.final_score == 92, 'Wrong final score');
    assert(enrollment.progress_percentage == 100, 'Progress should be 100%');
}
