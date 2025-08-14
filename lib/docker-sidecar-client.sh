#!/usr/bin/env bash
# Docker Sidecar Client Library
# Provides transparent Docker API access through sidecar proxy

set -Eeuo pipefail
IFS=$'\n\t'

# Configuration
SIDECAR_SOCKET="${SIDECAR_SOCKET:-/var/run/docker-sidecar.sock}"
SIDECAR_TIMEOUT="${SIDECAR_TIMEOUT:-30}"
FALLBACK_MODE="${SIDECAR_FALLBACK:-false}"

# Check if sidecar is available
is_sidecar_available() {
    [[ -S "$SIDECAR_SOCKET" ]]
}

# Send HTTP request to sidecar API
send_sidecar_request() {
    local method="$1"
    local path="$2"
    local body="${3:-{}}"
    
    if ! is_sidecar_available; then
        if [[ "$FALLBACK_MODE" == "true" ]]; then
            return 1  # Signal to use fallback
        else
            printf "ERROR: Sidecar socket not available at %s\n" "$SIDECAR_SOCKET" >&2
            return 2
        fi
    fi
    
    local content_length=${#body}
    
    # Construct HTTP request
    local http_request
    http_request=$(printf "%s %s HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$method" "$path" "$content_length" "$body")
    
    # Send request and capture response
    local response
    response=$(printf "%s" "$http_request" | timeout "$SIDECAR_TIMEOUT" nc -U "$SIDECAR_SOCKET" 2>/dev/null) || {
        printf "ERROR: Failed to communicate with sidecar API\n" >&2
        return 2
    }
    
    # Extract response body (skip HTTP headers)
    local response_body
    response_body=$(printf "%s" "$response" | awk '/^\r?$/{flag=1;next}flag')
    
    # Check if response indicates success
    local success
    success=$(printf "%s" "$response_body" | jq -r '.success // false' 2>/dev/null || echo "false")
    
    if [[ "$success" == "true" ]]; then
        # Extract result or output
        printf "%s" "$response_body" | jq -r '.result.output // .result.container_id // ""' 2>/dev/null || echo ""
        return 0
    else
        # Extract error message
        local error_msg
        error_msg=$(printf "%s" "$response_body" | jq -r '.error // "Unknown error"' 2>/dev/null || echo "API error")
        printf "ERROR: %s\n" "$error_msg" >&2
        return 1
    fi
}

# Docker ps implementation
docker_sidecar_ps() {
    local args=("$@")
    local all_flag=false
    local quiet_flag=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all)
                all_flag=true
                shift
                ;;
            -q|--quiet)
                quiet_flag=true
                shift
                ;;
            *)
                # Skip unknown arguments for now
                shift
                ;;
        esac
    done
    
    # Construct request
    local request_body
    request_body=$(jq -n \
        --arg op "docker_ps" \
        --argjson all "$all_flag" \
        --argjson quiet "$quiet_flag" \
        '{
            operation: $op,
            parameters: {
                all: $all,
                quiet: $quiet
            }
        }'
    )
    
    send_sidecar_request "GET" "/docker/ps" "$request_body"
}

# Docker images implementation
docker_sidecar_images() {
    local args=("$@")
    local all_flag=false
    local quiet_flag=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--all)
                all_flag=true
                shift
                ;;
            -q|--quiet)
                quiet_flag=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Construct request
    local request_body
    request_body=$(jq -n \
        --arg op "docker_images" \
        --argjson all "$all_flag" \
        --argjson quiet "$quiet_flag" \
        '{
            operation: $op,
            parameters: {
                all: $all,
                quiet: $quiet
            }
        }'
    )
    
    send_sidecar_request "GET" "/docker/images" "$request_body"
}

