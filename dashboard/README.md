# dashboard

Claude Code plugin that forwards all hook events to a dashboard TUI via Unix socket.

## Architecture

```
Claude Code
    |
    v
hooks (17 events)
    |
    v
bridge.sh
    |-- stack-tracker.sh  (agent stack management)
    |-- enrichment.sh     (inject agent_context_type into tool events)
    |-- socket-relay.sh   (socat/nc transport)
    |
    v
Unix socket (/tmp/claude-dashboard.sock)
    |
    v
Dashboard TUI (kb-cc-dashboard)
```

All 17 Claude Code hook events (UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, SubagentStart, SubagentStop, Stop, StopFailure, PreCompact, PostCompact, SessionStart, SessionEnd, InstructionsLoaded, PermissionRequest, ConfigChange, TaskCreated, TaskCompleted) are forwarded asynchronously to a Unix domain socket. The bridge enriches tool events with `agent_context_type` when a matching agent is on the stack.

## Prerequisites

- **jq** -- required for JSON parsing and event enrichment
- **socat** -- recommended for socket relay (falls back to `nc` if unavailable)

## Installation

```bash
claude plugin install dashboard@kb-cc-plugin
```

## Configuration

| Key | Description | Default |
|-----|-------------|---------|
| `socket_path` | Path to the Unix socket the TUI listens on | `/tmp/claude-dashboard.sock` |

The socket path is resolved in this priority order:
1. `CLAUDE_PLUGIN_OPTION_SOCKET_PATH` (plugin userConfig)
2. `SOCKET` environment variable
3. `/tmp/claude-dashboard.sock`

## Pair with TUI

This plugin is designed to work with the dashboard TUI:

https://github.com/pmmm114/kb-cc-dashboard

Start the TUI first (it creates the Unix socket), then use Claude Code normally. All hook events will appear in the dashboard in real time.

## How it works

1. Claude Code fires a hook event (e.g., PreToolUse)
2. `hooks.json` routes the event to `bridge.sh` with `async: true`
3. `bridge.sh` checks if the dashboard socket exists -- exits immediately if not (zero overhead when TUI is not running)
4. For SubagentStart/Stop events, the agent stack is updated
5. For tool events (PreToolUse, PostToolUse, PostToolUseFailure), the event is enriched with `agent_context_type` if a matching agent is on the stack
6. The event JSON is sent to the Unix socket via socat (or nc fallback)
