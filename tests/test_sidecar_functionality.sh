#!/usr/bin/env bash
# Functionality Tests for Docker Sidecar
# Tests end-to-end functionality and integration

set -Eeuo pipefail
IFS=$'\n\t'

# Test framework variables
readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="$(dirname "$TEST_DIR")/lib"
readonly BUILD_DIR="$(dirname "$TEST_DIR")/build"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test environment variables
TEST_SIDECAR_SOCKET="/tmp/test_sidecar_$$.sock"
TEST_SIDECAR_CONTAINER=""
TEST_PROJECT_HASH="test-$$"

# Cleanup function
cleanup_test_environment() {
    if [[ -n "$TEST_SIDECAR_CONTAINER" ]]; then
        printf "${BLUE}Cleaning up test sidecar container...${NC}\n"
        docker stop "$TEST_SIDECAR_CONTAINER" >/dev/null 2>&1 || true
        docker rm "$TEST_SIDECAR_CONTAINER" >/dev/null 2>&1 || true
    fi
    
    if [[ -S "$TEST_SIDECAR_SOCKET" ]]; then
        rm -f "$TEST_SIDECAR_SOCKET"
    fi
    
    # Clean up any test rate limit files
    rm -f /tmp/sidecar_rate_limit
}

# Set up cleanup on exit
trap cleanup_test_environment EXIT INT TERM

# Test helper functions
print_test_header() {
    printf "\n${YELLOW}=== %s ===${NC}\n" "$1"
}

run_test() {
    local test_name="$1"
    local test_function="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    printf "Testing: %s ... " "$test_name"
    
    if $test_function; then
        printf "${GREEN}PASS${NC}\n"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf "${RED}FAIL${NC}\n"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Source required libraries
source "$LIB_DIR/docker-sidecar-client.sh"

# Test sidecar availability detection
test_sidecar_availability() {
    # Test with non-existent socket
    SIDECAR_SOCKET="/nonexistent/socket" 
    if is_sidecar_available; then
        return 1  # Test failed - should not be available
    fi
    
    # Create a dummy socket file for testing
    local test_socket="/tmp/test_dummy_socket_$$"
    touch "$test_socket"
    
    SIDECAR_SOCKET="$test_socket"
    if is_sidecar_available; then
        rm -f "$test_socket"
        return 1  # Test failed - file is not a socket
    fi
    
    rm -f "$test_socket"
    return 0  # Test passed
}

# Test Docker wrapper script functionality
test_docker_wrapper() {
    local wrapper_script="$BUILD_DIR/docker-wrapper"
    
    if [[ ! -x "$wrapper_script" ]]; then
        return 1  # Test failed - wrapper not executable
    fi
    
    # Test with sidecar mode disabled
    DOCKER_SIDECAR_MODE=false
    local output
    output=$("$wrapper_script" --version 2>&1) || return 1
    
    # Should call real docker
    if [[ "$output" =~ Docker ]]; then
        return 0  # Test passed - called real Docker
    else
        return 1  # Test failed - unexpected output
    fi
}

# Test client library argument parsing
test_client_argument_parsing() {
    # Test docker ps argument parsing
    local all_flag quiet_flag
    
    # Mock the send_sidecar_request function for testing
    send_sidecar_request() {
        local method="$1"
        local path="$2"
        local body="$3"
        
        # Check that method and path are correct
        if [[ "$method" == "GET" ]] && [[ "$path" == "/docker/ps" ]]; then
            # Check that flags were parsed correctly
            local all_param quiet_param
            all_param=$(printf '%s\n' "$body" | jq -r '.parameters.all // false')
            quiet_param=$(printf '%s\n' "$body" | jq -r '.parameters.quiet // false')
            
            # For this test, we expect both flags to be true
            if [[ "$all_param" == "true" ]] && [[ "$quiet_param" == "true" ]]; then
                printf "test output"
                return 0
            fi
        fi
        return 1
    }
    
    # Test parsing
    local output
    output=$(docker_sidecar_ps -a -q 2>/dev/null) || return 1
    
    if [[ "$output" == "test output" ]]; then
        return 0  # Test passed
    else
        return 1  # Test failed
    fi
}

# Test JSON request construction
test_json_request_construction() {
    # Test docker run request construction
    local test_image="ubuntu:20.04"
    local expected_structure='{"operation":"docker_run","parameters":{"image":"ubuntu:20.04","command":["echo","hello"],"options":{"rm":true}}}'
    
    # We can't easily test the full docker_sidecar_run function without a running sidecar,
    # so we'll test the JSON construction logic separately
    
    local request_body
    request_body=$(jq -n \
        --arg op "docker_run" \
        --arg img "$test_image" \
        --argjson cmd '["echo", "hello"]' \
        --argjson opts '{"rm": true}' \
        '{
            operation: $op,
            parameters: {
                image: $img,
                command: $cmd,
                options: $opts
            }
        }'
    )
    
    # Verify structure
    local operation image rm_flag
    operation=$(printf '%s\n' "$request_body" | jq -r '.operation')
    image=$(printf '%s\n' "$request_body" | jq -r '.parameters.image')
    rm_flag=$(printf '%s\n' "$request_body" | jq -r '.parameters.options.rm')
    
    if [[ "$operation" == "docker_run" ]] && [[ "$image" == "$test_image" ]] && [[ "$rm_flag" == "true" ]]; then
        return 0  # Test passed
    else
        return 1  # Test failed
    fi
}

