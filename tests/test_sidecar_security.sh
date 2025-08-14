#!/usr/bin/env bash
# Security Tests for Docker Sidecar
# Tests security filtering and protection mechanisms

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
readonly NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source sidecar components for testing
source "$LIB_DIR/docker-sidecar/docker-sidecar-filter.sh"
source "$LIB_DIR/docker-sidecar/docker-sidecar-logger.sh"
source "$LIB_DIR/docker-sidecar-config.sh"

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

# Test dangerous flag detection
test_dangerous_flags_detection() {
    local test_request='{"operation":"docker_run","parameters":{"image":"ubuntu:20.04","options":{"privileged":true}}}'
    
    # This should fail due to dangerous flag
    if check_dangerous_flags "$(printf '%s\n' "$test_request" | jq '.parameters')" 2>/dev/null; then
        return 1  # Test failed - should have been blocked
    else
        return 0  # Test passed - correctly blocked
    fi
}

test_dangerous_volume_mounts() {
    local test_request='{"operation":"docker_run","parameters":{"image":"ubuntu:20.04","options":{"volume":["/:/host"]}}}'
    
    # This should fail due to dangerous volume mount
    if check_dangerous_flags "$(printf '%s\n' "$test_request" | jq '.parameters')" 2>/dev/null; then
        return 1  # Test failed - should have been blocked
    else
        return 0  # Test passed - correctly blocked
    fi
}

test_safe_flags_allowed() {
    local test_request='{"operation":"docker_run","parameters":{"image":"ubuntu:20.04","options":{"rm":true,"memory":"512m"}}}'
    
    # This should pass - safe flags
    if check_dangerous_flags "$(printf '%s\n' "$test_request" | jq '.parameters')" 2>/dev/null; then
        return 0  # Test passed - correctly allowed
    else
        return 1  # Test failed - should have been allowed
    fi
}

# Test image allowlist
test_image_allowlist_allowed() {
    if is_image_allowed "ubuntu:20.04"; then
        return 0  # Test passed - ubuntu should be allowed
    else
        return 1  # Test failed - ubuntu should be allowed
    fi
}

test_image_allowlist_blocked() {
    if is_image_allowed "malicious-image:latest"; then
        return 1  # Test failed - should be blocked
    else
        return 0  # Test passed - correctly blocked
    fi
}

test_latest_tag_blocked() {
    if is_image_allowed "ubuntu:latest"; then
        return 1  # Test failed - :latest should be blocked
    else
        return 0  # Test passed - correctly blocked
    fi
}

# Test memory limit conversion
test_memory_conversion_bytes() {
    local result
    result=$(convert_memory_to_bytes "1024")
    [[ "$result" -eq 1024 ]]
}

test_memory_conversion_kb() {
    local result
    result=$(convert_memory_to_bytes "1k")
    [[ "$result" -eq 1024 ]]
}

test_memory_conversion_mb() {
    local result
    result=$(convert_memory_to_bytes "1m")
    [[ "$result" -eq 1048576 ]]
}

test_memory_conversion_gb() {
    local result
    result=$(convert_memory_to_bytes "2g")
    [[ "$result" -eq 2147483648 ]]
}

test_memory_limit_enforcement() {
    if is_memory_within_limit "1g" "2g"; then
        return 0  # Test passed - 1g is within 2g limit
    else
        return 1  # Test failed - should be within limit
    fi
}

test_memory_limit_exceeded() {
    if is_memory_within_limit "3g" "2g"; then
        return 1  # Test failed - should exceed limit
    else
        return 0  # Test passed - correctly detected limit exceeded
    fi
}

# Test CPU limit enforcement
test_cpu_limit_enforcement() {
    if is_cpu_within_limit "1" "2"; then
        return 0  # Test passed - 1 CPU is within 2 CPU limit
    else
        return 1  # Test failed - should be within limit
    fi
}

test_cpu_limit_exceeded() {
    if is_cpu_within_limit "3" "2"; then
        return 1  # Test failed - should exceed limit
    else
        return 0  # Test passed - correctly detected limit exceeded
    fi
}

test_cpu_decimal_limits() {
    if is_cpu_within_limit "1.5" "2.0"; then
        return 0  # Test passed - 1.5 is within 2.0 limit
    else
        return 1  # Test failed - should be within limit
    fi
}

