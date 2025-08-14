#!/usr/bin/env bash
# Docker Sidecar API Server
# Provides secure Docker access through REST API proxy

set -Eeuo pipefail
IFS=$'\n\t'

# Source dependencies
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/docker-sidecar-filter.sh"
source "$SCRIPT_DIR/docker-sidecar-logger.sh"

readonly API_SOCKET="${API_SOCKET:-/var/run/api.sock}"
readonly DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"

# API request handlers
handle_docker_ps() {
    local request="$1"
    
    log_request "docker_ps" "$request"
    
    # Extract parameters from request
    local params=$(printf '%s\n' "$request" | jq -r '.parameters // {}')
    
    # Build docker ps command
    local docker_cmd=("docker" "ps")
    
    # Add common flags if present in params
    if printf '%s\n' "$params" | jq -e '.all // false' >/dev/null; then
        docker_cmd+=("-a")
    fi
    
    if printf '%s\n' "$params" | jq -e '.quiet // false' >/dev/null; then
        docker_cmd+=("-q")
    fi
    
    # Execute and return result
    local output
    local exit_code=0
    output=$("${docker_cmd[@]}" 2>&1) || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        printf '{"success": true, "result": {"output": %s}}' "$(printf '%s\n' "$output" | jq -R -s .)"
    else
        printf '{"success": false, "error": %s}' "$(printf '%s\n' "$output" | jq -R -s .)"
    fi
    
    log_response "docker_ps" $exit_code "$output"
}

handle_docker_images() {
    local request="$1"
    
    log_request "docker_images" "$request"
    
    # Extract parameters from request  
    local params=$(printf '%s\n' "$request" | jq -r '.parameters // {}')
    
    # Build docker images command
    local docker_cmd=("docker" "images")
    
    # Add common flags if present in params
    if printf '%s\n' "$params" | jq -e '.all // false' >/dev/null; then
        docker_cmd+=("-a")
    fi
    
    if printf '%s\n' "$params" | jq -e '.quiet // false' >/dev/null; then
        docker_cmd+=("-q")
    fi
    
    # Execute and return result
    local output
    local exit_code=0
    output=$("${docker_cmd[@]}" 2>&1) || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        printf '{"success": true, "result": {"output": %s}}' "$(printf '%s\n' "$output" | jq -R -s .)"
    else
        printf '{"success": false, "error": %s}' "$(printf '%s\n' "$output" | jq -R -s .)"
    fi
    
    log_response "docker_images" $exit_code "$output"
}

handle_docker_run() {
    local request="$1"
    
    log_request "docker_run" "$request"
    
    # Apply security filtering first
    local filtered_request
    filtered_request=$(apply_security_filters "$request") || {
        local error="Security filters blocked this request"
        printf '{"success": false, "error": %s}' "$(printf '%s\n' "$error" | jq -R -s .)"
        log_response "docker_run" 1 "$error"
        return 1
    }
    
    # Extract filtered parameters
    local params=$(printf '%s\n' "$filtered_request" | jq -r '.parameters')
    local image=$(printf '%s\n' "$params" | jq -r '.image')
    local command=$(printf '%s\n' "$params" | jq -r '.command[]? // empty')
    local options=$(printf '%s\n' "$params" | jq -r '.options // {}')
    
    # Build docker run command
    local docker_cmd=("docker" "run")
    
    # Add options
    if printf '%s\n' "$options" | jq -e '.rm // false' >/dev/null; then
        docker_cmd+=("--rm")
    fi
    
    if printf '%s\n' "$options" | jq -e '.detach // false' >/dev/null; then
        docker_cmd+=("-d")
    fi
    
    if printf '%s\n' "$options" | jq -e '.interactive // false' >/dev/null; then
        docker_cmd+=("-i")
    fi
    
    if printf '%s\n' "$options" | jq -e '.tty // false' >/dev/null; then
        docker_cmd+=("-t")
    fi
    
    # Add memory limit if specified
    local memory_limit
    memory_limit=$(printf '%s\n' "$options" | jq -r '.memory // empty')
    if [[ -n "$memory_limit" ]]; then
        docker_cmd+=("--memory" "$memory_limit")
    fi
    
    # Add CPU limit if specified
    local cpu_limit
    cpu_limit=$(printf '%s\n' "$options" | jq -r '.cpus // empty')
    if [[ -n "$cpu_limit" ]]; then
        docker_cmd+=("--cpus" "$cpu_limit")
    fi
    
    # Add image
    docker_cmd+=("$image")
    
    # Add command if present
    if [[ -n "$command" ]]; then
        while IFS= read -r cmd_part; do
            docker_cmd+=("$cmd_part")
        done <<< "$command"
    fi
    
    # Execute and return result
    local output
    local exit_code=0
    output=$("${docker_cmd[@]}" 2>&1) || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        local container_id
        container_id=$(printf '%s\n' "$output" | head -n1)
        printf '{"success": true, "result": {"container_id": %s, "output": %s}}' \
            "$(printf '%s\n' "$container_id" | jq -R -s .)" \
            "$(printf '%s\n' "$output" | jq -R -s .)"
    else
        printf '{"success": false, "error": %s}' "$(printf '%s\n' "$output" | jq -R -s .)"
    fi
    
    log_response "docker_run" $exit_code "$output"
}

