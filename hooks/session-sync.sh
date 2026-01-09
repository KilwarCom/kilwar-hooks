#!/bin/bash
# =============================================================================
# Session Sync Hook for Claude Code
#
# This script is executed by Claude Code's pre_compact hook to save session
# data to the Work Session Service before context is compacted.
#
# Input (stdin JSON):
#   - session_id: Unique session identifier
#   - transcript_path: Path to conversation transcript (.jsonl)
#   - cwd: Current working directory
#   - trigger: "manual" or "auto"
#
# Requirements:
#   - jq: JSON processor
#   - curl: HTTP client
#   - ~/.forge/config.json with services.sessions URL
#   - ~/.forge/credentials.json with access_token
#
# Exit codes:
#   0 - Success (or graceful failure - don't block compact)
#   2 - Blocking error (prevents compact)
# =============================================================================

set -euo pipefail

# Configuration
CONFIG_FILE="$HOME/.forge/config.json"
CREDENTIALS_FILE="$HOME/.forge/credentials.json"
LOG_FILE="$HOME/.claude/session-sync.log"

# Logging helper
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Read JSON input from stdin
INPUT=$(cat)
log "Hook triggered with input: $INPUT"

# Parse input fields
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"')

if [ -z "$SESSION_ID" ]; then
    log "ERROR: No session_id provided"
    exit 0  # Don't block compact
fi

# Check for config file
if [ ! -f "$CONFIG_FILE" ]; then
    log "No config found at $CONFIG_FILE - skipping sync"
    exit 0
fi

# Get sessions API URL from config
SESSIONS_API_URL=$(jq -r '.services.sessions // empty' "$CONFIG_FILE")
if [ -z "$SESSIONS_API_URL" ]; then
    log "No sessions URL in config - skipping sync"
    exit 0
fi

# Check for credentials
if [ ! -f "$CREDENTIALS_FILE" ]; then
    log "No credentials found at $CREDENTIALS_FILE - skipping sync"
    exit 0
fi

# Extract access token
ACCESS_TOKEN=$(jq -r '.access_token // empty' "$CREDENTIALS_FILE")
if [ -z "$ACCESS_TOKEN" ]; then
    log "No access_token in credentials - skipping sync"
    exit 0
fi

# Extract project ID from cwd (derive from path or use default)
# Format: last component of path as project identifier
PROJECT_ID=$(basename "$CWD" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID="default"
fi

log "Syncing session $SESSION_ID for project $PROJECT_ID (trigger: $TRIGGER)"

# Generate summary from transcript if available
SUMMARY=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Extract last few user/assistant exchanges for summary
    SUMMARY=$(tail -20 "$TRANSCRIPT_PATH" 2>/dev/null | head -c 5000 || echo "")
fi

# Create or update session
RESPONSE=$(curl -sf -X POST "$SESSIONS_API_URL/v1/sessions" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Project-Id: $PROJECT_ID" \
    -d "{
        \"actorType\": \"agent\",
        \"source\": \"claude-code\",
        \"environment\": \"local\",
        \"clientContext\": {
            \"sessionId\": \"$SESSION_ID\",
            \"trigger\": \"$TRIGGER\",
            \"cwd\": \"$CWD\"
        }
    }" 2>&1) || {
    log "Failed to create session: $RESPONSE"
    exit 0  # Don't block compact on API failure
}

log "Session created/updated: $RESPONSE"

# Output success (optional JSON response)
echo '{"continue": true}'
exit 0
