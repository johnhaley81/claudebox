# ClaudeBox Code Style and Conventions

## Bash Scripting Standards

### Compatibility
- **CRITICAL**: Bash 3.2 compatibility ONLY (for macOS support)
- No associative arrays
- No `${var^^}` uppercase expansion  
- No `[[ -v var ]]` variable checks
- Use `[ "$var" = "" ]` instead of `[[ ]]` for string comparisons in some cases

### Safety Flags
- Scripts often use `set -euo pipefail` for safety
- `-e`: Exit on non-zero status
- `-u`: Exit on undefined variables
- `-o pipefail`: Fail on pipe errors
- `IFS=$'\n\t'` to prevent word-splitting issues

### Error Handling with set -e
**CRITICAL**: When using `set -e`:
- NEVER use `&&` for conditional execution - use `if` statements
- NEVER use `||` as a fallback - handle errors explicitly
- ALWAYS use if/then/fi for conditional logic
- NO SHORTCUTS - they will cause script exit

Example:
```bash
# WRONG - exits script when VERBOSE != "true"
[[ "$VERBOSE" == "true" ]] && echo "Debug"

# CORRECT - won't exit
if [[ "$VERBOSE" == "true" ]]; then
    echo "Debug"
fi
```

### Output Standards
- **ALWAYS use printf** instead of echo
- `printf '%s\n' "$var"` instead of `echo "$var"`
- printf is portable and predictable
- **NO UNNECESSARY OUTPUT** - ClaudeBox values clean output
- Don't add success messages for every operation
- Verbose mode exists for detailed output

### Naming Conventions
- Functions: `snake_case` (e.g., `start_docker_sidecar`)
- Global variables: `UPPER_SNAKE_CASE` 
- Local variables: `lower_snake_case`
- Constants: `readonly UPPER_SNAKE_CASE`

### Function Structure
```bash
function_name() {
    local var1="$1"
    local var2="${2:-default}"
    
    # Function logic
    
    return 0  # Explicit return codes
}
```

### Common Patterns
- Parameter expansion: `${var:-default}`
- Array iteration: `for item in "${array[@]}"`
- Command substitution: `$(command)` not backticks
- Quoting: Always quote variables `"$var"`

## Critical Design Decisions

### Container Management
- Named containers WITH --rm flag (intentional)
- Containers are ephemeral and auto-delete
- Slot system tracks availability
- DO NOT remove --rm flag

### Docker Images  
- Images shared across slots
- Layer caching is critical
- DO NOT force --no-cache unless requested
- Rebuilds should be FAST

### Slot System
- Slots start at 1, not 0
- Slot 0 conceptually represents parent
- Different hash ensures uniqueness
- No lock files - container names are locks

## File Organization
- One function per purpose
- Modular library structure in lib/
- Clear separation of concerns
- Templates use {{VARIABLE}} substitution

## Documentation
- Inline comments for complex logic
- Function headers for public APIs
- README for user documentation
- CLAUDE.md for AI assistant guidance

## Testing
- Test scripts in tests/ directory
- Bash 3.2 compatibility tests
- Security tests for sidecar mode
- Manual testing recommended before commits