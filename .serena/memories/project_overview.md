# ClaudeBox Project Overview

## Purpose
ClaudeBox is a Docker-based development environment for Claude Code (Anthropic's AI coding assistant). It provides:
- Fully containerized, reproducible development environments
- Pre-configured language stacks and development profiles
- Project isolation with separate Docker images, settings, and data
- Multi-instance support for working on multiple projects simultaneously
- Security features including network isolation with project-specific firewall allowlists

## Tech Stack
- **Primary Language**: Bash (3.2 compatible for macOS support)
- **Containerization**: Docker
- **Shell**: Zsh with oh-my-zsh and powerline
- **Package Management**: apt (in containers), uv (for Python)
- **Testing**: Custom bash test scripts
- **Version**: 2.0.0

## Key Components
1. **main.sh** - Main entry point script
2. **lib/** - Library modules for various functionality:
   - `common.sh` - Shared utilities, logging, error handling
   - `docker.sh` - Docker operations, image building, container management
   - `config.sh` - Configuration loading/saving
   - `project.sh` - Per-project isolation, environment switching
   - `cli.sh` - CLI argument parsing and processing
   - `commands.*.sh` - Various command implementations
   - `docker-sidecar/` - Docker-in-Docker sidecar implementation

3. **build/** - Docker build files and scripts:
   - `Dockerfile` - Main container definition
   - `Dockerfile.sidecar` - Sidecar container for Docker-in-Docker
   - `docker-entrypoint` - Container entrypoint script
   - `docker-wrapper` - Docker command wrapper for sidecar mode

4. **templates/** - Template files for Dockerfile and dockerignore

## Project Structure
```
claudebox/
├── main.sh              # Entry point
├── lib/                 # Library modules
│   ├── common.sh
│   ├── docker.sh
│   ├── config.sh
│   ├── project.sh
│   ├── cli.sh
│   ├── commands.*.sh
│   └── docker-sidecar/
├── build/              # Docker build files
├── templates/          # Template files
├── tests/              # Test scripts
├── docs/               # Documentation
└── README.md
```

## Key Features
- **Development Profiles**: Pre-configured stacks (Python, Rust, Go, C/C++, Node.js, etc.)
- **Docker Sidecar Mode**: Secure Docker-in-Docker support
- **Project Isolation**: Complete separation between projects
- **Multi-slot System**: Multiple authenticated Claude instances per project
- **Firewall Management**: Network isolation with allowlists
- **Tmux Integration**: Socket mounting for multi-pane workflows