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
# ── ⛔ WHY THIS NO LONGER USES `jq` ──────────────────────────────────────────
#
# v1.0.0 parsed the payload with `jq`, while `install.sh` only ever checked for
# `python3`. On a machine without `jq` the parse produced an empty body, the
# next line exited 0, and the guard detected NOTHING — while `--check` still
# printed "installed, wired". A security control that fails OPEN and reports
# GREEN is worse than no control, because it also removes the worry that would
# have made someone look.
#
# Found by Jitendrakumar Shakya on 2026-09-15, on his own machine, by reading
# the script before running it. Reproduced here: fed a GitHub token with `jq`
# unavailable, the guard exited 0, printed nothing, and wrote no marker, while
# `--check` reported "guard 1.0.0 installed, wired".
#
# ⭐ THE FIX IS TO REMOVE THE DEPENDENCY, NOT TO CHECK FOR IT. Adding `jq` to
# the installer's requirements would trade a silent failure for a noisy install
# and still leave every already-installed copy inert. `python3` is already
# required by `install.sh`, is present on macOS and every Linux dev image, and
# does the same job in one process instead of three.
#
# AND `--check` NOW PROVES DETECTION, not just presence. It runs a planted
# credential through the real extraction and the real patterns and fails if
# nothing fires. "The file exists and is mentioned in settings.json" was never
# the question worth answering.
#
# Input (stdin JSON): Claude Code PostToolUse payload.
# Exit codes: always 0 on the hook path. This guard must never break a
#             developer's session; its job is to be impossible to ignore, not
#             to block. `--check` exits non-zero when the guard is not working.
# =============================================================================

set -uo pipefail

GUARD_VERSION="1.1.0"
MARKER_DIR="$HOME/.kilwar/credential-incidents"

# ── PARSING, WITHOUT jq ──────────────────────────────────────────────────────
# One python3 process returns every field this hook needs, unit-separated.
# `install.sh` already requires python3, so this cannot be the thing that is
# missing — which was the entire v1.0.0 defect.
#
# Exit 3 = stdin was not a JSON object. That is reported LOUDLY rather than
# treated as "no credential found": if the payload format ever changes, this
# guard must complain instead of quietly becoming decoration.
US=$'\x1f'
extract_fields() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if not isinstance(d, dict):
    sys.exit(3)
def flat(v):
    if v is None:
        return ""
    if isinstance(v, str):
        return v
    # A tool_response is often an object or a list. `jq -r` stringifies those
    # too, and a credential inside a structured response is still a credential.
    return json.dumps(v)
body = flat(d.get("tool_response")) or flat(d.get("tool_result"))
out = [body,
       flat(d.get("cwd")) or "unknown",
       flat(d.get("tool_name")) or "unknown",
       flat(d.get("session_id")) or "unknown",
       flat(d.get("transcript_path")) or "unknown"]
sys.stdout.write("\x1f".join(out))
' 2>/dev/null
}

# ── THE PATTERNS, IN ONE PLACE ───────────────────────────────────────────────
# HIGH PRECISION ONLY. Every pattern here is a shape that is almost never
# anything but a real credential. Deliberately absent: a bare `password=`, and
# `eyJ` for JWTs. Both match documentation, examples and test fixtures
# constantly, and a guard that fires on those gets switched off within a week,
# after which it protects nothing.
#
# ⛔ THIS IS A FUNCTION SO `--check` CAN RUN THE REAL THING. A self-test with
# its own copy of the patterns proves only that the copy works.
detect_shapes() {
  local body="$1" found="" 
  _add() { found="${found}${found:+, }$1"; }

  printf '%s' "$body" | grep -qE '(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp)://[^:/@[:space:]]+:[^@[:space:]]{6,}@' \
    && _add "a database connection string with an inline password"
  printf '%s' "$body" | grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    && _add "a private key block"
  # ⛔ AWS'S OWN DOCUMENTATION PLACEHOLDERS ARE NOT CREDENTIALS.
  # `AKIAIOSFODNN7EXAMPLE` is the example key in AWS's own docs and it is
  # copied into READMEs, terraform samples and test fixtures everywhere. AWS
  # reserves the convention that example keys END IN `EXAMPLE`, so this fires
  # only on a match that does not.
  #
  # This is not hypothetical tidiness: on 2026-09-15 this machine carried two
  # markers reading "an AWS access key id" that nobody could trace to any file
  # or command, and a doc placeholder in passing tool output is the likeliest
  # explanation. Two false incidents is exactly how a guard's output starts
  # being ignored.
  printf '%s' "$body" | grep -oE 'AKIA[0-9A-Z]{16}' | grep -qv 'EXAMPLE$' \
    && _add "an AWS access key id"
  printf '%s' "$body" | grep -qE '(ghp|gho|ghs|ghu)_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}' \
    && _add "a GitHub token"
  printf '%s' "$body" | grep -qE 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    && _add "a Slack token"
  printf '%s' "$body" | grep -qE 'sk_live_[A-Za-z0-9]{16,}' \
    && _add "a live Stripe secret key"

  printf '%s' "$found"
}

