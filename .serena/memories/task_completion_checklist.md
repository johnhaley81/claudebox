# ClaudeBox Task Completion Checklist

## Before Marking Any Task Complete

### 1. Code Quality Checks
- [ ] Bash 3.2 compatibility verified
- [ ] No associative arrays used
- [ ] No `${var^^}` or other incompatible expansions
- [ ] All variables properly quoted `"$var"`
- [ ] Using printf instead of echo
- [ ] Proper error handling with `if` statements (not `&&` or `||` with set -e)

### 2. Testing
- [ ] Run basic functionality test: `./main.sh`
- [ ] Test with --verbose flag to check for errors
- [ ] If Docker-related: verify container starts/stops properly
- [ ] If sidecar-related: check logs with `docker logs claudebox-sidecar-*`
- [ ] Run Bash 3.2 compatibility test if core functionality changed:
  ```bash
  ./tests/test_bash32_compat.sh
  ```

### 3. Docker Considerations
- [ ] If image changed: test rebuild doesn't break layer caching
- [ ] If container-related: verify --rm flag is preserved
- [ ] If sidecar-related: ensure socket communication works
- [ ] Check no orphaned containers: `docker ps -a | grep claudebox`

### 4. File Changes
- [ ] No unnecessary files created
- [ ] Existing files edited rather than recreated when possible
- [ ] No documentation files created unless requested
- [ ] .gitignore updated if new generated files/directories added

### 5. Output Cleanliness
- [ ] No unnecessary success messages added
- [ ] Debug output only shown with --verbose flag
- [ ] Error messages are clear and actionable
- [ ] No emoji unless explicitly requested

### 6. Safety Checks
- [ ] No secrets or keys exposed in code
- [ ] File permissions appropriate (executable for scripts)
- [ ] No breaking changes to existing functionality
- [ ] Slot system numbering preserved (starts at 1)

### 7. Documentation
- [ ] Code comments added for complex logic
- [ ] CLAUDE.md updated if major functionality added
- [ ] README.md updated if user-facing features changed

## Common Issues to Verify

### Docker Sidecar Specific
- Socket exists at `/tmp/claudebox-sockets-$project_hash/sidecar.sock`
- Container running: `docker ps | grep sidecar`
- No socket permission errors
- Request/response cycle works properly

### Container Management
- Containers clean up with --rm flag
- No duplicate containers for same slot
- Image names follow pattern: `claudebox-$project_hash`
- Slot detection works correctly

### Script Execution
- Scripts are executable: `chmod +x *.sh`
- Shebang is correct: `#!/usr/bin/env bash` or `#!/bin/bash`
- Libraries source correctly from lib/
- Functions are exported when needed

## Final Verification
```bash
# Quick smoke test
./main.sh --verbose create  # Should create new slot
./main.sh slots             # Should list slots
./main.sh revoke            # Should remove highest slot

# For sidecar changes
./main.sh --docker-mode sidecar --verbose
docker ps | grep sidecar    # Should show running sidecar
```

## Git Commit Preparation
- Use descriptive commit message
- Reference issue/feature if applicable
- Stash any experimental changes: `git stash`
- NEVER use `git restore HEAD`