#!/usr/bin/env bash
# Functions for managing Docker containers, images, and runtime.

# Docker checks
check_docker() {
    command -v docker >/dev/null || return 1
    docker info >/dev/null 2>&1 || return 2
    docker ps >/dev/null 2>&1 || return 3
    return 0
}

install_docker() {
    warn "Docker is not installed."
    cecho "Would you like to install Docker now? (y/n)" "$CYAN"
    read -r response
    [[ "$response" =~ ^[Yy]$ ]] || error "Docker is required. Visit: https://docs.docker.com/engine/install/"

    info "Installing Docker..."

    [[ -f /etc/os-release ]] && . /etc/os-release || error "Cannot detect OS"

    case "${ID:-}" in
        ubuntu|debian)
            warn "Installing Docker requires sudo privileges..."
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gnupg lsb-release
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/$ID/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        fedora|rhel|centos)
            warn "Installing Docker requires sudo privileges..."
            sudo dnf -y install dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        arch|manjaro)
            warn "Installing Docker requires sudo privileges..."
            sudo pacman -S --noconfirm docker
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        *)
            error "Unsupported OS: ${ID:-unknown}. Visit: https://docs.docker.com/engine/install/"
            ;;
    esac

    success "Docker installed successfully!"
    configure_docker_nonroot
}

configure_docker_nonroot() {
    warn "Configuring Docker for non-root usage..."
    warn "This requires sudo to add you to the docker group..."

    getent group docker >/dev/null || sudo groupadd docker
    sudo usermod -aG docker "$USER"

    success "Docker configured for non-root usage!"
    warn "You need to log out and back in for group changes to take effect."
    warn "Or run: ${CYAN}newgrp docker"
    warn "Then run 'claudebox' again."
    info "Trying to activate docker group in current shell..."
    exec newgrp docker
}

docker_exec_root() {
    docker exec -u root "$@"
}

docker_exec_user() {
    docker exec -u "$DOCKER_USER" "$@"
}