# `--check`: prove the guard is installed and wired, in one line a developer can
# paste into Slack. This is how "confirm it exists" works on day one, before the
# EKKA attestation plan runs it for us.
if [ "${1:-}" = "--check" ]; then
  SELF="$HOME/.claude/hooks/credential-exposure.sh"
  SETTINGS="$HOME/.claude/settings.json"
  ok=1
  [ -x "$SELF" ] || { echo "MISSING: $SELF not present or not executable"; ok=0; }
  grep -q "credential-exposure.sh" "$SETTINGS" 2>/dev/null || { echo "NOT WIRED: no hook entry in $SETTINGS"; ok=0; }

  # ⛔ AND THE PART v1.0.0 DID NOT DO: PROVE IT DETECTS.
  #
  # "installed, wired" was true on a machine where the guard found nothing,
  # because the parse silently produced an empty body. Presence was never the
  # question. So run a planted credential through the REAL extractor and the
  # REAL patterns, and refuse to print a green line if nothing fires.
  #
  # The fake token is ASSEMBLED AT RUNTIME on purpose: a literal `ghp_AAAA...`
  # in this file would make the guard flag its own source the first time
  # anybody reads it, which is the kind of false positive that gets a detector
  # switched off.
  command -v python3 >/dev/null 2>&1 || { echo "BROKEN: python3 not found — the guard cannot parse any payload and detects NOTHING"; ok=0; }
  if [ "$ok" = 1 ]; then
    _fake="ghp_$(printf 'A%.0s' $(seq 1 36))"
    _probe="$(printf '{"tool_name":"SelfTest","cwd":"/nonexistent","tool_response":"%s"}' "$_fake")"
    _fields="$(printf '%s' "$_probe" | extract_fields)"; _prc=$?
    if [ "$_prc" -ne 0 ] || [ -z "$_fields" ]; then
      echo "BROKEN: cannot parse a payload (python3 extraction failed) — the guard detects NOTHING"; ok=0
    else
      _body="${_fields%%${US}*}"
      _hit="$(detect_shapes "$_body")"
      if [ "$_hit" != "a GitHub token" ]; then
        echo "BROKEN: self-test credential was NOT detected (got '${_hit:-nothing}') — the guard detects NOTHING"; ok=0
      fi
    fi
  fi

  OPEN="$(ls -1 "$MARKER_DIR" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$ok" = 1 ] && echo "guard $GUARD_VERSION installed, wired, DETECTION SELF-TESTED, open incidents: $OPEN, host: $(hostname -s 2>/dev/null)"
  exit $(( ok ? 0 : 1 ))
fi

PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

# ⛔ A PARSER THAT IS NOT THERE IS AN INERT GUARD, AND IT SAYS SO.
# v1.0.0 swallowed this and exited 0. Noise on every tool call is the correct
# cost here: silence is the bug this replaces.
if ! command -v python3 >/dev/null 2>&1; then
  echo "credential-exposure guard $GUARD_VERSION IS INERT: python3 not found, no payload can be parsed, nothing is being scanned. Install python3 or remove the hook." >&2
  exit 0
fi

# Scan the tool RESULT only. Scanning the assistant's own text would fire on
# discussion of credentials, which is how a guard starts crying wolf.
FIELDS="$(printf '%s' "$PAYLOAD" | extract_fields)"; PRC=$?
if [ "$PRC" -eq 3 ]; then
  # Non-empty stdin that is not a JSON object. Either the payload format moved
  # or something else is calling this. Either way it must not look like "clean".
  echo "credential-exposure guard $GUARD_VERSION: stdin was not a JSON object, so NOTHING WAS SCANNED. If Claude Code's payload shape changed, this guard is inert until it is updated." >&2
  exit 0
fi
[ -n "$FIELDS" ] || exit 0

BODY="${FIELDS%%${US}*}"
_rest="${FIELDS#*${US}}"
CWD="${_rest%%${US}*}"; _rest="${_rest#*${US}}"
TOOL="${_rest%%${US}*}"; _rest="${_rest#*${US}}"
SESSION="${_rest%%${US}*}"; TRANSCRIPT="${_rest#*${US}}"
[ -n "$BODY" ] || exit 0

# ⛔ ONE COPY OF THE PATTERNS. They live in `detect_shapes` above so that
# `--check` exercises the same code a real payload hits. This used to be an
# inline block, which meant a self-test could only ever have tested a copy.
FOUND="$(detect_shapes "$BODY")"

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

# ⛔ SHAPE AND LOCATION ONLY. The value is never written here. This file is not
# a copy of the secret; it is a record that one was exposed.
# ⭐ THE SESSION AND TRANSCRIPT ARE RECORDED, AND THAT IS A DELIBERATE
# ADDITION, NOT AN EXPANSION OF WHAT IS STORED. On 2026-09-15 this machine held
# two markers reading "an AWS access key id ... tool: Bash" and it was
# IMPOSSIBLE to work out which command produced them: no file on disk matched
# the shape, and tool output is not retained. A marker nobody can act on is a
# worry, not a record.
#
# The transcript path adds NO new exposure: that file is local and already
# contains whatever was printed. It is a pointer to evidence that exists, which
# is the opposite of copying the secret somewhere new.
{
  echo "when:       $TS"
  echo "what:       $FOUND"
  echo "tool:       $TOOL"
  echo "directory:  $CWD"
  echo "session:    $SESSION"
  echo "transcript: $TRANSCRIPT   <- the command that did it is in here"
  echo "guard:      $GUARD_VERSION"
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
