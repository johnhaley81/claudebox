#!/usr/bin/env bash
# Docker Sidecar Security Filter
# Applies security policies to Docker operations

set -Eeuo pipefail
IFS=$'\n\t'

# Default security configuration
DEFAULT_SECURITY_LEVEL="${SIDECAR_SECURITY_LEVEL:-moderate}"
readonly MAX_CONTAINERS="${SIDECAR_MAX_CONTAINERS:-10}"
readonly MAX_MEMORY="${SIDECAR_MAX_MEMORY:-2g}"
readonly MAX_CPUS="${SIDECAR_MAX_CPUS:-2}"
readonly RATE_LIMIT_PER_MINUTE="${SIDECAR_RATE_LIMIT:-60}"

# Dangerous flags that should be blocked
readonly DANGEROUS_FLAGS=(
    "--privileged"
    "--cap-add=SYS_ADMIN"
    "--cap-add=NET_ADMIN" 
    "--cap-add=SYS_PTRACE"
    "--cap-add=SYS_MODULE"
    "--net=host"
    "--network=host"
    "--pid=host"
    "--ipc=host"
    "--userns=host"
    "--security-opt=apparmor:unconfined"
    "--security-opt=seccomp:unconfined"
)

# Dangerous volume mounts
readonly DANGEROUS_PATHS=(
    "/:/host"
    "/etc:/host-etc"
    "/var/run/docker.sock"
    "/proc:/host-proc"
    "/sys:/host-sys"
    "/dev:/host-dev"
    "/boot:/host-boot"
    "/lib/modules"
    "/usr/src"
)

# Operation allowlist based on security level
get_allowed_operations() {
    local security_level="${1:-moderate}"
    
    case "$security_level" in
        "strict")
            printf '%s\n' "docker_ps" "docker_images" "docker_logs" "docker_inspect"
            ;;
        "moderate")
            printf '%s\n' "docker_ps" "docker_images" "docker_logs" "docker_inspect" \
                         "docker_run_restricted" "docker_exec_readonly" "docker_build" "docker_pull"
            ;;
        "permissive")
            printf '%s\n' "docker_ps" "docker_images" "docker_logs" "docker_inspect" \
                         "docker_run" "docker_exec" "docker_build" "docker_pull" "docker_push" \
                         "docker_create" "docker_start" "docker_stop" "docker_rm"
            ;;
        *)
            # Default to moderate
            get_allowed_operations "moderate"
            ;;
    esac
}

# Image allowlist
is_image_allowed() {
    local image="$1"
    
    # Default allowlist - can be overridden by configuration
    local allowed_prefixes=(
        "ubuntu:"
        "alpine:"
        "debian:"
        "node:"
        "python:"
        "golang:"
        "rust:"
        "openjdk:"
        "nginx:"
        "postgres:"
        "mysql:"
        "redis:"
    )
    
    # Block 'latest' tags for security
    if [[ "$image" == *":latest" ]] || [[ "$image" != *":"* ]]; then
        return 1
    fi
    
    # Check against allowlist
    for prefix in "${allowed_prefixes[@]}"; do
        if [[ "$image" == "$prefix"* ]]; then
            return 0
        fi
    done
    
    return 1
}