# Test operation allowlist by security level
test_strict_operations() {
    local allowed_ops
    allowed_ops=$(get_allowed_operations "strict")
    
    # Should allow docker_ps
    if printf '%s\n' "$allowed_ops" | grep -q "docker_ps"; then
        # Should NOT allow docker_run
        if ! printf '%s\n' "$allowed_ops" | grep -q "docker_run"; then
            return 0  # Test passed
        fi
    fi
    return 1  # Test failed
}

test_moderate_operations() {
    local allowed_ops
    allowed_ops=$(get_allowed_operations "moderate")
    
    # Should allow docker_ps and docker_run_restricted
    if printf '%s\n' "$allowed_ops" | grep -q "docker_ps" && \
       printf '%s\n' "$allowed_ops" | grep -q "docker_run_restricted"; then
        return 0  # Test passed
    fi
    return 1  # Test failed
}

test_permissive_operations() {
    local allowed_ops
    allowed_ops=$(get_allowed_operations "permissive")
    
    # Should allow docker_ps and docker_run
    if printf '%s\n' "$allowed_ops" | grep -q "docker_ps" && \
       printf '%s\n' "$allowed_ops" | grep -q "docker_run"; then
        return 0  # Test passed
    fi
    return 1  # Test failed
}

# Test security filter integration
test_security_filter_blocks_privileged() {
    export DEFAULT_SECURITY_LEVEL="moderate"
    local test_request='{"operation":"docker_run","parameters":{"image":"ubuntu:20.04","options":{"privileged":true}}}'
    
    # This should be blocked by security filters
    if apply_security_filters "$test_request" >/dev/null 2>&1; then
        return 1  # Test failed - should have been blocked
    else
        return 0  # Test passed - correctly blocked
    fi
}

test_security_filter_allows_safe() {
    export DEFAULT_SECURITY_LEVEL="moderate"
    local test_request='{"operation":"docker_run","parameters":{"image":"ubuntu:20.04","options":{"rm":true}}}'
    
    # This should be allowed by security filters
    if apply_security_filters "$test_request" >/dev/null 2>&1; then
        return 0  # Test passed - correctly allowed
    else
        return 1  # Test failed - should have been allowed
    fi
}

test_resource_limit_application() {
    local test_request='{"operation":"docker_run","parameters":{"image":"ubuntu:20.04","options":{"memory":"4g"}}}'
    local filtered_request
    
    # Should apply default memory limit (2g)
    filtered_request=$(apply_resource_limits "$test_request")
    local memory_limit
    memory_limit=$(printf '%s\n' "$filtered_request" | jq -r '.parameters.options.memory')
    
    [[ "$memory_limit" == "2g" ]]
}

# Test rate limiting
test_rate_limit_mechanism() {
    # Clean up any existing rate limit file
    rm -f /tmp/sidecar_rate_limit
    
    # First request should pass
    if ! check_rate_limit; then
        return 1
    fi
    
    # Simulate many requests to trigger rate limit
    local i
    for i in $(seq 1 70); do
        check_rate_limit >/dev/null 2>&1 || break
    done
    
    # Should eventually be rate limited
    if check_rate_limit 2>/dev/null; then
        return 1  # Test failed - should be rate limited
    else
        return 0  # Test passed - correctly rate limited
    fi
}

# Test configuration system
test_config_default_creation() {
    local test_config_dir="/tmp/test_claudebox_config"
    local test_config_file="$test_config_dir/docker-sidecar.yaml"
    
    # Clean up
    rm -rf "$test_config_dir"
    
    # Override config paths for testing
    DEFAULT_CONFIG_DIR="$test_config_dir" DEFAULT_CONFIG_FILE="$test_config_file" init_sidecar_config
    
    # Check if config was created
    if [[ -f "$test_config_file" ]]; then
        rm -rf "$test_config_dir"
        return 0  # Test passed
    else
        rm -rf "$test_config_dir"
        return 1  # Test failed
    fi
}

test_config_value_parsing() {
    local test_config_file="/tmp/test_sidecar_config.yaml"
    
    # Create test config
    cat > "$test_config_file" << EOF
sidecar:
  security_level: strict
policies:
  max_containers: 5
EOF
    
    local security_level
    security_level=$(parse_yaml_value "$test_config_file" "sidecar.security_level" "moderate")
    
    local max_containers  
    max_containers=$(parse_yaml_value "$test_config_file" "policies.max_containers" "10")
    
    # Clean up
    rm -f "$test_config_file"
    
    if [[ "$security_level" == "strict" ]] && [[ "$max_containers" == "5" ]]; then
        return 0  # Test passed
    else
        return 1  # Test failed
    fi
}

