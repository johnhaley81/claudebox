# Docker Sidecar Implementation Details

## Overview
The Docker sidecar pattern in ClaudeBox provides secure Docker-in-Docker functionality without exposing the host Docker socket directly to containers.

## Architecture
```
Host System
    ├── Docker Daemon (host)
    ├── ClaudeBox Sidecar Container
    │   ├── API Server (docker-sidecar-api.sh)
    │   ├── Unix Socket (/tmp/sockets/sidecar.sock)
    │   └── Security Filters
    └── ClaudeBox User Container
        ├── Docker Wrapper (/usr/local/bin/docker-wrapper)
        ├── Sidecar Client (docker-sidecar-client.sh)
        └── Socket Mount (/var/run/docker-sidecar.sock)
```

## Key Files

### Sidecar Implementation
- `lib/docker-sidecar/docker-sidecar-api.sh` - Main API server
- `lib/docker-sidecar/docker-sidecar-filter.sh` - Security filters
- `lib/docker-sidecar/docker-sidecar-logger.sh` - Audit logging
- `lib/docker-sidecar-client.sh` - Client library for containers
- `lib/docker-sidecar-config.sh` - Configuration management
- `build/docker-wrapper` - Docker command wrapper script
- `build/Dockerfile.sidecar` - Sidecar container definition

### Integration Points
- `lib/docker.sh` - Functions: `build_sidecar_image()`, `start_docker_sidecar()`, `stop_docker_sidecar()`
- `main.sh` - Handles `--docker-mode sidecar` flag
- `lib/cli.sh` - Parses DOCKER_MODE environment variable

## Socket Communication

### Socket Path
```bash
/tmp/claudebox-sockets-$project_hash/sidecar.sock
```
Where `$project_hash` is calculated as: `printf '%08x' "$(crc32_string "$PROJECT_DIR")"`

### API Endpoints
- `GET /docker/ps` - List containers
- `GET /docker/images` - List images  
- `POST /docker/run` - Run container
- `POST /docker/exec` - Execute in container

### Request Format
```http
POST /docker/ps HTTP/1.1
Content-Type: application/json
Content-Length: 51

{"operation": "docker_ps", "all": false, "quiet": false}
```

## Current Implementation Status

### Working
- ✅ Sidecar container builds and starts
- ✅ Unix socket is created at correct path
- ✅ Docker wrapper is installed in user containers
- ✅ Basic commands (--version) work through wrapper
- ✅ Socket permissions and mounting work correctly

### Issues to Fix
- ⚠️ Netcat server loop doesn't handle bidirectional communication properly
- ⚠️ HTTP request/response cycle incomplete
- ⚠️ Some Docker commands timeout instead of returning results

## Debugging Commands

### Check Sidecar Status
```bash
# Check if running
docker ps | grep claudebox-sidecar-d07f2ac7

# View logs
docker logs claudebox-sidecar-d07f2ac7

# Check socket exists
ls -la /tmp/claudebox-sockets-*/sidecar.sock

# Test socket directly
echo '{"operation": "docker_ps"}' | nc -U /tmp/claudebox-sockets-*/sidecar.sock
```

### Manual Testing
```bash
# Test wrapper directly
docker run --rm --entrypoint bash \
  -v /tmp/claudebox-sockets-d07f2ac7/sidecar.sock:/var/run/docker-sidecar.sock \
  -v $PWD/lib/docker-sidecar-client.sh:/usr/local/lib/claudebox/docker-sidecar-client.sh:ro \
  -v $PWD/build/docker-wrapper:/usr/local/bin/docker-wrapper:ro \
  -e DOCKER_SIDECAR_MODE=true \
  claudebox-users_john_repos_mcp_servers_graphile_migrate_d07f2ac7 \
  -c '/usr/local/bin/docker-wrapper --version'
```

### Rebuild Sidecar
```bash
# Stop and remove old sidecar
docker stop claudebox-sidecar-d07f2ac7
docker rmi claudebox-sidecar:latest

# Rebuild without cache
docker build --no-cache -f build/Dockerfile.sidecar -t claudebox-sidecar:latest .

# Start new sidecar
./main.sh --docker-mode sidecar --verbose
```

## Security Considerations
- Sidecar runs as non-root user (sidecar:sidecar, UID/GID 1000)
- Security filters validate all Docker commands
- Audit logging tracks all operations
- Rate limiting prevents abuse
- Network isolation between containers

## Known Limitations
- Only supports subset of Docker commands (ps, images, run, exec)
- Synchronous request/response model
- Single connection at a time
- No streaming support for logs or attach