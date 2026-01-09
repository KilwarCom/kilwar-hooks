#!/bin/bash
# Session Sync Hook - Captures Claude Code session data for Desktop App processing
# Triggered on /compact (manual) - writes job file to outbox for JobWorker
#
# NEW: Extracts git metadata (commits, files changed, stats) for server-side processing

# Debug log
DEBUG_LOG="$HOME/.forge/hook-debug.log"
echo "$(date): Hook started" >> "$DEBUG_LOG"

set -e

OUTBOX_DIR="$HOME/.forge/outbox/sessions"
mkdir -p "$OUTBOX_DIR"

# Read hook input from stdin
INPUT=$(cat)
echo "$(date): Input received: $INPUT" >> "$DEBUG_LOG"

# Parse input JSON
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "manual"')
CWD=$(pwd)
CAPTURED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# =============================================================================
# Git Metadata Extraction (NEW)
# =============================================================================

# Get git remote URL for project lookup
GIT_REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null || echo "")
# Normalize: strip .git suffix and protocol
GIT_REMOTE_NORMALIZED=$(echo "$GIT_REMOTE" | sed 's/\.git$//' | sed 's|^https://||' | sed 's|^git@||' | sed 's|:|/|')

# Get current branch
GIT_BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Get recent commits (last 10) - format as JSON array
GIT_COMMITS="[]"
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
    COMMITS_RAW=$(git -C "$CWD" log --oneline -10 --format='{"hash":"%h","message":"%s","author":"%an","date":"%aI"}' 2>/dev/null || echo "")
    if [ -n "$COMMITS_RAW" ]; then
        GIT_COMMITS=$(echo "$COMMITS_RAW" | jq -s '.' 2>/dev/null || echo "[]")
    fi
fi

# Get files changed (in last 10 commits) - format as JSON array
GIT_FILES_CHANGED="[]"
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
    FILES_RAW=$(git -C "$CWD" diff --name-only HEAD~10 2>/dev/null || git -C "$CWD" diff --name-only HEAD 2>/dev/null || echo "")
    if [ -n "$FILES_RAW" ]; then
        GIT_FILES_CHANGED=$(echo "$FILES_RAW" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    fi
fi

# Get diff stats
GIT_STATS_FILES=0
GIT_STATS_ADDITIONS=0
GIT_STATS_DELETIONS=0
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
    STAT_LINE=$(git -C "$CWD" diff --stat HEAD~10 2>/dev/null | tail -1 || echo "")
    if [ -n "$STAT_LINE" ]; then
        # Parse: "X files changed, Y insertions(+), Z deletions(-)"
        GIT_STATS_FILES=$(echo "$STAT_LINE" | grep -oE '[0-9]+' | head -1 || echo "0")
        GIT_STATS_ADDITIONS=$(echo "$STAT_LINE" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        GIT_STATS_DELETIONS=$(echo "$STAT_LINE" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
    fi
fi

# Build git JSON object
GIT_JSON=$(cat << GITJSON
{
  "remote": "$GIT_REMOTE_NORMALIZED",
  "branch": "$GIT_BRANCH",
  "commits": $GIT_COMMITS,
  "files_changed": $GIT_FILES_CHANGED,
  "stats": {
    "files": ${GIT_STATS_FILES:-0},
    "additions": ${GIT_STATS_ADDITIONS:-0},
    "deletions": ${GIT_STATS_DELETIONS:-0}
  }
}
GITJSON
)

# =============================================================================
# Transcript Processing
# =============================================================================

# Expand ~ in transcript path
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# Read transcript if available
TRANSCRIPT_CONTENT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Get last 100KB of transcript to avoid huge files
    TRANSCRIPT_CONTENT=$(tail -c 100000 "$TRANSCRIPT_PATH" 2>/dev/null | base64)
fi

# =============================================================================
# Plan Files
# =============================================================================

# Find plan files in .claude/plans for this project
PLANS_JSON="[]"
PLANS_DIR="$HOME/.claude/plans"
if [ -d "$PLANS_DIR" ]; then
    PLAN_FILES=$(find "$PLANS_DIR" -name "*.md" -mmin -60 2>/dev/null | head -5)
    if [ -n "$PLAN_FILES" ]; then
        PLANS_ARRAY="["
        FIRST=true
        for plan in $PLAN_FILES; do
            if [ "$FIRST" = true ]; then
                FIRST=false
            else
                PLANS_ARRAY+=","
            fi
            PLAN_CONTENT=$(cat "$plan" 2>/dev/null | base64)
            PLAN_NAME=$(basename "$plan")
            PLANS_ARRAY+="{\"name\":\"$PLAN_NAME\",\"content\":\"$PLAN_CONTENT\"}"
        done
        PLANS_ARRAY+="]"
        PLANS_JSON="$PLANS_ARRAY"
    fi
fi

# =============================================================================
# Write Job File
# =============================================================================

# Generate unique job ID
JOB_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "job-$(date +%s)")

# Write job file for Desktop App JobWorker
JOB_FILE="$OUTBOX_DIR/session-$JOB_ID.json"

# Use jq to build proper JSON (avoids escaping issues)
jq -n \
  --arg id "$JOB_ID" \
  --arg type "session_sync" \
  --arg status "pending" \
  --arg created_at "$CAPTURED_AT" \
  --arg session_id "$SESSION_ID" \
  --arg cwd "$CWD" \
  --arg trigger "$TRIGGER" \
  --arg captured_at "$CAPTURED_AT" \
  --arg transcript_path "$TRANSCRIPT_PATH" \
  --arg transcript_base64 "$TRANSCRIPT_CONTENT" \
  --argjson git "$GIT_JSON" \
  --argjson plans "$PLANS_JSON" \
  '{
    id: $id,
    type: $type,
    status: $status,
    created_at: $created_at,
    session_id: $session_id,
    cwd: $cwd,
    git_remote: $git.remote,
    trigger: $trigger,
    captured_at: $captured_at,
    data: {
      session_id: $session_id,
      cwd: $cwd,
      trigger: $trigger,
      captured_at: $captured_at,
      transcript_path: $transcript_path,
      transcript_base64: $transcript_base64,
      git: $git,
      plans: $plans
    }
  }' > "$JOB_FILE"

echo "[SessionSync] Job created: $JOB_FILE (branch: $GIT_BRANCH, commits: $(echo "$GIT_COMMITS" | jq 'length'), files: $(echo "$GIT_FILES_CHANGED" | jq 'length'))" >&2

# Allow compact to continue
echo '{"continue": true}'
exit 0
