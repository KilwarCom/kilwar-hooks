#!/bin/bash
# Session Sync Hook - Captures Claude Code session data for Desktop App processing
# Triggered on /compact (manual) - writes job file to outbox for JobWorker
#
# Extracts git metadata (commits, files changed, stats) for server-side processing

set -e

OUTBOX_DIR="$HOME/.forge/outbox/sessions"
mkdir -p "$OUTBOX_DIR"

# Read hook input from stdin
INPUT=$(cat)

# Parse input JSON
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "manual"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then
    CWD=$(pwd)
fi
CAPTURED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# =============================================================================
# Git Metadata Extraction
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
GIT_STATS='{"files":0,"additions":0,"deletions":0}'
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
    STAT_LINE=$(git -C "$CWD" diff --stat HEAD~10 2>/dev/null | tail -1 || echo "")
    if [ -n "$STAT_LINE" ]; then
        FILES=$(echo "$STAT_LINE" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
        ADDITIONS=$(echo "$STAT_LINE" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo "0")
        DELETIONS=$(echo "$STAT_LINE" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo "0")
        GIT_STATS=$(jq -n --argjson f "${FILES:-0}" --argjson a "${ADDITIONS:-0}" --argjson d "${DELETIONS:-0}" '{files:$f,additions:$a,deletions:$d}')
    fi
fi

# =============================================================================
# Transcript Processing
# =============================================================================

TRANSCRIPT_B64=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Read and base64 encode transcript (limit to 500KB)
    TRANSCRIPT_B64=$(head -c 512000 "$TRANSCRIPT_PATH" | base64 | tr -d '\n')
fi

# =============================================================================
# Plans Extraction
# =============================================================================

PLANS_JSON="[]"
PLANS_DIR="$HOME/.claude/plans"
if [ -d "$PLANS_DIR" ]; then
    PLANS_JSON=$(find "$PLANS_DIR" -name "*.md" -mmin -60 -type f 2>/dev/null | head -5 | while read -r plan_file; do
        plan_name=$(basename "$plan_file" .md)
        plan_content=$(head -c 102400 "$plan_file" | base64 | tr -d '\n')
        echo "{\"name\":\"$plan_name\",\"content\":\"$plan_content\"}"
    done | jq -s '.' 2>/dev/null || echo "[]")
fi

# =============================================================================
# Project Name Detection
# =============================================================================

PROJECT_NAME=$(basename "$CWD")
if [ -n "$GIT_REMOTE_NORMALIZED" ]; then
    PROJECT_NAME=$(basename "$GIT_REMOTE_NORMALIZED")
fi

# =============================================================================
# Write Job File for Desktop App JobWorker
# =============================================================================

JOB_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(date +%s)-$$")
JOB_FILE="$OUTBOX_DIR/session-$JOB_ID.json"

cat > "$JOB_FILE" << EOF
{
  "job_type": "session_sync",
  "project_name": "$PROJECT_NAME",
  "data": {
    "session_id": "$SESSION_ID",
    "cwd": "$CWD",
    "trigger": "$TRIGGER",
    "captured_at": "$CAPTURED_AT",
    "git": {
      "remote": "$GIT_REMOTE_NORMALIZED",
      "branch": "$GIT_BRANCH",
      "commits": $GIT_COMMITS,
      "files_changed": $GIT_FILES_CHANGED,
      "stats": $GIT_STATS
    },
    "transcript_base64": "$TRANSCRIPT_B64",
    "plans": $PLANS_JSON
  }
}
EOF

echo "[SessionSync] Job created: $JOB_FILE (branch: $GIT_BRANCH, commits: $(echo "$GIT_COMMITS" | jq 'length'), files: $(echo "$GIT_FILES_CHANGED" | jq 'length'))" >&2

# Return success to Claude Code
echo '{"continue": true}'
exit 0
