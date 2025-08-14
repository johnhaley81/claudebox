#!/usr/bin/env bash
# Unified CLI parser for ClaudeBox
# Implements the four-bucket architecture for clean, predictable CLI handling

# ============================================================================
# CLI PARSER - SINGLE SOURCE OF TRUTH
# ============================================================================

# Four flag buckets (Bash 3.2 compatible - no associative arrays)
readonly HOST_ONLY_FLAGS=(--verbose rebuild)
readonly CONTROL_FLAGS=(--enable-sudo --disable-firewall --docker-mode)
readonly SCRIPT_COMMANDS=(shell create slot slots revoke profiles projects profile info help -h --help add remove install allowlist clean save project tmux kill)

# parse_cli_args - Central CLI parsing with four-bucket architecture
# Usage: parse_cli_args "$@"
# Sets global variables:
#   host_flags: Array of host-only flags (help, version, etc)
#   control_flags: Array of control flags (verbose, enable-sudo, etc)
#   script_command: Single command for ClaudeBox to execute
#   pass_through: Array of args to pass to Claude in container
# Note: Each argument goes into exactly ONE bucket - no duplication
parse_cli_args() {
    local all_args=("$@")
    
    # Initialize bucket arrays
    host_flags=()
    control_flags=()
    script_command=""
    pass_through=()
    
    # Single parsing loop - each arg goes into exactly ONE bucket
    local found_script_command=false
    local i=0
    
    while [[ $i -lt ${#all_args[@]} ]]; do
        local arg="${all_args[$i]}"
        
        if [[ " ${HOST_ONLY_FLAGS[*]} " == *" $arg "* ]]; then
            # Bucket 1: Host-only flags
            host_flags+=("$arg")
        elif [[ "$arg" == "--docker-mode" ]]; then
            # Special handling for --docker-mode with value
            control_flags+=("$arg")
            # Look for the next argument as the value
            if [[ $((i + 1)) -lt ${#all_args[@]} ]]; then
                local next_arg="${all_args[$((i + 1))]}"
                # Check if next arg is a valid docker mode and not another flag
                if [[ "$next_arg" =~ ^(socket|none)$ ]]; then
                    control_flags+=("$next_arg")
                    i=$((i + 1))  # Skip the next argument since we consumed it
                else
                    # No valid mode provided, default to socket
                    control_flags+=("socket")
                fi
            else
                # No argument after --docker-mode, default to socket
                control_flags+=("socket")
            fi
        elif [[ " ${CONTROL_FLAGS[*]} " == *" $arg "* ]]; then
            # Bucket 2: Other control flags (pass to container)
            control_flags+=("$arg")
        elif [[ "$found_script_command" == "false" ]] && [[ " ${SCRIPT_COMMANDS[*]} " == *" $arg "* ]]; then
            # Bucket 3: Script commands (first one wins)
            script_command="$arg"
            found_script_command=true
        else
            # Bucket 4: Pass-through (everything else)
            pass_through+=("$arg")
        fi
        
        i=$((i + 1))
    done
    
    # Export results for use by main script
    export CLI_HOST_FLAGS=("${host_flags[@]}")
    export CLI_CONTROL_FLAGS=("${control_flags[@]}")
    export CLI_SCRIPT_COMMAND="$script_command"
    export CLI_PASS_THROUGH=("${pass_through[@]}")
}

# Process host-only flags and set environment variables
process_host_flags() {
    for flag in "${CLI_HOST_FLAGS[@]}"; do
        case "$flag" in
            --verbose)
                export VERBOSE=true
                ;;
            rebuild)
                export REBUILD=true
                ;;
            tmux)
                export CLAUDEBOX_WRAP_TMUX=true
                ;;
        esac
    done
}

# Process control flags and set environment variables
process_control_flags() {
    local i=0
    while [[ $i -lt ${#CLI_CONTROL_FLAGS[@]} ]]; do
        local flag="${CLI_CONTROL_FLAGS[$i]}"
        case "$flag" in
            --docker-mode)
                # Next element should be the mode value
                if [[ $((i + 1)) -lt ${#CLI_CONTROL_FLAGS[@]} ]]; then
                    local mode="${CLI_CONTROL_FLAGS[$((i + 1))]}"
                    export DOCKER_MODE="$mode"
                    i=$((i + 1))  # Skip next element since we consumed it
                else
                    export DOCKER_MODE="socket"  # Default fallback
                fi
                ;;
        esac
        i=$((i + 1))
    done
}

# Get control flags that should be passed to container (filters out host-only control flags)
get_container_control_flags() {
    local container_flags=()
    local i=0
    
    while [[ $i -lt ${#CLI_CONTROL_FLAGS[@]} ]]; do
        local flag="${CLI_CONTROL_FLAGS[$i]}"
        case "$flag" in
            --docker-mode)
                # Skip --docker-mode and its value
                if [[ $((i + 1)) -lt ${#CLI_CONTROL_FLAGS[@]} ]]; then
                    i=$((i + 1))  # Skip the next element (the mode value)
                fi
                ;;
            --enable-sudo|--disable-firewall)
                # These flags should be passed to container
                container_flags+=("$flag")
                ;;
        esac
        i=$((i + 1))
    done
    
    printf '%s\n' "${container_flags[@]}"
}

# Get command requirements - returns one of:
# "none" - pure host command, no Docker or image needed
# "image" - needs image name but not Docker running
# "docker" - needs Docker running and will run container
get_command_requirements() {
    local cmd="${1:-}"
    local subcommand="${2:-}"
    
    case "$cmd" in
        # Pure host commands - no Docker or image needed
        profiles|projects|help|-h|--help|slots|create|revoke|clean|import|unlink|kill)
            echo "none"
            ;;
        # Commands that need image name but not Docker
        info|profile|add|remove|install|allowlist|save)
            echo "image"
            ;;
        # Commands that need Docker and will run containers
        shell|project|rebuild|update|config|mcp|migrate-installer|tmux|slot|"")
            echo "docker"
            ;;
        # Unknown commands are forwarded to Claude in container
        *)
            echo "docker"
            ;;
    esac
}

# Legacy function for compatibility
requires_docker_image() {
    local cmd="${1:-}"
    local req=$(get_command_requirements "$cmd")
    [[ "$req" == "docker" ]]
}

# Check if current command requires a slot
requires_slot() {
    local cmd="${1:-}"
    
    # Commands that need a slot
    case "$cmd" in
        shell|update|config|mcp|migrate-installer|create|slot|"")
            return 0  # true - needs slot
            ;;
        *)
            return 1  # false - doesn't need slot
            ;;
    esac
}

# Debug output for parsed arguments (only if VERBOSE=true)
debug_parsed_args() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        echo "[DEBUG] CLI Parser Results:" >&2
        echo "[DEBUG]   Host flags: ${CLI_HOST_FLAGS[*]}" >&2
        echo "[DEBUG]   Control flags: ${CLI_CONTROL_FLAGS[*]}" >&2
        echo "[DEBUG]   Script command: ${CLI_SCRIPT_COMMAND}" >&2
        echo "[DEBUG]   Pass-through: ${CLI_PASS_THROUGH[*]}" >&2
    fi
}

# Export all functions
export -f parse_cli_args process_host_flags process_control_flags get_container_control_flags get_command_requirements requires_docker_image requires_slot debug_parsed_args