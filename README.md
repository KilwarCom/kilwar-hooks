# Kilwar Hooks

Claude Code hook scripts for the Kilwar ecosystem.

## Installation

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

## Requirements

- `jq` - JSON processor
- `curl` - HTTP client
- `~/.forge/config.json` - Service URLs
- `~/.forge/credentials.json` - Access token

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