handle_docker_exec() {
    local request="$1"
    
    log_request "docker_exec" "$request"
    
    # Apply security filtering
    local filtered_request
    filtered_request=$(apply_security_filters "$request") || {
        local error="Security filters blocked this request"
        printf '{"success": false, "error": %s}' "$(printf '%s\n' "$error" | jq -R -s .)"
        log_response "docker_exec" 1 "$error"
        return 1
    }
    
    # Extract parameters
    local params=$(printf '%s\n' "$filtered_request" | jq -r '.parameters')
    local container_id=$(printf '%s\n' "$params" | jq -r '.container_id')
    local command=$(printf '%s\n' "$params" | jq -r '.command[]? // empty')
    local options=$(printf '%s\n' "$params" | jq -r '.options // {}')
    
    # Build docker exec command
    local docker_cmd=("docker" "exec")
    
    # Add options
    if printf '%s\n' "$options" | jq -e '.interactive // false' >/dev/null; then
        docker_cmd+=("-i")
    fi
    
    if printf '%s\n' "$options" | jq -e '.tty // false' >/dev/null; then
        docker_cmd+=("-t")
    fi
    
    # Add container ID
    docker_cmd+=("$container_id")
    
    # Add command
    if [[ -n "$command" ]]; then
        while IFS= read -r cmd_part; do
            docker_cmd+=("$cmd_part")
        done <<< "$command"
    fi
    
    # Execute and return result
    local output
    local exit_code=0
    output=$("${docker_cmd[@]}" 2>&1) || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        printf '{"success": true, "result": {"output": %s}}' "$(printf '%s\n' "$output" | jq -R -s .)"
    else
        printf '{"success": false, "error": %s}' "$(printf '%s\n' "$output" | jq -R -s .)"
    fi
    
    log_response "docker_exec" $exit_code "$output"
}

# HTTP request parser
parse_http_request() {
    local request_line=""
    local content_length=0
    local body=""
    
    # Read request line
    IFS= read -r request_line
    
    # Read headers
    while IFS= read -r header; do
        # Remove carriage return
        header="${header%$'\r'}"
        
        # Empty line indicates end of headers
        if [[ -z "$header" ]]; then
            break
        fi
        
        # Extract Content-Length
        if [[ "$header" =~ ^[Cc]ontent-[Ll]ength:\ *([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done
    
    # Read body if Content-Length is specified
    if [[ $content_length -gt 0 ]]; then
        body=$(dd bs=1 count="$content_length" 2>/dev/null)
    fi
    
    # Parse request line
    local method path protocol
    read -r method path protocol <<< "$request_line"
    
    # Output parsed request
    printf '%s\n' "$method"
    printf '%s\n' "$path"
    printf '%s\n' "$body"
}

# Main request handler
handle_request() {
    local method="$1"
    local path="$2"
    local body="$3"
    
    local response=""
    local status="200 OK"
    
    case "$method" in
        "GET")
            case "$path" in
                "/docker/ps")
                    response=$(handle_docker_ps "${body:-{}}")
                    ;;
                "/docker/images")
                    response=$(handle_docker_images "${body:-{}}")
                    ;;
                *)
                    status="404 Not Found"
                    response='{"success": false, "error": "Endpoint not found"}'
                    ;;
            esac
            ;;
        "POST")
            case "$path" in
                "/docker/run")
                    response=$(handle_docker_run "$body")
                    ;;
                "/docker/exec")
                    response=$(handle_docker_exec "$body")
                    ;;
                *)
                    status="404 Not Found"
                    response='{"success": false, "error": "Endpoint not found"}'
                    ;;
            esac
            ;;
        *)
            status="405 Method Not Allowed"
            response='{"success": false, "error": "Method not allowed"}'
            ;;
    esac
    
    # Send HTTP response
    printf "HTTP/1.1 %s\r\n" "$status"
    printf "Content-Type: application/json\r\n"
    printf "Content-Length: %d\r\n" "${#response}"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "$response"
}