# Test audit logging
test_audit_logging() {
    local test_log_dir="/tmp/test_sidecar_logs"
    local test_log_file="$test_log_dir/docker-audit.log"
    
    # Clean up and create test environment
    rm -rf "$test_log_dir"
    mkdir -p "$test_log_dir"
    
    # Override log settings
    LOG_DIR="$test_log_dir" LOG_FILE="$test_log_file" init_logging
    
    # Test logging
    LOG_DIR="$test_log_dir" LOG_FILE="$test_log_file" log_audit_event "TEST" "test_operation" "Test message" '{"test": true}'
    
    # Check if log entry was written
    local log_exists=false
    if [[ -f "$test_log_file" ]] && grep -q "test_operation" "$test_log_file"; then
        log_exists=true
    fi
    
    # Clean up
    rm -rf "$test_log_dir"
    
    if [[ "$log_exists" == "true" ]]; then
        return 0  # Test passed
    else
        return 1  # Test failed
    fi
}

# Main test execution
main() {
    printf "${GREEN}Docker Sidecar Security Tests${NC}\n"
    printf "==============================\n"
    
    # Set up test environment
    export VERBOSE=false
    export SIDECAR_SECURITY_LEVEL=moderate
    export SIDECAR_MAX_MEMORY=2g
    export SIDECAR_MAX_CPUS=2
    export SIDECAR_RATE_LIMIT=60
    
    print_test_header "Dangerous Flag Detection"
    run_test "Privileged flag blocked" test_dangerous_flags_detection
    run_test "Dangerous volume mounts blocked" test_dangerous_volume_mounts  
    run_test "Safe flags allowed" test_safe_flags_allowed
    
    print_test_header "Image Allowlist"
    run_test "Allowed image passes" test_image_allowlist_allowed
    run_test "Blocked image rejected" test_image_allowlist_blocked
    run_test "Latest tag blocked" test_latest_tag_blocked
    
    print_test_header "Memory Limits"
    run_test "Memory conversion bytes" test_memory_conversion_bytes
    run_test "Memory conversion KB" test_memory_conversion_kb
    run_test "Memory conversion MB" test_memory_conversion_mb
    run_test "Memory conversion GB" test_memory_conversion_gb
    run_test "Memory limit enforcement" test_memory_limit_enforcement
    run_test "Memory limit exceeded detection" test_memory_limit_exceeded
    
    print_test_header "CPU Limits"
    run_test "CPU limit enforcement" test_cpu_limit_enforcement
    run_test "CPU limit exceeded detection" test_cpu_limit_exceeded
    run_test "Decimal CPU limits" test_cpu_decimal_limits
    
    print_test_header "Operation Allowlists"
    run_test "Strict security level operations" test_strict_operations
    run_test "Moderate security level operations" test_moderate_operations
    run_test "Permissive security level operations" test_permissive_operations
    
    print_test_header "Security Filter Integration"
    run_test "Privileged requests blocked" test_security_filter_blocks_privileged
    run_test "Safe requests allowed" test_security_filter_allows_safe
    run_test "Resource limits applied" test_resource_limit_application
    
    print_test_header "Rate Limiting"
    run_test "Rate limiting mechanism" test_rate_limit_mechanism
    
    print_test_header "Configuration System"
    run_test "Default config creation" test_config_default_creation
    run_test "Config value parsing" test_config_value_parsing
    
    print_test_header "Audit Logging"
    run_test "Basic audit logging" test_audit_logging
    
    # Print summary
    printf "\n${YELLOW}Test Summary${NC}\n"
    printf "============\n"
    printf "Tests run: %d\n" $TESTS_RUN
    printf "${GREEN}Tests passed: %d${NC}\n" $TESTS_PASSED
    printf "${RED}Tests failed: %d${NC}\n" $TESTS_FAILED
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        printf "\n${GREEN}All tests passed!${NC}\n"
        exit 0
    else
        printf "\n${RED}Some tests failed!${NC}\n"
        exit 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi