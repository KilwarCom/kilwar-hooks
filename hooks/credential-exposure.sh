#!/bin/bash
# =============================================================================
# CREDENTIAL EXPOSURE GUARD — a Kilwar standing rule, set by MANISH PARANJAPE.
#
# If a real credential value ever reaches an AI assistant's context, that is an
# incident, and it is handled on a PRIORITY basis. Not at the end of the task.
# Not "I'll mention it later". Now.
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
#
# A production database credential was printed to a terminal because a command's
# only safety mechanism was a redacting filter at the END of a pipe. The filter
# broke; the raw line printed. Nobody was careless. The secret was simply
# READABLE, and a file that can be printed will eventually be printed.
#
# The same night, on the same machine, a different key could NOT be leaked under
# a direct instruction to produce it, because it lived in a write-only store and
# no copy existed to find.
#
# One variable separated those outcomes, and it was STORAGE, not judgment.
#
#   ⭐ Put secrets where they cannot be read back.
#      Do not rely on anyone being careful.
#
# ── WHAT THIS HOOK DOES, AND DELIBERATELY DOES NOT DO ────────────────────────
#
# DOES:  detects high-confidence credential shapes in tool output, tells the
#        assistant to stop and disclose immediately, and writes a durable local
#        marker so the incident cannot quietly evaporate at session end.
#
# DOES NOT ECHO WHAT IT FOUND. A leak detector that prints the leak is a second
# leak. It reports the SHAPE and the location, never the value.
#
# DOES NOT FILE A TICKET AUTOMATICALLY, on purpose. Three reasons: it would need
# a write-scoped token on every laptop; a false positive would create noise that
# teaches people to ignore real ones; and an automated process that just handled
# a secret is the last thing that should be composing text about it.
#
# ── THE ORDER MATTERS, AND IT IS NOT THE OBVIOUS ONE ─────────────────────────
#
#   1. SAY IT, in the same message. Before finishing whatever you were doing.
#   2. ROTATE. Mint the new value FIRST, so whatever escaped is already dead.
#   3. THEN the ticket, recording that rotation happened.
#   4. THEN remove the plain-text source.
#
# Rotating AFTER the paperwork leaves the window open for exactly as long as the
# tidy-up takes, and the tidy-up is the part that always slips.
#
# Input (stdin JSON): Claude Code PostToolUse payload.
# Exit codes: always 0. This guard must never break a developer's session; its
#             job is to be impossible to ignore, not to block.
# =============================================================================

set -uo pipefail

GUARD_VERSION="1.0.0"
MARKER_DIR="$HOME/.kilwar/credential-incidents"

# `--check`: prove the guard is installed and wired, in one line a developer can
# paste into Slack. This is how "confirm it exists" works on day one, before the
# EKKA attestation plan runs it for us.
if [ "${1:-}" = "--check" ]; then
  SELF="$HOME/.claude/hooks/credential-exposure.sh"
  SETTINGS="$HOME/.claude/settings.json"
  ok=1
  [ -x "$SELF" ] || { echo "MISSING: $SELF not present or not executable"; ok=0; }
  grep -q "credential-exposure.sh" "$SETTINGS" 2>/dev/null || { echo "NOT WIRED: no hook entry in $SETTINGS"; ok=0; }
  OPEN="$(ls -1 "$MARKER_DIR" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$ok" = 1 ] && echo "guard $GUARD_VERSION installed, wired, open incidents: $OPEN, host: $(hostname -s 2>/dev/null)"
  exit $(( ok ? 0 : 1 ))
fi

PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

# Scan the tool RESULT only. Scanning the assistant's own text would fire on
# discussion of credentials, which is how a guard starts crying wolf.
BODY="$(printf '%s' "$PAYLOAD" | (jq -r '.tool_response // .tool_result // empty' 2>/dev/null || true))"
[ -n "$BODY" ] || exit 0

# ── THE PATTERNS ─────────────────────────────────────────────────────────────
# HIGH PRECISION ONLY. Every pattern here is a shape that is almost never
# anything but a real credential. Deliberately absent: a bare `password=`, and
# `eyJ` for JWTs. Both match documentation, examples and test fixtures
# constantly, and a guard that fires on those gets switched off within a week,
# after which it protects nothing.
FOUND=""
add() { FOUND="${FOUND}${FOUND:+, }$1"; }

