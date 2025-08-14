#!/usr/bin/env bash
# Docker Sidecar Audit Logger
# Logs all Docker operations for security auditing

set -Eeuo pipefail
IFS=$'\n\t'

# Logging configuration
LOG_DIR="${SIDECAR_LOG_DIR:-$HOME/.claudebox}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/docker-audit.log}"
LOG_MAX_SIZE="${SIDECAR_LOG_MAX_SIZE:-10485760}"  # 10MB default
LOG_RETENTION_DAYS="${SIDECAR_LOG_RETENTION_DAYS:-30}"

# Initialize logging system
init_logging() {
    # Ensure log directory exists
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" || {
            printf "ERROR: Cannot create log directory: %s\n" "$LOG_DIR" >&2
            return 1
        }
    fi
    
    # Ensure log file exists
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE" || {
            printf "ERROR: Cannot create log file: %s\n" "$LOG_FILE" >&2
            return 1
        }
    fi
    
    # Rotate logs if needed
    rotate_logs_if_needed
    
    # Clean up old logs
    cleanup_old_logs
    
    # Log initialization
    log_audit_event "SYSTEM" "INIT" "Docker Sidecar logging initialized" "{\"log_file\":\"$LOG_FILE\",\"retention_days\":$LOG_RETENTION_DAYS}"
}

# Get current timestamp in ISO format
get_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

# Get current user information
get_user_info() {
    local user_id="${USER:-unknown}"
    local process_id="$$"
    local parent_pid="$PPID"
    
    printf '{"user":"%s","pid":%d,"ppid":%d}' "$user_id" "$process_id" "$parent_pid"
}

# Generate request ID for correlation
generate_request_id() {
    # Simple request ID based on timestamp and random number
    local timestamp
    timestamp=$(date +%s)
    local random_suffix
    random_suffix=$(awk 'BEGIN { srand(); printf "%04d", rand() * 10000 }')
    
    printf "%s-%s" "$timestamp" "$random_suffix"
}

# Core audit logging function
log_audit_event() {
    local event_type="$1"
    local operation="$2" 
    local message="$3"
    local data="${4:-{}}"
    local exit_code="${5:-0}"
    
    local timestamp
    timestamp=$(get_timestamp)
    
    local user_info
    user_info=$(get_user_info)
    
    local log_entry
    # Validate JSON data parameter
    if ! printf '%s' "$data" | jq . >/dev/null 2>&1; then
        data='{"error": "Invalid JSON data provided"}'
    fi
    
    # Validate JSON user_info parameter
    if ! printf '%s' "$user_info" | jq . >/dev/null 2>&1; then
        user_info='{"user": "unknown", "pid": 0, "ppid": 0}'
    fi
    
    log_entry=$(jq -n \
        --arg timestamp "$timestamp" \
        --arg event_type "$event_type" \
        --arg operation "$operation" \
        --arg message "$message" \
        --argjson data "$data" \
        --argjson user_info "$user_info" \
        --arg exit_code "$exit_code" \
        '{
            timestamp: $timestamp,
            event_type: $event_type,
            operation: $operation,
            message: $message,
            exit_code: ($exit_code | tonumber),
            user: $user_info,
            data: $data
        }' 2>/dev/null
    ) || {
        # Fallback to simple logging if jq fails
        log_entry=$(printf '{"timestamp":"%s","event_type":"%s","operation":"%s","message":"%s","exit_code":%s}' \
            "$timestamp" "$event_type" "$operation" "$message" "$exit_code")
    }
    
    # Write to log file with file locking
    {
        flock -x 200
        printf '%s\n' "$log_entry" >> "$LOG_FILE"
    } 200>>"$LOG_FILE.lock"
}

# Log incoming requests
log_request() {
    local operation="$1"
    local request_data="$2"
    local request_id="${REQUEST_ID:-$(generate_request_id)}"
    
    # Extract key information from request
    local sanitized_data
    sanitized_data=$(printf '%s\n' "$request_data" | jq 'del(.auth_token?) | del(.secrets?)' 2>/dev/null || printf '{}')
    
    local audit_data
    audit_data=$(jq -n \
        --arg request_id "$request_id" \
        --argjson request "$sanitized_data" \
        '{
            request_id: $request_id,
            direction: "incoming",
            request: $request
        }'
    )
    
    log_audit_event "REQUEST" "$operation" "Docker operation requested" "$audit_data"
    
    # Set REQUEST_ID for correlation with response
    export REQUEST_ID="$request_id"
}

