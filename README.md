# kb-cc-plugin

Personal Claude Code plugin marketplace.

## Plugins

| Plugin | Description |
|--------|-------------|
| [error-reporter](error-reporter/) | Hook debug log 분석 → GitHub Issue 자동 생성 |

## Installation

```bash
# Add marketplace (once)
/plugin marketplace add kb-cc-plugin

# Or in settings.json extraKnownMarketplaces:
# "kb-cc-plugin": { "source": { "source": "github", "repo": "pmmm114/kb-cc-plugin" } }

# Install plugin
/plugin install error-reporter@kb-cc-plugin
```