# Connection strings carrying an inline password: scheme://user:secret@host
printf '%s' "$BODY" | grep -qE '(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp)://[^:/@[:space:]]+:[^@[:space:]]{6,}@' \
  && add "a database connection string with an inline password"

printf '%s' "$BODY" | grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
  && add "a private key block"

printf '%s' "$BODY" | grep -qE 'AKIA[0-9A-Z]{16}' \
  && add "an AWS access key id"

printf '%s' "$BODY" | grep -qE '(ghp|gho|ghs|ghu)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}' \
  && add "a GitHub token"

printf '%s' "$BODY" | grep -qE 'xox[baprs]-[A-Za-z0-9-]{10,}' \
  && add "a Slack token"

printf '%s' "$BODY" | grep -qE 'sk_live_[A-Za-z0-9]{16,}' \
  && add "a live Stripe secret key"

[ -n "$FOUND" ] || exit 0

# ── RECORD IT SOMEWHERE THAT OUTLIVES THE SESSION ────────────────────────────
# This is what "it will be flagged" actually means. Not a threat: a file. An
# unresolved marker is a real, checkable artifact, which a promise in a chat
# window is not.
mkdir -p "$MARKER_DIR" 2>/dev/null
# ⛔ THE SUFFIX IS NOT DECORATION. The filename was once the timestamp alone, and
# two incidents in the same second overwrote each other: five planted exposures
# produced two files. A guard whose entire purpose is "this cannot quietly
# evaporate" must not silently drop records. $$ plus RANDOM makes a collision
# require two hooks in the same second in the same process, which cannot happen.
TS="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
CWD="$(printf '%s' "$PAYLOAD" | (jq -r '.cwd // "unknown"' 2>/dev/null || echo unknown))"
TOOL="$(printf '%s' "$PAYLOAD" | (jq -r '.tool_name // "unknown"' 2>/dev/null || echo unknown))"

# ⛔ SHAPE AND LOCATION ONLY. The value is never written here. This file is not
# a copy of the secret; it is a record that one was exposed.
{
  echo "when:       $TS"
  echo "what:       $FOUND"
  echo "tool:       $TOOL"
  echo "directory:  $CWD"
  echo "rotated:    NO      <- change to the date once the credential is rotated"
  echo "ticket:     NONE    <- put the ticket reference here"
} > "$MARKER_DIR/$TS.txt" 2>/dev/null

OPEN="$(ls -1 "$MARKER_DIR" 2>/dev/null | wc -l | tr -d ' ')"

cat >&2 <<BANNER

================================================================================
  CREDENTIAL EXPOSED IN THIS SESSION  —  HANDLE IT NOW, NOT AT THE END
================================================================================

  Detected: $FOUND
  Via:      $TOOL
  Logged:   $MARKER_DIR/$TS.txt
  Open credential incidents on this machine: $OPEN

  MANISH PARANJAPE set this rule, and asked that it be fixed on a PRIORITY
  basis. A credential reaching an assistant's context is an incident whoever
  caused it and whether or not anyone was authorised to run the command.

  DO THIS, IN THIS ORDER:

    1. SAY IT NOW, in your very next message, before finishing the task.
       Do not paste the value again. Name the shape and where it came from.

    2. ROTATE IT FIRST. Mint the new value before any paperwork, so whatever
       escaped is already dead. Rotating afterwards leaves the window open for
       as long as the cleanup takes, and the cleanup always slips.

    3. THEN raise a HIGHEST PRIORITY ticket. Never put the value in it, and do
       not name the exact key until after rotation: an open ticket saying
       "this specific credential leaked and is unrotated" is a map.

    4. THEN remove the plain-text source, and fix the real cause: move it to a
       store that cannot be read back. Blocking one assistant from reading it
       leaves every developer, CI job and role still able to.

  Then edit the file above: set 'rotated:' and 'ticket:'.
  An unresolved marker is flagged at every session start until it is closed.

================================================================================

BANNER

exit 0
