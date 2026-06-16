# Foundry CLI Reference

All commands run from the host system.

## Command Structure

```bash
foundry <domain> <action> [arguments] [options]
```

## Global Options

```bash
-h, --help      Show help
-v, --version   Show version
--verbose       Enable verbose logs
--dry-run       Print intended actions without executing
```

## VM Commands

```bash
foundry vm create <name> [template] [-y|--yes] [--ssh-key <path>] [--project <name|path>]
foundry vm start <name>
foundry vm stop <name>
foundry vm restart <name>
foundry vm destroy <name>
foundry vm ssh <name> [command...]
foundry vm list
foundry vm status <name>
foundry vm ip <name>
foundry vm copy <source> <dest>
foundry vm rename <old> <new>
foundry vm snapshot <name> <snapshot>
foundry vm update <name>
```

Notes:
- VM lifecycle operations require root privileges.
- `create --project` expects a project directory that includes `git-config.json`.
- If `--ssh-key` is omitted, Foundry generates a per-VM keypair under `~/.local/share/foundry/vms/<name>/ssh/`.

## Agent Commands

```bash
foundry agent start <vm> [type]
foundry agent stop <vm>
foundry agent restart <vm>
foundry agent attach <vm>
foundry agent status <vm>
foundry agent logs <vm> [-f|--follow]
foundry agent enable-autostart <vm>
foundry agent disable-autostart <vm>
```

Agent types:
- `ralph` - ralph-claude-code autonomous agent
- `ralph-orchestrator` - ralph-orchestrator autonomous agent
- `kimi-ralph` - Kimi Code CLI autonomous agent in Ralph mode
- `claude` - Claude Code CLI interactive session
- `gemini` - Gemini CLI interactive session
- `codex` - OpenAI Codex CLI interactive session

Note: each VM may run only one autonomous agent at a time.

## GitHub Watcher Commands

```bash
foundry agent gh-watcher init <vm>
foundry agent gh-watcher start <vm>
foundry agent gh-watcher stop <vm>
foundry agent gh-watcher status <vm>
foundry agent gh-watcher logs <vm> [--follow]
foundry agent gh-watcher reset <vm>
```

## Workspace Commands

```bash
foundry workspace init <vm> <config.json>
foundry workspace sync <vm> [project]
foundry workspace init-ralph <vm>
foundry workspace edit <vm> <file>
foundry workspace info <vm>
foundry workspace template [file]
```

Notes:
- `workspace sync` updates `.ralph/.kimi/.claude/.codex/.gemini`, `.ralphrc`, top-level `ralph*.yml`, and top-level `*.md` files.
- If `[project]` is omitted, Foundry tries to resolve project metadata from VM registry.

## Template Commands

```bash
foundry template list
foundry template build base
foundry template build golden
```

## Host Commands

```bash
foundry host setup
foundry host status
```

## Network Commands

```bash
foundry network init
foundry network status
foundry network cleanup
```

## Config Commands

```bash
foundry config get <key>
foundry config set <key> <value>
foundry config edit
foundry config show
```

Config keys are normalized to uppercase underscore form internally. For example:
- `default.cpus` -> `DEFAULT_CPUS`
- `default.memory` -> `DEFAULT_MEMORY`