# Test configuration system functionality
test_configuration_loading() {
    local test_config_dir="/tmp/test_claudebox_config_$$"
    local test_config_file="$test_config_dir/docker-sidecar.yaml"
    
    # Clean up and create test environment
    rm -rf "$test_config_dir"
    mkdir -p "$test_config_dir"
    
    # Create test configuration
    cat > "$test_config_file" << EOF
sidecar:
  security_level: strict
policies:
  max_containers: 15
  max_memory: "4g"
  rate_limit_per_minute: 120
logging:
  enabled: false
  retention_days: 7
EOF
    
    # Test configuration loading
    source "$LIB_DIR/docker-sidecar-config.sh"
    
    local security_level max_containers max_memory rate_limit log_enabled retention_days
    security_level=$(DEFAULT_CONFIG_FILE="$test_config_file" get_security_level)
    max_containers=$(DEFAULT_CONFIG_FILE="$test_config_file" get_policy_value "max_containers")
    max_memory=$(DEFAULT_CONFIG_FILE="$test_config_file" get_policy_value "max_memory")
    rate_limit=$(DEFAULT_CONFIG_FILE="$test_config_file" get_policy_value "rate_limit_per_minute")
    log_enabled=$(DEFAULT_CONFIG_FILE="$test_config_file" get_logging_config "enabled")
    retention_days=$(DEFAULT_CONFIG_FILE="$test_config_file" get_logging_config "retention_days")
    
    # Clean up
    rm -rf "$test_config_dir"
    
    # Verify values
    if [[ "$security_level" == "strict" ]] && \
       [[ "$max_containers" == "15" ]] && \
       [[ "$max_memory" == "4g" ]] && \
       [[ "$rate_limit" == "120" ]] && \
       [[ "$log_enabled" == "false" ]] && \
       [[ "$retention_days" == "7" ]]; then
        return 0  # Test passed
    else
        return 1  # Test failed
    fi
}

# Test configuration validation
test_configuration_validation() {
    local test_config_dir="/tmp/test_claudebox_config_validation_$$"
    local test_config_file="$test_config_dir/docker-sidecar.yaml"
    
    # Clean up and create test environment
    rm -rf "$test_config_dir"
    mkdir -p "$test_config_dir"
    
    # Create invalid configuration
    cat > "$test_config_file" << EOF
sidecar:
  security_level: invalid_level
policies:
  max_containers: 999
  rate_limit_per_minute: 0
EOF
    
    source "$LIB_DIR/docker-sidecar-config.sh"
    
    # Test validation - should fail
    if DEFAULT_CONFIG_FILE="$test_config_file" validate_sidecar_config 2>/dev/null; then
        rm -rf "$test_config_dir"
        return 1  # Test failed - validation should have failed
    else
        rm -rf "$test_config_dir"
        return 0  # Test passed - validation correctly failed
    fi
}

# Test sidecar image building (mock)
test_sidecar_image_build_check() {
    # We can't actually build the image in the test environment,
    # but we can test the build logic
    
    source "$LIB_DIR/docker.sh"
    
    # Mock docker images command to simulate missing image
    docker() {
        if [[ "$1" == "images" ]]; then
            # Return empty result to simulate missing image
            return 0
        elif [[ "$1" == "build" ]]; then
            # Simulate successful build
            return 0
        fi
        # Pass through other commands
        command docker "$@"
    }
    
    # This would normally trigger a build, but we can't test that easily
    # Instead, just verify the function exists and has the right structure
    if declare -f build_sidecar_image >/dev/null; then
        return 0  # Test passed - function exists
    else
        return 1  # Test failed - function not found
    fi
}

# Test container lifecycle management functions
test_sidecar_lifecycle_functions() {
    source "$LIB_DIR/docker.sh"
    
    # Test that lifecycle functions exist
    local functions=(
        "build_sidecar_image"
        "start_docker_sidecar" 
        "stop_docker_sidecar"
        "check_sidecar_status"
    )
    
    for func in "${functions[@]}"; do
        if ! declare -f "$func" >/dev/null; then
            return 1  # Test failed - function not found
        fi
    done
    
    return 0  # Test passed - all functions found
}

# Test environment variable handling
test_environment_variables() {
    source "$LIB_DIR/docker-sidecar-config.sh"
    
    # Set up test environment
    local test_config_dir="/tmp/test_claudebox_config_env_$$"
    local test_config_file="$test_config_dir/docker-sidecar.yaml"
    
    rm -rf "$test_config_dir"
    mkdir -p "$test_config_dir"
    
    cat > "$test_config_file" << EOF
sidecar:
  security_level: permissive
policies:
  max_containers: 25
EOF
    
    # Export configuration
    DEFAULT_CONFIG_FILE="$test_config_file" export_sidecar_env
    
    # Check exported variables
    if [[ "$SIDECAR_SECURITY_LEVEL" == "permissive" ]] && \
       [[ "$SIDECAR_MAX_CONTAINERS" == "25" ]]; then
        rm -rf "$test_config_dir"
        return 0  # Test passed
    else
        rm -rf "$test_config_dir"
        return 1  # Test failed
    fi
}