# run_claudebox_container - Main entry point for container execution
# Usage: run_claudebox_container <container_name> <mode> [args...]
# Args:
#   container_name: Name for the container (empty for auto-generated)
#   mode: "interactive", "detached", "pipe", or "attached"
#   args: Commands to pass to claude in container
# Returns: Exit code from container
# Note: Handles all mounting, environment setup, and security configuration
run_claudebox_container() {
    local container_name="$1"
    local run_mode="$2"  # "interactive", "detached", "pipe", or "attached"
    shift 2
    local container_args=("$@")
    
    # Handle "attached" mode - start detached, wait, then attach
    if [[ "$run_mode" == "attached" ]]; then
        # Start detached
        run_claudebox_container "$container_name" "detached" "${container_args[@]}" >/dev/null
        
        # Show progress while container initializes
        fillbar
        
        # Wait for container to be ready
        while ! docker exec "$container_name" true ; do
            sleep 0.1
        done
        
        fillbar stop
        
        # Attach to ready container
        docker attach "$container_name"
        
        return
    fi
    
    local docker_args=()
    
    # Set run mode
    case "$run_mode" in
        "interactive")
            # Only use -it if we have a TTY
            if [ -t 0 ] && [ -t 1 ]; then
                docker_args+=("-it")
            fi
            # Use --rm for auto-cleanup unless it's an admin container
            # Admin containers need to persist so we can commit changes
            if [[ -z "$container_name" ]] || [[ "$container_name" != *"admin"* ]]; then
                docker_args+=("--rm")
            fi
            if [[ -n "$container_name" ]]; then
                docker_args+=("--name" "$container_name")
            fi
            docker_args+=("--init")
            ;;
        "detached")
            docker_args+=("-d")
            if [[ -n "$container_name" ]]; then
                docker_args+=("--name" "$container_name")
            fi
            ;;
        "pipe")
            docker_args+=("--rm" "--init")
            ;;
    esac
    
    # Always check for tmux socket and mount if available (or create one)
    local tmux_socket=""
    local tmux_socket_dir=""
    
    # If TMUX env var is set, extract socket path from it
    if [[ -n "${TMUX:-}" ]]; then
        # TMUX format is typically: /tmp/tmux-1000/default,23456,0
        tmux_socket="${TMUX%%,*}"
        tmux_socket_dir=$(dirname "$tmux_socket")
    else
        # Look for existing tmux socket or determine where to create one
        local uid=$(id -u)
        local default_socket_dir="/tmp/tmux-$uid"
        
        # Check common locations for existing sockets
        for socket_dir in "$default_socket_dir" "/var/run/tmux-$uid" "$HOME/.tmux"; do
            if [[ -d "$socket_dir" ]]; then
                # Find any socket in the directory
                for socket in "$socket_dir"/default "$socket_dir"/*; do
                    if [[ -S "$socket" ]]; then
                        tmux_socket="$socket"
                        tmux_socket_dir="$socket_dir"
                        break
                    fi
                done
                [[ -n "$tmux_socket" ]] && break
            fi
        done
        
        # If no socket found, ensure we have a socket directory for potential tmux usage
        if [[ -z "$tmux_socket" ]]; then
            tmux_socket_dir="$default_socket_dir"
            # Create the socket directory if it doesn't exist
            if [[ ! -d "$tmux_socket_dir" ]]; then
                mkdir -p "$tmux_socket_dir"
                chmod 700 "$tmux_socket_dir"
            fi
            
            # Check if tmux is installed and create a detached session if so
            if command -v tmux >/dev/null 2>&1; then
                # Create a minimal tmux server without attaching
                # This creates the socket but doesn't start any session
                tmux -S "$tmux_socket_dir/default" start-server \; 2>/dev/null || true
                if [[ -S "$tmux_socket_dir/default" ]]; then
                    tmux_socket="$tmux_socket_dir/default"
                    if [[ "$VERBOSE" == "true" ]]; then
                        echo "[DEBUG] Created tmux server socket at: $tmux_socket" >&2
                    fi
                fi
            fi
        fi
    fi
    
    # Mount the socket and directory if we have them
    if [[ -n "$tmux_socket_dir" ]] && [[ -d "$tmux_socket_dir" ]]; then
        # Always mount the socket directory
        docker_args+=(-v "$tmux_socket_dir:$tmux_socket_dir")
        if [[ "$VERBOSE" == "true" ]]; then
            echo "[DEBUG] Mounting tmux socket directory: $tmux_socket_dir" >&2
        fi
        
        # Mount specific socket if it exists
        if [[ -n "$tmux_socket" ]] && [[ -S "$tmux_socket" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "[DEBUG] Tmux socket found at: $tmux_socket" >&2
            fi
        fi
        
        # Pass TMUX env var if available
        [[ -n "${TMUX:-}" ]] && docker_args+=(-e "TMUX=$TMUX")
    fi
    
    # Standard configuration for ALL containers
    docker_args+=(
        -w /workspace
        -v "$PROJECT_DIR":/workspace
        -v "$PROJECT_PARENT_DIR":/home/$DOCKER_USER/.claudebox
    )
    
    # Ensure .claude directory exists
    if [[ ! -d "$PROJECT_SLOT_DIR/.claude" ]]; then
        mkdir -p "$PROJECT_SLOT_DIR/.claude"
    fi
    
    docker_args+=(-v "$PROJECT_SLOT_DIR/.claude":/home/$DOCKER_USER/.claude)
    
    # Mount .claude.json only if it already exists (from previous session)
    if [[ -f "$PROJECT_SLOT_DIR/.claude.json" ]]; then
        docker_args+=(-v "$PROJECT_SLOT_DIR/.claude.json":/home/$DOCKER_USER/.claude.json)
    fi
    
    # Mount .config directory
    docker_args+=(-v "$PROJECT_SLOT_DIR/.config":/home/$DOCKER_USER/.config)
    
    # Mount .cache directory
    docker_args+=(-v "$PROJECT_SLOT_DIR/.cache":/home/$DOCKER_USER/.cache)
    
    # Mount SSH directory
    docker_args+=(-v "$HOME/.ssh":"/home/$DOCKER_USER/.ssh:ro")
    
    # Docker-in-Docker support based on --docker-mode
    case "${DOCKER_MODE:-socket}" in
        "socket")
            if [[ -S /var/run/docker.sock ]]; then
                docker_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
                if [[ "$VERBOSE" == "true" ]]; then
                    echo "[DEBUG] Docker socket mounted for Docker-in-Docker support" >&2
                fi
            elif [[ "$VERBOSE" == "true" ]]; then
                echo "[DEBUG] Docker socket not available - DinD disabled" >&2
            fi
            ;;
        "sidecar")
            # Start sidecar container if not running
            start_docker_sidecar || {
                printf "ERROR: Failed to start Docker sidecar container\n" >&2
                return 1
            }
            
            # Mount sidecar socket and client library
            local project_hash
            project_hash=$(printf '%08x' "$(crc32_string "$PROJECT_DIR")")
            local socket_dir="/tmp/claudebox-sockets-$project_hash"
            local sidecar_socket="$socket_dir/sidecar.sock"
            if [[ -S "$sidecar_socket" ]]; then
                docker_args+=(-v "$sidecar_socket":/var/run/docker-sidecar.sock)
                local script_root
                script_root=$(dirname "$(dirname "${BASH_SOURCE[0]}")")
                docker_args+=(-v "$script_root/lib/docker-sidecar-client.sh":/usr/local/lib/claudebox/docker-sidecar-client.sh:ro)
                docker_args+=(-v "$script_root/build/docker-wrapper":/usr/local/bin/docker-wrapper:ro)
                docker_args+=(-e DOCKER_SIDECAR_MODE=true)
                if [[ "$VERBOSE" == "true" ]]; then
                    echo "[DEBUG] Docker sidecar mode enabled with socket: $sidecar_socket" >&2
                fi
            else
                printf "WARNING: Sidecar socket not found, falling back to no Docker mode\n" >&2
            fi
            ;;
        "none")
            if [[ "$VERBOSE" == "true" ]]; then
                echo "[DEBUG] Docker-in-Docker disabled by --docker-mode none" >&2
            fi
            ;;
    esac
    
    # Mount .env file if it exists in the project directory
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        docker_args+=(-v "$PROJECT_DIR/.env":/workspace/.env:ro)
        if [[ "$VERBOSE" == "true" ]]; then
            echo "[DEBUG] Mounting .env file from project directory" >&2
        fi
    fi
    
    # Add environment variables
    local project_name=$(basename "$PROJECT_DIR")
    local slot_name=$(basename "$PROJECT_SLOT_DIR")
    
    # Calculate slot index for hostname
    local slot_index=1  # default if we can't determine
    if [[ -n "$PROJECT_PARENT_DIR" ]] && [[ -n "$slot_name" ]]; then
        slot_index=$(get_slot_index "$slot_name" "$PROJECT_PARENT_DIR" 2>/dev/null || echo "1")
    fi
    
    docker_args+=(
        -e "NODE_ENV=${NODE_ENV:-production}"
        -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
        -e "CLAUDEBOX_PROJECT_NAME=$project_name"
        -e "CLAUDEBOX_SLOT_NAME=$slot_name"
        -e "TERM=${TERM:-xterm-256color}"
        -e "VERBOSE=${VERBOSE:-false}"
        -e "CLAUDEBOX_WRAP_TMUX=${CLAUDEBOX_WRAP_TMUX:-false}"
        -e "CLAUDEBOX_PANE_NAME=${CLAUDEBOX_PANE_NAME:-}"
        -e "CLAUDEBOX_TMUX_PANE=${CLAUDEBOX_TMUX_PANE:-}"
        --cap-add NET_ADMIN
        --cap-add NET_RAW
        "$IMAGE_NAME"
    )
    
    # Add any additional arguments
    if [[ ${#container_args[@]} -gt 0 ]]; then
        docker_args+=("${container_args[@]}")
    fi
    
    # Show security warnings for Docker socket access
    case "${DOCKER_MODE:-socket}" in
        "socket")
            if [[ -S /var/run/docker.sock ]]; then
                printf '%s\n' "🚨 SECURITY WARNING: Docker socket mounted - container has root-equivalent access to host!" >&2
                printf '%s\n' "   This enables Docker-in-Docker but grants significant host privileges." >&2
                printf '%s\n' "   Use --docker-mode none to disable Docker access." >&2
                printf '%s\n' "   Press Ctrl+C within 3 seconds to cancel..." >&2
                sleep 3
            fi
            ;;
        "safe")
            if [[ -S /var/run/docker.sock ]]; then
                printf '%s\n' "⚠️  Docker socket mounted read-only - some Docker operations may fail." >&2
                printf '%s\n' "   Note: Read-only still allows container creation with elevated privileges." >&2
            fi
            ;;
    esac
    
    # Run the container
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[DEBUG] Docker run command: docker run ${docker_args[*]}" >&2
    fi
    docker run "${docker_args[@]}"
    local exit_code=$?
    
    return $exit_code
}

check_container_exists() {
    local container_name="$1"
    
    # Check if container exists (running or stopped)
    if docker ps -a --filter "name=^${container_name}$" --format "{{.Names}}"  | grep -q "^${container_name}$"; then
        # Check if it's running
        if docker ps --filter "name=^${container_name}$" --format "{{.Names}}"  | grep -q "^${container_name}$"; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "none"
    fi
}

run_docker_build() {
    info "Running docker build..."
    export DOCKER_BUILDKIT=1
    
    # Check if we need to force rebuild due to template changes
    local no_cache_flag=""
    if [[ "${CLAUDEBOX_FORCE_NO_CACHE:-false}" == "true" ]]; then
        no_cache_flag="--no-cache"
        info "Forcing full rebuild (templates changed)"
    fi
    
    docker build \
        $no_cache_flag \
        --progress=${BUILDKIT_PROGRESS:-auto} \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        --build-arg USER_ID="$USER_ID" \
        --build-arg GROUP_ID="$GROUP_ID" \
        --build-arg USERNAME="$DOCKER_USER" \
        --build-arg NODE_VERSION="$NODE_VERSION" \
        --build-arg DELTA_VERSION="$DELTA_VERSION" \
        --build-arg REBUILD_TIMESTAMP="${CLAUDEBOX_REBUILD_TIMESTAMP:-}" \
        -f "$1" -t "$IMAGE_NAME" "$2" || error "Docker build failed"
}

# Docker Sidecar Management Functions

# Build sidecar image if needed
build_sidecar_image() {
    local sidecar_image="claudebox-sidecar:latest"
    
    # Check if sidecar image exists
    if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${sidecar_image}$"; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "[DEBUG] Building Docker sidecar image" >&2
        fi
        
        # Build the sidecar image
        local script_root
        script_root=$(dirname "$(dirname "${BASH_SOURCE[0]}")")
        
        docker build \
            --progress=${BUILDKIT_PROGRESS:-auto} \
            -f "$script_root/build/Dockerfile.sidecar" \
            -t "$sidecar_image" \
            "$script_root" || {
                printf "ERROR: Failed to build Docker sidecar image\n" >&2
                return 1
            }
    fi
}

# Start Docker sidecar container
start_docker_sidecar() {
    # Generate project hash using the same method as ClaudeBox container names
    local project_hash
    project_hash=$(printf '%08x' "$(crc32_string "$PROJECT_DIR")")
    
    local sidecar_name="claudebox-sidecar-$project_hash"
    local socket_dir="/tmp/claudebox-sockets-$project_hash"
    local sidecar_socket="$socket_dir/sidecar.sock"
    local sidecar_image="claudebox-sidecar:latest"
    
    # Check if sidecar is already running with a valid socket
    if docker ps --filter "name=^${sidecar_name}$" --format "{{.Names}}" | grep -q "^${sidecar_name}$"; then
        # Container is running, check if socket exists
        if [[ -S "$sidecar_socket" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "[DEBUG] Docker sidecar already running with valid socket: $sidecar_name" >&2
            fi
            return 0
        else
            # Container running but no socket - stop and restart it
            if [[ "$VERBOSE" == "true" ]]; then
                echo "[DEBUG] Docker sidecar running but socket missing, restarting: $sidecar_name" >&2
            fi
            docker stop "$sidecar_name" >/dev/null 2>&1 || true
            # Wait for container to stop
            sleep 1
        fi
    fi
    
    # Remove existing stopped container if present
    if docker ps -a --filter "name=^${sidecar_name}$" --format "{{.Names}}" | grep -q "^${sidecar_name}$"; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "[DEBUG] Removing stopped sidecar container: $sidecar_name" >&2
        fi
        docker rm "$sidecar_name" >/dev/null 2>&1 || true
    fi
    
    # Remove existing socket file or directory if present
    if [[ -S "$sidecar_socket" ]]; then
        rm -f "$sidecar_socket"
    elif [[ -d "$sidecar_socket" ]]; then
        rm -rf "$sidecar_socket"
    fi
    
    # Create a dedicated directory for the socket if it doesn't exist
    if [[ ! -d "$socket_dir" ]]; then
        mkdir -p "$socket_dir"
    fi
    
    # Socket filename for consistency
    local socket_filename="sidecar.sock"
    
    # Build sidecar image if needed
    build_sidecar_image || return 1
    
    # Start the sidecar container
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[DEBUG] Starting Docker sidecar container: $sidecar_name" >&2
    fi
    
    docker run -d \
        --name "$sidecar_name" \
        --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$socket_dir":/tmp/sockets \
        -e API_SOCKET="/tmp/sockets/$socket_filename" \
        -e SIDECAR_SECURITY_LEVEL="${SIDECAR_SECURITY_LEVEL:-moderate}" \
        -e SIDECAR_MAX_CONTAINERS="${SIDECAR_MAX_CONTAINERS:-10}" \
        -e SIDECAR_MAX_MEMORY="${SIDECAR_MAX_MEMORY:-2g}" \
        -e SIDECAR_MAX_CPUS="${SIDECAR_MAX_CPUS:-2}" \
        -e SIDECAR_RATE_LIMIT="${SIDECAR_RATE_LIMIT:-60}" \
        "$sidecar_image" >/dev/null || {
            printf "ERROR: Failed to start Docker sidecar container\n" >&2
            return 1
        }
    
    # Wait for sidecar to be ready (socket to appear)
    local wait_count=0
    while [[ ! -S "$sidecar_socket" ]] && [[ $wait_count -lt 30 ]]; do
        sleep 0.5
        wait_count=$((wait_count + 1))
    done
    
    if [[ ! -S "$sidecar_socket" ]]; then
        printf "ERROR: Docker sidecar failed to start (socket not found)\n" >&2
        # Clean up failed container
        docker rm -f "$sidecar_name" >/dev/null 2>&1 || true
        return 1
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[DEBUG] Docker sidecar ready at: $sidecar_socket" >&2
    fi
}

# Stop Docker sidecar container
stop_docker_sidecar() {
    # Generate project hash using the same method as ClaudeBox container names
    local project_hash
    project_hash=$(printf '%08x' "$(crc32_string "$PROJECT_DIR")")
    
    local sidecar_name="claudebox-sidecar-$project_hash"
    local socket_dir="/tmp/claudebox-sockets-$project_hash"
    local sidecar_socket="$socket_dir/sidecar.sock"
    
    # Stop the container if running
    if docker ps --filter "name=^${sidecar_name}$" --format "{{.Names}}" | grep -q "^${sidecar_name}$"; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "[DEBUG] Stopping Docker sidecar container: $sidecar_name" >&2
        fi
        docker stop "$sidecar_name" >/dev/null 2>&1 || true
    fi
    
    # Clean up socket file and directory
    if [[ -S "$sidecar_socket" ]]; then
        rm -f "$sidecar_socket"
    fi
    
    # Remove socket directory if empty
    if [[ -d "$socket_dir" ]] && [[ -z "$(ls -A "$socket_dir")" ]]; then
        rmdir "$socket_dir"
    fi
}

# Check Docker sidecar status
check_sidecar_status() {
    # Generate project hash using the same method as ClaudeBox container names
    local project_hash
    project_hash=$(printf '%08x' "$(crc32_string "$PROJECT_DIR")")
    
    local sidecar_name="claudebox-sidecar-$project_hash"
    local socket_dir="/tmp/claudebox-sockets-$project_hash"
    local sidecar_socket="$socket_dir/sidecar.sock"
    
    if docker ps --filter "name=^${sidecar_name}$" --format "{{.Names}}" | grep -q "^${sidecar_name}$"; then
        if [[ -S "$sidecar_socket" ]]; then
            echo "running"
        else
            echo "starting"
        fi
    else
        echo "stopped"
    fi
}

export -f check_docker install_docker configure_docker_nonroot docker_exec_root docker_exec_user run_claudebox_container check_container_exists run_docker_build
export -f build_sidecar_image start_docker_sidecar stop_docker_sidecar check_sidecar_status