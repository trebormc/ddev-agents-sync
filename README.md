[![tests](https://github.com/trebormc/ddev-agents-sync/actions/workflows/tests.yml/badge.svg)](https://github.com/trebormc/ddev-agents-sync/actions/workflows/tests.yml)

# ddev-agents-sync

A DDEV add-on that automatically syncs AI agent repositories into a shared Docker volume. Supports multiple repos with override priority — perfect for combining public agents with private customizations.

On every `ddev start`, this container clones or updates the configured repositories and merges them into a single directory accessible by [ddev-opencode](https://github.com/trebormc/ddev-opencode) and [ddev-claude-code](https://github.com/trebormc/ddev-claude-code).

## Quick Start

```bash
# Install the add-on (default: syncs trebormc/drupal-ai-agents)
ddev add-on get trebormc/ddev-agents-sync
ddev restart
```

That's it. OpenCode and Claude Code will automatically pick up the synced agents.

## Prerequisites

- [DDEV](https://ddev.readthedocs.io/) >= v1.23.5

## Installation

```bash
ddev add-on get trebormc/ddev-agents-sync
```

This add-on is automatically installed as a dependency of [ddev-opencode](https://github.com/trebormc/ddev-opencode) and [ddev-claude-code](https://github.com/trebormc/ddev-claude-code).

## Configuration

Edit `.ddev/.env.agents-sync`:

```bash
# Comma-separated list of git repositories to sync
# Later repos override earlier ones (useful for private overrides)
AGENTS_REPOS=https://github.com/trebormc/drupal-ai-agents.git

# Set to "false" to disable automatic sync on ddev start
AGENTS_AUTO_UPDATE=true
```

### Single repo (default)

```bash
AGENTS_REPOS=https://github.com/trebormc/drupal-ai-agents.git
```

### Multiple repos (public + private override)

```bash
AGENTS_REPOS=https://github.com/trebormc/drupal-ai-agents.git,https://github.com/your-org/private-agents.git
```

Files from later repos override earlier ones. This lets you use the public Drupal agents as a base and add (or replace) specific agents/skills from a private repo.

### Disable auto-update

```bash
AGENTS_AUTO_UPDATE=false
```

When disabled, the container uses previously cached repos without attempting `git pull`. Useful for offline work or when you want to pin a specific version.

## How It Works

```
On ddev start:
  ┌─────────────────────────────────────────────────────────┐
  │  agents-sync container                                   │
  │                                                          │
  │  1. For each repo in AGENTS_REPOS:                      │
  │     - If not cloned: git clone --depth 1                │
  │     - If cloned: git pull --ff-only (silent on failure) │
  │                                                          │
  │  2. Merge all repos into /agents (shared volume):       │
  │     /tmp/agent-repos/repo-0/ ─┐                         │
  │     /tmp/agent-repos/repo-1/ ─┼─► /agents/              │
  │     /tmp/agent-repos/repo-2/ ─┘   (later repos win)    │
  │                                                          │
  │  3. Sleep (stay alive for depends_on)                   │
  └─────────────────────────────────────────────────────────┘

  ┌──────────────────┐  ┌──────────────────┐
  │   OpenCode       │  │   Claude Code    │
  │   reads /agents  │  │   reads /agents  │
  │   (read-only)    │  │   (read-only)    │
  └──────────────────┘  └──────────────────┘
```

The `/agents` directory is a Docker named volume (`ddev-{sitename}-agents`) — not visible on the host filesystem. It persists between restarts and is shared between containers.

### Merge strategy

Files are copied from each repo in order. The merge is a simple file-level override:

- `agent/*.md` — merged (later repos can add or override agents)
- `skills/*/SKILL.md` — merged (later repos can add or override skills)
- `rules/*.md` — merged (later repos can add or override rules)
- `CLAUDE.md`, `opencode.json` — overridden by the last repo that provides them

### Override priority

```bash
AGENTS_REPOS=repo-A,repo-B,repo-C
```

If both repo-A and repo-C have `agent/drupal-dev.md`, the version from repo-C wins.

## Commands

### `ddev agents-update`

Manually trigger a sync without restarting DDEV:

```bash
ddev agents-update
```

## Local Path Mode

If you prefer to manage agents locally instead of syncing from git, you can skip this add-on and use the host directory mount in OpenCode or Claude Code:

```bash
# In .ddev/.env.opencode
HOST_OPENCODE_CONFIG_DIR=/path/to/your/local/agents/
```

When `HOST_OPENCODE_CONFIG_DIR` is set, OpenCode uses the host directory directly instead of the shared volume.

## Related

- [drupal-ai-agents](https://github.com/trebormc/drupal-ai-agents) -- Default agents, rules, and skills for Drupal development
- [ddev-opencode](https://github.com/trebormc/ddev-opencode) -- OpenCode AI container
- [ddev-claude-code](https://github.com/trebormc/ddev-claude-code) -- Claude Code container
- [ddev-ralph](https://github.com/trebormc/ddev-ralph) -- Autonomous task runner

## Disclaimer

This project is not affiliated with Anthropic, OpenCode, Beads, Playwright, Microsoft, or DDEV. AI-generated code may contain errors -- always review changes before deploying to production. See [menetray.com](https://menetray.com) for more information and [DruScan](https://druscan.com) for Drupal auditing tools.

## License

Apache-2.0. See [LICENSE](LICENSE).