# Log outgoing responses
log_response() {
    local operation="$1"
    local exit_code="$2"
    local output="$3"
    local request_id="${REQUEST_ID:-unknown}"
    
    # Limit output size in logs to prevent excessive log growth
    local truncated_output
    if [[ ${#output} -gt 1000 ]]; then
        truncated_output="${output:0:1000}... [truncated]"
    else
        truncated_output="$output"
    fi
    
    local audit_data
    audit_data=$(jq -n \
        --arg request_id "$request_id" \
        --arg output "$truncated_output" \
        --arg exit_code "$exit_code" \
        '{
            request_id: $request_id,
            direction: "outgoing", 
            exit_code: ($exit_code | tonumber),
            output: $output
        }'
    )
    
    local message
    if [[ $exit_code -eq 0 ]]; then
        message="Docker operation completed successfully"
    else
        message="Docker operation failed"
    fi
    
    log_audit_event "RESPONSE" "$operation" "$message" "$audit_data" "$exit_code"
}

# Log security events
log_security_event() {
    local event_type="$1"  # BLOCKED, FILTERED, RATE_LIMITED, etc.
    local operation="$2"
    local reason="$3"
    local request_data="${4:-{}}"
    
    local audit_data
    audit_data=$(jq -n \
        --arg reason "$reason" \
        --argjson request "$request_data" \
        '{
            reason: $reason,
            request: $request
        }'
    )
    
    log_audit_event "SECURITY" "$operation" "$event_type: $reason" "$audit_data" "1"
}

# Log system events
log_system_event() {
    local event_type="$1"  # START, STOP, CONFIG_CHANGE, etc.
    local message="$2"
    local data="${3:-{}}"
    
    log_audit_event "SYSTEM" "$event_type" "$message" "$data"
}

# Rotate logs if they exceed maximum size
rotate_logs_if_needed() {
    if [[ -f "$LOG_FILE" ]]; then
        local file_size
        file_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo "0")
        
        if [[ $file_size -gt $LOG_MAX_SIZE ]]; then
            local backup_file="${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
            
            # Move current log to backup
            mv "$LOG_FILE" "$backup_file" || {
                printf "WARNING: Could not rotate log file\n" >&2
                return 1
            }
            
            # Create new empty log file
            touch "$LOG_FILE"
            
            printf "Log rotated: %s -> %s\n" "$LOG_FILE" "$backup_file" >&2
        fi
    fi
}

# Clean up old log files
cleanup_old_logs() {
    if [[ $LOG_RETENTION_DAYS -gt 0 ]]; then
        # Find and remove log files older than retention period
        find "$LOG_DIR" -name "docker-audit.log.*" -type f -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null || true
    fi
}

# Generate audit report
generate_audit_report() {
    local start_date="${1:-$(date -d '1 day ago' '+%Y-%m-%d')}"
    local end_date="${2:-$(date '+%Y-%m-%d')}"
    
    if [[ ! -f "$LOG_FILE" ]]; then
        printf "No audit log found at: %s\n" "$LOG_FILE" >&2
        return 1
    fi
    
    printf "=== Docker Sidecar Audit Report ===\n"
    printf "Period: %s to %s\n" "$start_date" "$end_date"
    printf "Generated: %s\n\n" "$(get_timestamp)"
    
    # Count events by type
    printf "Event Summary:\n"
    jq -r --arg start "$start_date" --arg end "$end_date" '
        select(.timestamp >= $start and .timestamp <= $end) |
        .event_type' < "$LOG_FILE" | sort | uniq -c | awk '{printf "  %-15s: %s\n", $2, $1}'
    
    printf "\nOperation Summary:\n"
    jq -r --arg start "$start_date" --arg end "$end_date" '
        select(.timestamp >= $start and .timestamp <= $end) |
        .operation' < "$LOG_FILE" | sort | uniq -c | awk '{printf "  %-20s: %s\n", $2, $1}'
    
    # Security events
    printf "\nSecurity Events:\n"
    local security_count
    security_count=$(jq -r --arg start "$start_date" --arg end "$end_date" '
        select(.timestamp >= $start and .timestamp <= $end and .event_type == "SECURITY")' < "$LOG_FILE" | wc -l)
    
    if [[ $security_count -gt 0 ]]; then
        jq -r --arg start "$start_date" --arg end "$end_date" '
            select(.timestamp >= $start and .timestamp <= $end and .event_type == "SECURITY") |
            "  \(.timestamp) - \(.operation): \(.message)"' < "$LOG_FILE"
    else
        printf "  No security events in this period\n"
    fi
    
    # Failed operations
    printf "\nFailed Operations:\n"
    local failed_count
    failed_count=$(jq -r --arg start "$start_date" --arg end "$end_date" '
        select(.timestamp >= $start and .timestamp <= $end and .exit_code != 0)' < "$LOG_FILE" | wc -l)
    
    if [[ $failed_count -gt 0 ]]; then
        jq -r --arg start "$start_date" --arg end "$end_date" '
            select(.timestamp >= $start and .timestamp <= $end and .exit_code != 0) |
            "  \(.timestamp) - \(.operation): \(.message) (exit code: \(.exit_code))"' < "$LOG_FILE" | head -10
        
        if [[ $failed_count -gt 10 ]]; then
            printf "  ... and %d more failed operations\n" $((failed_count - 10))
        fi
    else
        printf "  No failed operations in this period\n"
    fi
    
    printf "\n=== End of Report ===\n"
}

# Export functions for use by API server and other components
export -f init_logging get_timestamp get_user_info generate_request_id
export -f log_audit_event log_request log_response log_security_event log_system_event
export -f rotate_logs_if_needed cleanup_old_logs generate_audit_report