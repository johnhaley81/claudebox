# Docker Sidecar Pattern Design for ClaudeBox

## Executive Summary

This document outlines the design for implementing a Docker sidecar pattern in ClaudeBox, providing secure Docker access through a proxy container that validates and filters operations.

## Motivation

The current Docker socket mounting approach (`--docker-mode socket`) provides root-equivalent access to the host system, creating significant security risks. The sidecar pattern offers a middle ground between functionality and security by:

1. Maintaining Docker capabilities
2. Adding security controls and filtering
3. Providing audit logging
4. Preventing dangerous operations

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Host System                          │
│                                                         │
│  ┌──────────────┐        ┌──────────────────────┐     │
│  │  ClaudeBox   │ ──────> │   Docker Sidecar    │     │
│  │  Container   │  REST   │     Container       │     │
│  │              │  API    │                     │     │
│  │ ┌──────────┐ │        │  ┌────────────────┐ │     │
│  │ │  Claude  │ │        │  │ Request Filter │ │     │
│  │ │   CLI    │ │        │  └────────────────┘ │     │
│  │ └──────────┘ │        │  ┌────────────────┐ │     │
│  └──────────────┘        │  │  Audit Logger  │ │     │
│                          │  └────────────────┘ │     │
│                          │  ┌────────────────┐ │     │
│                          │  │ Docker Client  │ │     │
│                          │  └────────────────┘ │     │
│                          └──────────┬──────────┘     │
│                                     │                 │
│                          ┌──────────▼──────────┐     │
│                          │   Docker Socket     │     │
│                          │ /var/run/docker.sock│     │
│                          └─────────────────────┘     │
└─────────────────────────────────────────────────────────┘
```

## Implementation Components

### 1. Sidecar Container (`lib/docker-sidecar/`)

#### `docker-sidecar-api.sh`
REST API server running in the sidecar container:
- Listens on Unix socket or TCP port
- Validates incoming requests
- Applies security policies
- Forwards approved requests to Docker daemon
- Returns filtered responses

#### `docker-sidecar-filter.sh`
Security filtering logic:
- Operation allowlist/blocklist
- Parameter validation
- Resource limit enforcement
- Dangerous flag detection

#### `docker-sidecar-logger.sh`
Audit logging system:
- Logs all requests with timestamps
- Records user, operation, parameters
- Tracks success/failure
- Generates security reports

### 2. ClaudeBox Client (`lib/docker-sidecar-client.sh`)

Client library for ClaudeBox to communicate with sidecar:
- Translates Docker commands to API requests
- Handles authentication with sidecar
- Manages connection pooling
- Provides fallback handling

### 3. Container Definitions

#### `Dockerfile.sidecar`
```dockerfile
FROM alpine:latest
RUN apk add --no-cache docker-cli bash jq curl
COPY lib/docker-sidecar/* /app/
ENTRYPOINT ["/app/docker-sidecar-api.sh"]
```

## Security Policies

### Default Allowlist Operations

```yaml
allowed_operations:
  - docker_ps
  - docker_images
  - docker_logs
  - docker_exec_readonly
  - docker_run_restricted
  - docker_build
  - docker_pull
  - docker_push_to_allowlist

blocked_operations:
  - docker_run_privileged
  - docker_run_host_network
  - docker_mount_sensitive_paths
  - docker_cap_add_dangerous
```

### Dangerous Flags Detection

```bash
DANGEROUS_FLAGS=(
    "--privileged"
    "--cap-add=SYS_ADMIN"
    "--cap-add=NET_ADMIN"
    "--net=host"
    "--pid=host"
    "--ipc=host"
    "-v /:/host"
    "-v /etc:/host-etc"
    "-v /var/run/docker.sock"
)
```

### Resource Limits

```yaml
resource_limits:
  max_containers_per_session: 10
  max_memory_per_container: 2G
  max_cpu_per_container: 2
  max_storage_per_container: 10G
  rate_limit_per_minute: 60
```

## Communication Protocol

### API Endpoints

```
POST /docker/run
POST /docker/exec
GET  /docker/ps
GET  /docker/images
GET  /docker/logs/{container_id}
POST /docker/build
DELETE /docker/containers/{container_id}
```

### Request Format

```json
{
  "operation": "docker_run",
  "parameters": {
    "image": "ubuntu:latest",
    "command": ["echo", "hello"],
    "options": {
      "rm": true,
      "memory": "512m"
    }
  },
  "auth_token": "..."
}
```

### Response Format

```json
{
  "success": true,
  "result": {
    "container_id": "abc123...",
    "output": "hello\n"
  },
  "filtered": ["--privileged flag removed"],
  "warnings": ["Memory limit enforced: 512m"]
}
```

## Integration with ClaudeBox

### New Docker Mode

```bash
--docker-mode sidecar
```

### Modified `lib/docker.sh`

```bash
case "${DOCKER_MODE:-socket}" in
    "sidecar")
        # Start sidecar container if not running
        start_docker_sidecar
        
        # Mount sidecar socket instead of Docker socket
        docker_args+=(-v /tmp/claudebox-sidecar.sock:/var/run/docker-sidecar.sock)
        
        # Set environment for Docker client wrapper
        docker_args+=(-e DOCKER_SIDECAR_MODE=true)
        ;;
esac
```

### Docker Command Wrapper

```bash
# /usr/local/bin/docker wrapper in ClaudeBox container
if [[ "$DOCKER_SIDECAR_MODE" == "true" ]]; then
    docker-sidecar-client "$@"
else
    /usr/bin/docker "$@"
fi
```

## Deployment Strategy

### Container Orchestration

```bash
# Start sidecar first
docker run -d \
    --name claudebox-sidecar-$PROJECT_HASH \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /tmp/claudebox-sidecar.sock:/var/run/api.sock \
    claudebox-sidecar:latest

# Then start ClaudeBox with sidecar mode
./main.sh --docker-mode sidecar
```

### Lifecycle Management

1. **Startup**: Check if sidecar exists, start if needed
2. **Health Checks**: Monitor sidecar availability
3. **Cleanup**: Stop sidecar when ClaudeBox exits
4. **Error Handling**: Fallback to no Docker if sidecar fails

## Configuration File

`~/.claudebox/docker-sidecar.yaml`:

```yaml
sidecar:
  enabled: true
  security_level: strict  # strict, moderate, permissive
  
policies:
  allow_privileged: false
  allow_host_mounts: false
  max_containers: 10
  allowed_images:
    - ubuntu:*
    - alpine:*
    - node:*
    - python:*
  blocked_images:
    - *:latest  # Force specific tags
  
logging:
  enabled: true
  path: ~/.claudebox/docker-audit.log
  retention_days: 30
  
rate_limiting:
  requests_per_minute: 60
  burst_size: 10
```

## Security Benefits

### Compared to Socket Mounting

| Aspect | Socket Mount | Sidecar |
|--------|-------------|---------|
| Host Root Access | Yes | No* |
| Operation Filtering | No | Yes |
| Audit Logging | No | Yes |
| Resource Limits | No | Yes |
| Rate Limiting | No | Yes |
| Dangerous Flag Prevention | No | Yes |

*Sidecar still has Docker access but can't be bypassed by container

### Attack Surface Reduction

1. **No Direct Socket Access**: Container can't bypass sidecar
2. **Request Validation**: All operations validated before execution
3. **Parameter Sanitization**: Dangerous parameters removed
4. **Resource Constraints**: Prevents resource exhaustion
5. **Audit Trail**: All operations logged for forensics

## Implementation Phases

### Phase 1: MVP (Week 1)
- Basic sidecar container with REST API
- Simple allow/block list for operations
- Integration with `--docker-mode sidecar`

### Phase 2: Security Hardening (Week 2)
- Parameter validation and sanitization
- Resource limit enforcement
- Rate limiting implementation

### Phase 3: Advanced Features (Week 3)
- Audit logging system
- Configuration file support
- Web UI for log viewing

### Phase 4: Production Ready (Week 4)
- Performance optimization
- High availability support
- Documentation and testing

## Testing Strategy

### Unit Tests
- Filter logic validation
- API endpoint testing
- Client library testing

### Integration Tests
- End-to-end Docker operations
- Security policy enforcement
- Error handling scenarios

### Security Tests
- Attempt bypasses
- Privilege escalation attempts
- Resource exhaustion tests

## Performance Considerations

### Overhead Analysis
- Additional network hop: ~1-2ms
- Request validation: ~5-10ms
- Total overhead: <15ms per operation

### Optimization Strategies
- Connection pooling
- Request batching
- Caching for read operations
- Async logging

## Migration Path

1. **Coexistence**: Both socket and sidecar modes available
2. **Deprecation Warning**: Warn about socket mode risks
3. **Default Change**: Make sidecar default mode
4. **Socket Removal**: Eventually remove socket mode

## Open Questions

1. Should sidecar support Docker Compose operations?
2. How to handle Docker build contexts efficiently?
3. Should we support custom security policies per project?
4. Integration with container registries?
5. Support for Docker Swarm/Kubernetes?

## Conclusion

The sidecar pattern provides a pragmatic balance between Docker functionality and security. While it doesn't eliminate all risks (the sidecar itself has Docker access), it significantly reduces the attack surface and provides defense-in-depth through:

- Operation filtering
- Parameter validation  
- Resource limits
- Audit logging
- Rate limiting

This makes ClaudeBox safer for use in less-isolated environments while maintaining the Docker capabilities developers need.

## Next Steps

1. Review and approve design
2. Create proof-of-concept implementation
3. Security review by team
4. Performance testing
5. Gradual rollout with feature flag