# Check for dangerous flags in docker command
check_dangerous_flags() {
    local params="$1"
    local dangerous_found=()
    
    # Extract all option keys and values from the parameters
    local options
    options=$(printf '%s\n' "$params" | jq -r '.options // {} | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null || true)
    
    # Check each option against dangerous flags
    while IFS= read -r option; do
        if [[ -z "$option" ]]; then
            continue
        fi
        
        for dangerous_flag in "${DANGEROUS_FLAGS[@]}"; do
            if [[ "$option" == "$dangerous_flag"* ]] || [[ "--$option" == "$dangerous_flag"* ]]; then
                dangerous_found+=("$dangerous_flag")
            fi
        done
    done <<< "$options"
    
    # Check for dangerous volume mounts
    local volumes
    volumes=$(printf '%s\n' "$params" | jq -r '.options.volume[]? // empty' 2>/dev/null || true)
    
    while IFS= read -r volume; do
        if [[ -z "$volume" ]]; then
            continue
        fi
        
        for dangerous_path in "${DANGEROUS_PATHS[@]}"; do
            if [[ "$volume" == "$dangerous_path"* ]]; then
                dangerous_found+=("volume mount: $volume")
            fi
        done
    done <<< "$volumes"
    
    if [[ ${#dangerous_found[@]} -gt 0 ]]; then
        printf "Dangerous flags/options detected: %s\n" "$(IFS=', '; printf '%s\n' "${dangerous_found[*]}")" >&2
        return 1
    fi
    
    return 0
}

# Apply resource limits
apply_resource_limits() {
    local request="$1"
    local modified_request="$request"
    
    # Extract current options
    local options
    options=$(printf '%s\n' "$request" | jq -r '.parameters.options // {}')
    
    # Apply memory limit if not set or exceeds maximum
    local current_memory
    current_memory=$(printf '%s\n' "$options" | jq -r '.memory // empty')
    
    if [[ -z "$current_memory" ]] || ! is_memory_within_limit "$current_memory" "$MAX_MEMORY"; then
        options=$(printf '%s\n' "$options" | jq --arg mem "$MAX_MEMORY" '.memory = $mem')
    fi
    
    # Apply CPU limit if not set or exceeds maximum  
    local current_cpus
    current_cpus=$(printf '%s\n' "$options" | jq -r '.cpus // empty')
    
    if [[ -z "$current_cpus" ]] || ! is_cpu_within_limit "$current_cpus" "$MAX_CPUS"; then
        options=$(printf '%s\n' "$options" | jq --arg cpus "$MAX_CPUS" '.cpus = $cpus')
    fi
    
    # Update the request with modified options
    modified_request=$(printf '%s\n' "$request" | jq --argjson opts "$options" '.parameters.options = $opts')
    
    printf '%s\n' "$modified_request"
}

# Helper function to check memory limits
is_memory_within_limit() {
    local requested="$1"
    local max_limit="$2"
    
    # Convert both to bytes for comparison
    local requested_bytes
    local max_bytes
    
    requested_bytes=$(convert_memory_to_bytes "$requested") || return 1
    max_bytes=$(convert_memory_to_bytes "$max_limit") || return 1
    
    [[ $requested_bytes -le $max_bytes ]]
}

# Helper function to check CPU limits
is_cpu_within_limit() {
    local requested="$1"
    local max_limit="$2"
    
    # Simple comparison for CPU count
    if [[ "$requested" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$max_limit" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        # Use awk for floating point comparison
        awk "BEGIN { exit !($requested <= $max_limit) }"
    else
        return 1
    fi
}

# Convert memory specification to bytes
convert_memory_to_bytes() {
    local memory="$1"
    local bytes=0
    
    if [[ "$memory" =~ ^([0-9]+)([bBkKmMgG]?)$ ]]; then
        local number="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2],,}"  # Lowercase
        
        case "$unit" in
            ""|"b") bytes=$number ;;
            "k") bytes=$((number * 1024)) ;;
            "m") bytes=$((number * 1024 * 1024)) ;;
            "g") bytes=$((number * 1024 * 1024 * 1024)) ;;
            *) return 1 ;;
        esac
        
        printf '%d\n' "$bytes"
    else
        return 1
    fi
}

# Rate limiting check
check_rate_limit() {
    local rate_limit_file="/tmp/sidecar_rate_limit"
    local current_time
    current_time=$(date +%s)
    
    # Clean up old entries (older than 1 minute)
    if [[ -f "$rate_limit_file" ]]; then
        local cutoff_time=$((current_time - 60))
        awk -v cutoff="$cutoff_time" '$1 > cutoff' "$rate_limit_file" > "${rate_limit_file}.tmp" || true
        mv "${rate_limit_file}.tmp" "$rate_limit_file" 2>/dev/null || true
    fi
    
    # Count current requests in the last minute
    local request_count=0
    if [[ -f "$rate_limit_file" ]]; then
        request_count=$(wc -l < "$rate_limit_file" 2>/dev/null || echo "0")
    fi
    
    # Check if we're under the limit
    if [[ $request_count -ge $RATE_LIMIT_PER_MINUTE ]]; then
        printf "Rate limit exceeded: %d requests in the last minute (limit: %d)\n" \
            "$request_count" "$RATE_LIMIT_PER_MINUTE" >&2
        return 1
    fi
    
    # Record this request
    printf '%d\n' "$current_time" >> "$rate_limit_file"
    return 0
}

# Main security filter function
apply_security_filters() {
    local request="$1"
    local operation
    operation=$(printf '%s\n' "$request" | jq -r '.operation // empty')
    
    # Check rate limiting first
    if ! check_rate_limit; then
        return 1
    fi
    
    # Check if operation is allowed
    local allowed_ops
    allowed_ops=$(get_allowed_operations "$DEFAULT_SECURITY_LEVEL")
    
    if ! printf '%s\n' "$allowed_ops" | grep -q "^${operation}$"; then
        printf "Operation '%s' not allowed at security level '%s'\n" "$operation" "$DEFAULT_SECURITY_LEVEL" >&2
        return 1
    fi
    
    # For docker run operations, apply additional checks
    if [[ "$operation" == "docker_run" ]] || [[ "$operation" == "docker_run_restricted" ]]; then
        local params
        params=$(printf '%s\n' "$request" | jq -r '.parameters // {}')
        
        # Check image allowlist
        local image
        image=$(printf '%s\n' "$params" | jq -r '.image // empty')
        
        if [[ -n "$image" ]] && ! is_image_allowed "$image"; then
            printf "Image '%s' not in allowlist\n" "$image" >&2
            return 1
        fi
        
        # Check for dangerous flags
        if ! check_dangerous_flags "$params"; then
            return 1
        fi
        
        # Apply resource limits
        request=$(apply_resource_limits "$request")
    fi
    
    # For docker exec operations, apply restrictions
    if [[ "$operation" == "docker_exec" ]] || [[ "$operation" == "docker_exec_readonly" ]]; then
        local params
        params=$(printf '%s\n' "$request" | jq -r '.parameters // {}')
        
        # Check for dangerous flags
        if ! check_dangerous_flags "$params"; then
            return 1
        fi
    fi
    
    # Return the potentially modified request
    printf '%s\n' "$request"
}

# Export functions for use by API server
export -f get_allowed_operations is_image_allowed check_dangerous_flags
export -f apply_resource_limits is_memory_within_limit is_cpu_within_limit
export -f convert_memory_to_bytes check_rate_limit apply_security_filters