# Main server loop
start_server() {
    # Remove existing socket if present
    if [[ -S "$API_SOCKET" ]]; then
        rm -f "$API_SOCKET"
    fi
    
    # Ensure Docker socket is accessible
    if [[ ! -S "$DOCKER_SOCKET" ]]; then
        printf "ERROR: Docker socket not found at %s\n" "$DOCKER_SOCKET" >&2
        exit 1
    fi
    
    # Initialize logging
    init_logging
    
    printf "Starting Docker Sidecar API server on %s\n" "$API_SOCKET"
    
    # Create the socket directory if it doesn't exist
    local socket_dir
    socket_dir=$(dirname "$API_SOCKET")
    if [[ ! -d "$socket_dir" ]]; then
        mkdir -p "$socket_dir"
    fi
    
    # Start the socket server
    printf "Starting socket listener...\n"
    
    # Use a simple persistent approach with netcat
    while true; do
        # Start netcat listening on the socket
        printf "Waiting for connection on %s\n" "$API_SOCKET" >&2
        
        # Handle one connection at a time using netcat
        nc -l -U "$API_SOCKET" | {
            # Read the request
            local request_lines=()
            local line
            local content_length=0
            local reading_headers=true
            
            # Read headers
            while IFS= read -r line; do
                # Remove carriage return if present
                line="${line%$'\r'}"
                
                # Empty line marks end of headers
                if [[ -z "$line" ]] && [[ "$reading_headers" == "true" ]]; then
                    reading_headers=false
                    break
                fi
                
                # Store the line
                request_lines+=("$line")
                
                # Check for Content-Length header
                if [[ "$line" =~ ^Content-Length:\ *([0-9]+) ]]; then
                    content_length="${BASH_REMATCH[1]}"
                fi
            done
            
            # Read body if Content-Length is specified
            local body=""
            if [[ "$content_length" -gt 0 ]]; then
                body=$(head -c "$content_length")
            fi
            
            # Parse the request line
            local request_line="${request_lines[0]:-}"
            local method path
            if [[ -n "$request_line" ]] && [[ "$request_line" =~ ^([A-Z]+)\ +([^\ ]+) ]]; then
                method="${BASH_REMATCH[1]}"
                path="${BASH_REMATCH[2]}"
            else
                method="GET"
                path="/"
            fi
            
            # Handle the request and send response
            printf "Handling %s %s\n" "$method" "$path" >&2
            handle_request "$method" "$path" "$body"
        }
        
        # Check if socket still exists, if not recreate it
        if [[ ! -S "$API_SOCKET" ]]; then
            printf "Socket disappeared, will be recreated on next iteration\n" >&2
        fi
        
        # Small delay between connections
        sleep 0.05
    done
}

# Signal handlers
cleanup() {
    printf "\nShutting down Docker Sidecar API server\n"
    if [[ -S "$API_SOCKET" ]]; then
        rm -f "$API_SOCKET"
    fi
    exit 0
}

trap 'cleanup' INT TERM EXIT

# Start server if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    start_server
fi

# Export functions for testing
export -f handle_docker_ps handle_docker_images handle_docker_run handle_docker_exec
export -f parse_http_request handle_request start_server