# Docker run implementation
docker_sidecar_run() {
    local args=("$@")
    local image=""
    local command_args=()
    local rm_flag=false
    local detach_flag=false
    local interactive_flag=false
    local tty_flag=false
    local memory=""
    local cpus=""
    local volumes=()
    local env_vars=()
    
    # Parse docker run arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rm)
                rm_flag=true
                shift
                ;;
            -d|--detach)
                detach_flag=true
                shift
                ;;
            -i|--interactive)
                interactive_flag=true
                shift
                ;;
            -t|--tty)
                tty_flag=true
                shift
                ;;
            -it|-ti)
                interactive_flag=true
                tty_flag=true
                shift
                ;;
            --memory)
                memory="$2"
                shift 2
                ;;
            --memory=*)
                memory="${1#--memory=}"
                shift
                ;;
            --cpus)
                cpus="$2"
                shift 2
                ;;
            --cpus=*)
                cpus="${1#--cpus=}"
                shift
                ;;
            -v|--volume)
                volumes+=("$2")
                shift 2
                ;;
            -v*)
                volumes+=("${1#-v}")
                shift
                ;;
            --volume=*)
                volumes+=("${1#--volume=}")
                shift
                ;;
            -e|--env)
                env_vars+=("$2")
                shift 2
                ;;
            -e*)
                env_vars+=("${1#-e}")
                shift
                ;;
            --env=*)
                env_vars+=("${1#--env=}")
                shift
                ;;
            -*)
                # Skip other flags for now
                shift
                ;;
            *)
                if [[ -z "$image" ]]; then
                    image="$1"
                else
                    command_args+=("$1")
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$image" ]]; then
        printf "ERROR: No image specified\n" >&2
        return 1
    fi
    
    # Build options object
    local options_obj="{}"
    
    if [[ "$rm_flag" == "true" ]]; then
        options_obj=$(printf "%s" "$options_obj" | jq '.rm = true')
    fi
    
    if [[ "$detach_flag" == "true" ]]; then
        options_obj=$(printf "%s" "$options_obj" | jq '.detach = true')
    fi
    
    if [[ "$interactive_flag" == "true" ]]; then
        options_obj=$(printf "%s" "$options_obj" | jq '.interactive = true')
    fi
    
    if [[ "$tty_flag" == "true" ]]; then
        options_obj=$(printf "%s" "$options_obj" | jq '.tty = true')
    fi
    
    if [[ -n "$memory" ]]; then
        options_obj=$(printf "%s" "$options_obj" | jq --arg mem "$memory" '.memory = $mem')
    fi
    
    if [[ -n "$cpus" ]]; then
        options_obj=$(printf "%s" "$options_obj" | jq --arg cpu "$cpus" '.cpus = $cpu')
    fi
    
    if [[ ${#volumes[@]} -gt 0 ]]; then
        local volumes_json
        volumes_json=$(printf '%s\n' "${volumes[@]}" | jq -R . | jq -s .)
        options_obj=$(printf "%s" "$options_obj" | jq --argjson vols "$volumes_json" '.volume = $vols')
    fi
    
    if [[ ${#env_vars[@]} -gt 0 ]]; then
        local env_json
        env_json=$(printf '%s\n' "${env_vars[@]}" | jq -R . | jq -s .)
        options_obj=$(printf "%s" "$options_obj" | jq --argjson envs "$env_json" '.env = $envs')
    fi
    
    # Build command array
    local command_json="[]"
    if [[ ${#command_args[@]} -gt 0 ]]; then
        command_json=$(printf '%s\n' "${command_args[@]}" | jq -R . | jq -s .)
    fi
    
    # Construct request
    local request_body
    request_body=$(jq -n \
        --arg op "docker_run" \
        --arg img "$image" \
        --argjson cmd "$command_json" \
        --argjson opts "$options_obj" \
        '{
            operation: $op,
            parameters: {
                image: $img,
                command: $cmd,
                options: $opts
            }
        }'
    )
    
    send_sidecar_request "POST" "/docker/run" "$request_body"
}

# Docker exec implementation
docker_sidecar_exec() {
    local args=("$@")
    local container_id=""
    local command_args=()
    local interactive_flag=false
    local tty_flag=false
    
    # Parse docker exec arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i|--interactive)
                interactive_flag=true
                shift
                ;;
            -t|--tty)
                tty_flag=true
                shift
                ;;
            -it|-ti)
                interactive_flag=true
                tty_flag=true
                shift
                ;;
            -*)
                # Skip other flags
                shift
                ;;
            *)
                if [[ -z "$container_id" ]]; then
                    container_id="$1"
                else
                    command_args+=("$1")
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$container_id" ]]; then
        printf "ERROR: No container ID specified\n" >&2
        return 1
    fi
    
    if [[ ${#command_args[@]} -eq 0 ]]; then
        printf "ERROR: No command specified\n" >&2
        return 1
    fi
    
    # Build options object
    local options_obj="{}"
    
    if [[ "$interactive_flag" == "true" ]]; then
        options_obj=$(printf "%s" "$options_obj" | jq '.interactive = true')
    fi
    
    if [[ "$tty_flag" == "true" ]]; then
        options_obj=$(printf "%s" "$options_obj" | jq '.tty = true')
    fi
    
    # Build command array
    local command_json
    command_json=$(printf '%s\n' "${command_args[@]}" | jq -R . | jq -s .)
    
    # Construct request
    local request_body
    request_body=$(jq -n \
        --arg op "docker_exec" \
        --arg container "$container_id" \
        --argjson cmd "$command_json" \
        --argjson opts "$options_obj" \
        '{
            operation: $op,
            parameters: {
                container_id: $container,
                command: $cmd,
                options: $opts
            }
        }'
    )
    
    send_sidecar_request "POST" "/docker/exec" "$request_body"
}

# Main docker command dispatcher
docker_sidecar_command() {
    local subcommand="${1:-}"
    
    # Handle special flags
    if [[ "$subcommand" == "--version" ]] || [[ "$subcommand" == "-v" ]]; then
        printf "Docker version 20.10.0 (sidecar mode)\n"
        return 0
    fi
    
    if [[ "$subcommand" == "--help" ]] || [[ "$subcommand" == "-h" ]]; then
        printf "Usage: docker COMMAND\n"
        printf "\nCommands available through sidecar:\n"
        printf "  ps          List containers\n"
        printf "  images      List images\n"
        printf "  run         Run a command in a new container\n"
        printf "  exec        Run a command in a running container\n"
        printf "  --version   Show version information\n"
        printf "  --help      Show this help message\n"
        return 0
    fi
    
    if [[ -z "$subcommand" ]]; then
        printf "Usage: docker COMMAND\n"
        printf "\nCommands available through sidecar:\n"
        printf "  ps          List containers\n"
        printf "  images      List images\n"
        printf "  run         Run a command in a new container\n"
        printf "  exec        Run a command in a running container\n"
        return 1
    fi
    
    shift
    
    case "$subcommand" in
        ps)
            docker_sidecar_ps "$@"
            ;;
        images)
            docker_sidecar_images "$@"
            ;;
        run)
            docker_sidecar_run "$@"
            ;;
        exec)
            docker_sidecar_exec "$@"
            ;;
        *)
            printf "ERROR: Unsupported command '%s' in sidecar mode\n" "$subcommand" >&2
            printf "Available commands: ps, images, run, exec\n" >&2
            return 1
            ;;
    esac
}

# Export main function for use by wrapper script
export -f docker_sidecar_command is_sidecar_available
export -f docker_sidecar_ps docker_sidecar_images docker_sidecar_run docker_sidecar_exec