#!/bin/bash
# =============================================================================
# kilwar-hooks installer. One command, safe to run twice.
#
#   curl -fsSL https://raw.githubusercontent.com/KilwarCom/kilwar-hooks/main/install.sh | bash
#
# What it does: copies hooks/credential-exposure.sh into ~/.claude/hooks/ and
# wires it into ~/.claude/settings.json as a PostToolUse hook. Existing settings
# and existing hooks are kept. Running it again changes nothing.
#
# What it never does: read, print or transmit anything from your machine. It
# writes two files under ~/.claude and stops.
#
# Requires: bash, curl, python3 (macOS and every Linux dev image have all three).
# ⛔ NOT jq. v1.0.0 of the guard PARSED WITH jq while this installer only ever
# checked for python3, so on a machine without jq the guard silently detected
# nothing and `--check` still printed "installed, wired". The guard now parses
# with python3, which is the thing this script actually requires.
# Override the source ref with KILWAR_HOOKS_REF=v1.1.0 (default: main).
# =============================================================================
set -euo pipefail

REF="${KILWAR_HOOKS_REF:-main}"
BASE="https://raw.githubusercontent.com/KilwarCom/kilwar-hooks/${REF}"
HOOK_DIR="$HOME/.claude/hooks"
HOOK="$HOOK_DIR/credential-exposure.sh"
SETTINGS="$HOME/.claude/settings.json"

command -v python3 >/dev/null || { echo "install: python3 is required" >&2; exit 1; }

mkdir -p "$HOOK_DIR"
TMP="$(mktemp)"
if [ -n "${KILWAR_HOOKS_LOCAL:-}" ]; then
  cp "$KILWAR_HOOKS_LOCAL/hooks/credential-exposure.sh" "$TMP"   # tests and offline installs
else
  curl -fsSL "$BASE/hooks/credential-exposure.sh" -o "$TMP"
fi
bash -n "$TMP" || { echo "install: downloaded hook does not parse, refusing to install" >&2; rm -f "$TMP"; exit 1; }
grep -q "CREDENTIAL EXPOSURE GUARD" "$TMP" || { echo "install: downloaded file is not the guard, refusing" >&2; rm -f "$TMP"; exit 1; }
mv "$TMP" "$HOOK" && chmod 0755 "$HOOK"

# Wire settings.json. Idempotent: adds the hook entry once, keeps everything else.
SETTINGS="$SETTINGS" HOOK="$HOOK" python3 - <<'PY'
import json, os
p = os.environ["SETTINGS"]; hook = os.environ["HOOK"]
try:
    s = json.load(open(p))
except FileNotFoundError:
    s = {}
except json.JSONDecodeError:
    raise SystemExit(f"install: {p} is not valid JSON; fix it by hand, nothing was changed")
hooks = s.setdefault("hooks", {})
post = hooks.setdefault("PostToolUse", [])
entry = {"matcher": "", "hooks": [{"type": "command", "command": hook}]}
already = any(h.get("command") == hook for grp in post for h in grp.get("hooks", []))
if not already:
    post.append(entry)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    json.dump(s, open(tmp, "w"), indent=2); open(tmp, "a").write("\n")
    os.replace(tmp, p)
    print("installed: credential-exposure guard wired into", p)
else:
    print("already installed: nothing changed")
PY
# ⭐ AND PROVE IT WORKS BEFORE SAYING IT IS INSTALLED.
#
# "installed" used to mean "the file was copied and settings.json mentions it".
# That is exactly what was true on the machine where the guard detected nothing
# for its whole life. `--check` now runs a planted credential through the real
# extractor and the real patterns, so this either proves detection or fails the
# install loudly. An installer that cannot demonstrate the thing it installed
# is the reason nobody noticed for a day.
if ! "$HOOK" --check; then
  echo "install: the guard was copied and wired, but its SELF-TEST FAILED — it is not detecting anything." >&2
  echo "install: fix the cause above; do not treat this as installed." >&2
  exit 1
fi
echo "restart Claude Code to activate."