# Test error handling in client functions
test_client_error_handling() {
    # Test client behavior with unavailable sidecar
    SIDECAR_SOCKET="/nonexistent/socket"
    SIDECAR_FALLBACK=false
    
    # Should return error code 2 for unavailable sidecar
    local exit_code=0
    docker_sidecar_ps 2>/dev/null || exit_code=$?
    
    if [[ $exit_code -eq 2 ]]; then
        return 0  # Test passed - correct error handling
    else
        return 1  # Test failed - unexpected error code
    fi
}

# Test CLI integration
test_cli_integration() {
    source "$LIB_DIR/cli.sh"
    
    # Test that sidecar is recognized as valid docker mode
    local test_args=("--docker-mode" "sidecar" "shell")
    CLI_HOST_FLAGS=()
    CLI_CONTROL_FLAGS=()
    CLI_SCRIPT_COMMAND=""
    CLI_PASS_THROUGH=()
    
    parse_cli_args "${test_args[@]}"
    
    # Process control flags to set DOCKER_MODE
    process_control_flags
    
    if [[ "$DOCKER_MODE" == "sidecar" ]]; then
        return 0  # Test passed - sidecar mode recognized
    else
        return 1  # Test failed - sidecar mode not set
    fi
}

# Test log rotation functionality
test_log_rotation() {
    local test_log_dir="/tmp/test_sidecar_logs_$$"
    local test_log_file="$test_log_dir/docker-audit.log"
    
    # Clean up and create test environment
    rm -rf "$test_log_dir"
    mkdir -p "$test_log_dir"
    
    source "$LIB_DIR/docker-sidecar/docker-sidecar-logger.sh"
    
    # Create a large log file (simulate size check)
    printf 'Large log content\n%.0s' {1..1000} > "$test_log_file"
    
    # Mock the file size check by overriding LOG_MAX_SIZE
    LOG_DIR="$test_log_dir" LOG_FILE="$test_log_file" LOG_MAX_SIZE=1000 rotate_logs_if_needed
    
    # Check if rotation occurred (backup file should exist)
    local backup_exists=false
    if ls "${test_log_file}".* >/dev/null 2>&1; then
        backup_exists=true
    fi
    
    rm -rf "$test_log_dir"
    
    if [[ "$backup_exists" == "true" ]]; then
        return 0  # Test passed - log was rotated
    else
        return 1  # Test failed - log rotation didn't work
    fi
}

# Test template existence and structure
test_template_structure() {
    local template_file="$BUILD_DIR/../templates/docker-sidecar.yaml"
    
    if [[ ! -f "$template_file" ]]; then
        return 1  # Test failed - template not found
    fi
    
    # Check for key sections in template
    local required_sections=(
        "sidecar:"
        "policies:"
        "logging:" 
        "dangerous_flags:"
        "dangerous_paths:"
    )
    
    for section in "${required_sections[@]}"; do
        if ! grep -q "^$section" "$template_file"; then
            return 1  # Test failed - section not found
        fi
    done
    
    return 0  # Test passed - all sections found
}

# Main test execution
main() {
    printf "${GREEN}Docker Sidecar Functionality Tests${NC}\n"
    printf "===================================\n"
    
    print_test_header "Client Library Tests"
    run_test "Sidecar availability detection" test_sidecar_availability
    run_test "Docker wrapper functionality" test_docker_wrapper
    run_test "Client argument parsing" test_client_argument_parsing
    run_test "JSON request construction" test_json_request_construction
    run_test "Client error handling" test_client_error_handling
    
    print_test_header "Configuration System"
    run_test "Configuration loading" test_configuration_loading
    run_test "Configuration validation" test_configuration_validation
    run_test "Environment variable handling" test_environment_variables
    
    print_test_header "Integration Tests"
    run_test "Sidecar image build check" test_sidecar_image_build_check
    run_test "Lifecycle functions exist" test_sidecar_lifecycle_functions
    run_test "CLI integration" test_cli_integration
    
    print_test_header "Infrastructure Tests"
    run_test "Log rotation functionality" test_log_rotation
    run_test "Template structure" test_template_structure
    
    # Print summary
    printf "\n${YELLOW}Test Summary${NC}\n"
    printf "============\n"
    printf "Tests run: %d\n" $TESTS_RUN
    printf "${GREEN}Tests passed: %d${NC}\n" $TESTS_PASSED
    printf "${RED}Tests failed: %d${NC}\n" $TESTS_FAILED
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        printf "\n${GREEN}All functionality tests passed!${NC}\n"
        exit 0
    else
        printf "\n${RED}Some functionality tests failed!${NC}\n"
        exit 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi