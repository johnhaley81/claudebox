#!/usr/bin/env bash
# Docker Sidecar Configuration Management
# Handles loading and parsing of sidecar configuration files

set -Eeuo pipefail
IFS=$'\n\t'

# Default configuration paths
DEFAULT_CONFIG_DIR="${DEFAULT_CONFIG_DIR:-$HOME/.claudebox}"
DEFAULT_CONFIG_FILE="${DEFAULT_CONFIG_FILE:-$DEFAULT_CONFIG_DIR/docker-sidecar.yaml}"
SYSTEM_CONFIG_FILE="${SYSTEM_CONFIG_FILE:-/etc/claudebox/docker-sidecar.yaml}"

# Initialize configuration system
init_sidecar_config() {
    # Ensure config directory exists
    if [[ ! -d "$DEFAULT_CONFIG_DIR" ]]; then
        mkdir -p "$DEFAULT_CONFIG_DIR" || {
            printf "ERROR: Cannot create config directory: %s\n" "$DEFAULT_CONFIG_DIR" >&2
            return 1
        }
    fi
    
    # Create default config if it doesn't exist
    if [[ ! -f "$DEFAULT_CONFIG_FILE" ]]; then
        create_default_config || {
            printf "ERROR: Cannot create default configuration\n" >&2
            return 1
        }
    fi
}

# Create default configuration file
create_default_config() {
    cat > "$DEFAULT_CONFIG_FILE" << 'EOF'
# ClaudeBox Docker Sidecar Configuration
# This file controls the security and behavior of the Docker sidecar proxy

sidecar:
  enabled: true
  security_level: moderate  # strict, moderate, permissive
  
policies:
  allow_privileged: false
  allow_host_mounts: false
  max_containers: 10
  max_memory: "2g"
  max_cpus: "2"
  rate_limit_per_minute: 60
  
  # Image allowlist (patterns)
  allowed_images:
    - "ubuntu:*"
    - "alpine:*"
    - "debian:*"
    - "node:*"
    - "python:*"
    - "golang:*"
    - "rust:*"
    - "openjdk:*"
    - "nginx:*"
    - "postgres:*"
    - "mysql:*"
    - "redis:*"
    
  # Blocked images (patterns)
  blocked_images:
    - "*:latest"  # Force specific tags for security
    
  # Allowed operations by security level
  operations:
    strict:
      - "docker_ps"
      - "docker_images"
      - "docker_logs"
      - "docker_inspect"
    moderate:
      - "docker_ps"
      - "docker_images"
      - "docker_logs"
      - "docker_inspect"
      - "docker_run_restricted"
      - "docker_exec_readonly"
      - "docker_build"
      - "docker_pull"
    permissive:
      - "docker_ps"
      - "docker_images"
      - "docker_logs"
      - "docker_inspect"
      - "docker_run"
      - "docker_exec"
      - "docker_build"
      - "docker_pull"
      - "docker_push"
      - "docker_create"
      - "docker_start"
      - "docker_stop"
      - "docker_rm"

logging:
  enabled: true
  path: "~/.claudebox/docker-audit.log"
  retention_days: 30
  max_size_mb: 10
  
monitoring:
  health_check_interval: 30
  restart_on_failure: true
  max_restart_attempts: 3
EOF

    printf "Created default sidecar configuration at: %s\n" "$DEFAULT_CONFIG_FILE"
}

# Simple YAML parser for basic key-value extraction
# Note: This is a minimal YAML parser for our specific config structure
parse_yaml_value() {
    local file="$1"
    local key_path="$2"
    local default_value="${3:-}"
    
    if [[ ! -f "$file" ]]; then
        printf '%s\n' "$default_value"
        return 1
    fi
    
    # Split key path by dots to handle nested values
    local key_parts
    IFS='.' read -ra key_parts <<< "$key_path"
    
    local current_section=""
    local indent_level=0
    local found_value=""
    
    while IFS= read -r line; do
        # Skip empty lines and comments
        if [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # Calculate indentation level
        local current_indent=0
        local trimmed_line="$line"
        while [[ "$trimmed_line" =~ ^[[:space:]] ]]; do
            current_indent=$((current_indent + 1))
            trimmed_line="${trimmed_line:1}"
        done
        
        # Handle key-value pairs
        if [[ "$trimmed_line" =~ ^([^:]+):[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            
            # Build current path
            if [[ $current_indent -eq 0 ]]; then
                current_section="$key"
            elif [[ $current_indent -eq 2 ]]; then
                current_section="${current_section%.*}.$key" 2>/dev/null || current_section="$key"
            fi
            
            # Check if this matches our target path
            local full_path="$current_section"
            if [[ ${#key_parts[@]} -eq 2 ]] && [[ "$full_path" == "${key_parts[0]}.${key_parts[1]}" ]]; then
                # Remove quotes from value if present
                value="${value%\"}"
                value="${value#\"}"
                found_value="$value"
                break
            fi
        fi
    done < "$file"
    
    if [[ -n "$found_value" ]]; then
        printf '%s\n' "$found_value"
    else
        printf '%s\n' "$default_value"
    fi
}

# Get configuration value with fallback hierarchy
get_config_value() {
    local key_path="$1"
    local default_value="${2:-}"
    
    local value
    
    # Try user config first
    if [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
        value=$(parse_yaml_value "$DEFAULT_CONFIG_FILE" "$key_path" "")
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi
    
    # Try system config
    if [[ -f "$SYSTEM_CONFIG_FILE" ]]; then
        value=$(parse_yaml_value "$SYSTEM_CONFIG_FILE" "$key_path" "")
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi
    
    # Return default
    printf '%s\n' "$default_value"
}

# Get security level configuration
get_security_level() {
    get_config_value "sidecar.security_level" "moderate"
}

# Get policies
get_policy_value() {
    local policy_key="$1"
    local default_value="${2:-}"
    get_config_value "policies.$policy_key" "$default_value"
}

# Get logging configuration
get_logging_config() {
    local log_key="$1"
    local default_value="${2:-}"
    get_config_value "logging.$log_key" "$default_value"
}

# Check if sidecar is enabled
is_sidecar_enabled() {
    local enabled
    enabled=$(get_config_value "sidecar.enabled" "true")
    [[ "$enabled" == "true" ]]
}

# Export configuration as environment variables
export_sidecar_env() {
    export SIDECAR_ENABLED=$(get_config_value "sidecar.enabled" "true")
    export SIDECAR_SECURITY_LEVEL=$(get_security_level)
    export SIDECAR_MAX_CONTAINERS=$(get_policy_value "max_containers" "10")
    export SIDECAR_MAX_MEMORY=$(get_policy_value "max_memory" "2g")
    export SIDECAR_MAX_CPUS=$(get_policy_value "max_cpus" "2")
    export SIDECAR_RATE_LIMIT=$(get_policy_value "rate_limit_per_minute" "60")
    export SIDECAR_LOG_DIR="$DEFAULT_CONFIG_DIR"
    export SIDECAR_LOG_ENABLED=$(get_logging_config "enabled" "true")
    export SIDECAR_LOG_RETENTION_DAYS=$(get_logging_config "retention_days" "30")
    export SIDECAR_LOG_MAX_SIZE=$(($(get_logging_config "max_size_mb" "10") * 1024 * 1024))
    
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo "[DEBUG] Sidecar configuration exported to environment" >&2
    fi
}

# Validate configuration
validate_sidecar_config() {
    local errors=()
    
    # Check security level
    local security_level
    security_level=$(get_security_level)
    if [[ ! "$security_level" =~ ^(strict|moderate|permissive)$ ]]; then
        errors+=("Invalid security level: $security_level")
    fi
    
    # Check numeric values
    local max_containers
    max_containers=$(get_policy_value "max_containers" "10")
    if [[ ! "$max_containers" =~ ^[0-9]+$ ]] || [[ $max_containers -lt 1 ]] || [[ $max_containers -gt 100 ]]; then
        errors+=("Invalid max_containers: $max_containers (must be 1-100)")
    fi
    
    local rate_limit
    rate_limit=$(get_policy_value "rate_limit_per_minute" "60")
    if [[ ! "$rate_limit" =~ ^[0-9]+$ ]] || [[ $rate_limit -lt 1 ]] || [[ $rate_limit -gt 3600 ]]; then
        errors+=("Invalid rate_limit_per_minute: $rate_limit (must be 1-3600)")
    fi
    
    # Report errors
    if [[ ${#errors[@]} -gt 0 ]]; then
        printf "Configuration validation errors:\n" >&2
        for error in "${errors[@]}"; do
            printf "  - %s\n" "$error" >&2
        done
        return 1
    fi
    
    return 0
}

# Show current configuration
show_sidecar_config() {
    printf "ClaudeBox Docker Sidecar Configuration\n"
    printf "=====================================\n\n"
    
    printf "Status:\n"
    if is_sidecar_enabled; then
        printf "  Enabled: Yes\n"
    else
        printf "  Enabled: No\n"
    fi
    printf "  Security Level: %s\n" "$(get_security_level)"
    printf "\n"
    
    printf "Policies:\n"
    printf "  Max Containers: %s\n" "$(get_policy_value "max_containers" "10")"
    printf "  Max Memory: %s\n" "$(get_policy_value "max_memory" "2g")"
    printf "  Max CPUs: %s\n" "$(get_policy_value "max_cpus" "2")"
    printf "  Rate Limit: %s requests/minute\n" "$(get_policy_value "rate_limit_per_minute" "60")"
    printf "  Allow Privileged: %s\n" "$(get_policy_value "allow_privileged" "false")"
    printf "  Allow Host Mounts: %s\n" "$(get_policy_value "allow_host_mounts" "false")"
    printf "\n"
    
    printf "Logging:\n"
    printf "  Enabled: %s\n" "$(get_logging_config "enabled" "true")"
    printf "  Path: %s\n" "$(get_logging_config "path" "~/.claudebox/docker-audit.log")"
    printf "  Retention: %s days\n" "$(get_logging_config "retention_days" "30")"
    printf "  Max Size: %s MB\n" "$(get_logging_config "max_size_mb" "10")"
    printf "\n"
    
    printf "Configuration Files:\n"
    if [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
        printf "  User Config: %s (exists)\n" "$DEFAULT_CONFIG_FILE"
    else
        printf "  User Config: %s (not found)\n" "$DEFAULT_CONFIG_FILE"
    fi
    
    if [[ -f "$SYSTEM_CONFIG_FILE" ]]; then
        printf "  System Config: %s (exists)\n" "$SYSTEM_CONFIG_FILE"
    else
        printf "  System Config: %s (not found)\n" "$SYSTEM_CONFIG_FILE"
    fi
}

# Export functions
export -f init_sidecar_config create_default_config parse_yaml_value
export -f get_config_value get_security_level get_policy_value get_logging_config
export -f is_sidecar_enabled export_sidecar_env validate_sidecar_config show_sidecar_config