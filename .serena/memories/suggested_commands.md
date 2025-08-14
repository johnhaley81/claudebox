# ClaudeBox Development Commands

## Core ClaudeBox Commands
```bash
# Main entry point
./main.sh                    # Run ClaudeBox
claudebox                    # Run installed version

# Common operations
claudebox create             # Create new slot
claudebox slot <n>           # Launch specific slot
claudebox slots              # List all slots
claudebox revoke             # Remove highest slot
claudebox revoke all         # Remove all unused slots
claudebox rebuild            # Force rebuild of Docker image
claudebox profiles           # List available profiles
claudebox projects           # List all projects
claudebox info               # Show project info
claudebox clean              # Cleanup menu
claudebox shell              # Open transient shell
claudebox shell admin        # Open admin shell (sudo enabled)
```

## Development Commands
```bash
# Add/remove development profiles
claudebox add python rust    # Add profiles
claudebox remove rust        # Remove profiles

# Install packages
claudebox install <packages> # Install apt packages

# Firewall management
claudebox allowlist          # View/edit firewall allowlist

# Docker modes
claudebox --docker-mode sidecar  # Use Docker sidecar
claudebox --docker-mode socket    # Use Docker socket (default)
claudebox --docker-mode none      # No Docker access

# Flags
claudebox --verbose          # Show detailed output
claudebox --enable-sudo      # Enable sudo without password
claudebox --disable-firewall # Disable network restrictions
```

## Testing Commands
```bash
# Run tests
./tests/test_bash32_compat.sh       # Test Bash 3.2 compatibility
./tests/test_sidecar_functionality.sh # Test sidecar functionality
./tests/test_sidecar_security.sh    # Test sidecar security
./tests/test_in_bash32_docker.sh    # Test in Bash 3.2 Docker
```

## Docker Commands
```bash
# Build operations
docker build -f build/Dockerfile -t claudebox-core .
docker build -f build/Dockerfile.sidecar -t claudebox-sidecar:latest .
docker build --no-cache -f build/Dockerfile.sidecar -t claudebox-sidecar:latest .

# Container management
docker ps | grep claudebox           # List ClaudeBox containers
docker logs claudebox-sidecar-<hash> # Check sidecar logs
docker stop claudebox-sidecar-<hash> # Stop sidecar
docker rm claudebox-sidecar-<hash>   # Remove sidecar

# Image management
docker images | grep claudebox       # List ClaudeBox images
docker rmi claudebox-<project>       # Remove project image
```

## Git Commands (macOS/Darwin)
```bash
git status                   # Check status
git add .                    # Stage all changes
git commit -m "message"      # Commit changes
git diff                     # Show unstaged changes
git log --oneline -10        # Show recent commits
git stash                    # Stash changes (NEVER use git restore HEAD)
```

## System Commands (macOS/Darwin)
```bash
# File operations
ls -la                       # List with hidden files
find . -name "*.sh"          # Find shell scripts
grep -r "pattern" .          # Search recursively
cksum file                   # Calculate checksum (for CRC32)

# Process management
ps aux | grep claudebox      # Find ClaudeBox processes
kill -9 PID                  # Force kill process

# Permissions
chmod +x script.sh           # Make executable
chown user:group file        # Change ownership

# macOS specific
open .                       # Open in Finder
pbcopy < file                # Copy to clipboard
pbpaste > file               # Paste from clipboard
```

## Debug Commands
```bash
# Verbose mode for debugging
bash -x ./main.sh            # Trace execution
set -x                       # Enable debug in script
set +x                       # Disable debug

# Check environment
env | grep CLAUDEBOX         # Check ClaudeBox variables
echo $PROJECT_DIR            # Check project directory
echo $DOCKER_MODE            # Check Docker mode

# Socket debugging
ls -la /tmp/claudebox-sockets-*     # Check socket directories
test -S /path/to/socket && echo "Socket exists"
nc -U /path/to/socket               # Test Unix socket connection
```

## Project Structure Commands
```bash
# Navigate project
cd /Users/john/repos/claudebox  # Project root
cd lib/                          # Library modules
cd build/                        # Docker build files
cd lib/docker-sidecar/           # Sidecar implementation

# Source libraries (in scripts)
source lib/common.sh             # Load common utilities
source lib/docker.sh             # Load Docker functions
source lib/project.sh            # Load project functions
```

## Important Notes
- Always ensure Bash 3.2 compatibility
- Use printf instead of echo
- Quote all variables
- Test changes before committing
- Never use `git restore HEAD` - use `git stash` instead