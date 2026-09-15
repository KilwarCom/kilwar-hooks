# Kilwar Hooks

Claude Code hook scripts for the Kilwar ecosystem.

## Installation

### The credential-exposure guard (required on every developer machine)

One command, safe to run twice:

```bash
curl -fsSL https://raw.githubusercontent.com/KilwarCom/kilwar-hooks/main/install.sh | bash
```

Then restart Claude Code. It copies `hooks/credential-exposure.sh` into `~/.claude/hooks/`
and wires it as a `PostToolUse` hook in `~/.claude/settings.json`, keeping every existing
setting. It never reads, prints or sends anything from your machine.

Admins: `managed-settings.json` in this repo is the same hook as a **managed setting**,
for the claude.ai admin console or MDM. Managed settings are precedence level 1, so a
developer cannot remove the hook. The script still has to be on disk; `install.sh` does that.

### session-sync (Desktop App)

The Desktop App automatically syncs these hooks to `~/.claude/hooks/`.

For manual installation:

```bash
# Download hook
curl -o ~/.claude/hooks/session-sync.sh \
  https://raw.githubusercontent.com/KilwarCom/kilwar-hooks/main/hooks/session-sync.sh

# Make executable
chmod +x ~/.claude/hooks/session-sync.sh
```

## Configuration

Hooks read configuration from `~/.forge/config.json`:

```json
{
  "services": {
    "sessions": "https://sessions.kilwar.com",
    "forge": "https://forge.kilwar.com",
    "tickets": "https://tickets-api.kilwar.com"
  }
}
```

Credentials are read from `~/.forge/credentials.json`.

## Available Hooks

| Hook | Type | Description |
|------|------|-------------|
| session-sync | pre_compact | Saves session data before Claude Code compacts context |
| credential-exposure | post_tool_use | Detects a real credential reaching the assistant's context, tells it to disclose and rotate immediately, and records the incident locally. Never echoes what it found. |

## Requirements

**They differ per hook, and that mattered.**

`credential-exposure` needs only:
- `bash`, `curl` (install) and **`python3`** — nothing else

⛔ **It deliberately does NOT need `jq`.** v1.0.0 parsed the payload with `jq`
while `install.sh` only ever checked for `python3`. On a machine without `jq`
the parse produced an empty body, the hook exited 0, and the guard detected
**nothing** — while `--check` still printed "installed, wired". A security
control that fails open and reports green is worse than none, because it also
removes the worry that would have made someone look. Found by Jitendrakumar
Shakya on 2026-09-15 by reading the script before running it.

`session-sync` needs:
- `jq` - JSON processor
- `curl` - HTTP client
- `~/.forge/config.json` - Service URLs
- `~/.forge/credentials.json` - Access token

## Proving the guard actually works

```sh
~/.claude/hooks/credential-exposure.sh --check
```

```
guard 1.1.0 installed, wired, DETECTION SELF-TESTED, open incidents: 0, host: your-machine
```

`DETECTION SELF-TESTED` is the word that carries the weight. `--check` runs a
planted credential through the **real** extractor and the **real** patterns and
exits non-zero if nothing fires, so a green line means the guard detects rather
than merely exists. `install.sh` runs it too and fails the install if it does
not pass.

Open incidents live in `~/.kilwar/credential-incidents/`. Each file records the
**shape**, the tool, the directory and the session — never the value. The
session and transcript are there so an incident can be traced back to the
command that caused it; a marker nobody can act on is a worry, not a record.

## Hook Types

| Type | When it runs |
|------|--------------|
| pre_compact | Before Claude Code compacts conversation context |

## Development

### Testing a hook locally

```bash
# Create test config
mkdir -p ~/.forge
echo '{"services":{"sessions":"https://sessions.kilwar.com"}}' > ~/.forge/config.json

# Run hook with test input
echo '{"session_id":"test-123","cwd":"/tmp","trigger":"manual"}' | ./hooks/session-sync.sh
```

### Adding a new hook

1. Create script in `hooks/` directory
2. Add entry to `manifest.json`
3. Update this README

## License

MIT
