# Bundling Principle

Agent Foundry uses a self-extracting archive (SFX) strategy for distribution:

1. **The Bundle**: A shell script stub fused with a compressed tarball payload.
2. **Execution**: On every run, the stub extracts the payload to a unique `/tmp` directory.
3. **Dispatch**: The CLI executes from the temporary directory and automatically deletes it upon exit.

This provides a single-binary experience while keeping the internal structure modular and dependency-free.

# Home Directory Resolution

Agent Foundry is often run with `doas`/`sudo`, which sets `$HOME` to `/root`. Code that constructs user paths must **never** use `$HOME` or unqualified `~` for runtime path resolution on the host.

Use the existing helpers in `lib/utils.sh`:

- `resolve_host_user()` — returns the real invoking user (`SUDO_USER`, `DOAS_USER`, or `$USER`).
- `resolve_host_home()` — returns that user's home directory (via `getent passwd`, falling back to `$HOME`).

Example:

```bash
host_home="$(resolve_host_home)"
config_dir="${FOUNDRY_CONFIG_DIR:-${host_home}/.config/foundry}"
```

Rules:

1. Always call `resolve_host_home()` when building paths to `~/.config/foundry`, `~/.local/share/foundry`, or user-owned project directories.
2. Do not declare local variables named `token`, `secret`, or any other name that matches a caller-passed variable name when using `printf -v "$var_name"`; it will write to the local shadow instead of the caller's variable.
3. Inside VM scripts (running as `root` in the VM), `$HOME` is `/root` and may be used normally.
4. Help text and comments may use `~` for readability; runtime code must not.

# Config-Driven Automation

Agent Foundry is **config-driven**: if a piece of information or behavior is present in the project configuration, the CLI should act on it automatically instead of requiring the user to run additional commands.

Principles:

1. **One command to activate**: Running a top-level command (e.g. `foundry agent forgejo-watcher init <vm>`) should apply the full configuration. If the config says register hooks, register them. If it says watch repos, watch them.
2. **Auto-derive what you can**: IP addresses, URLs, ports, and other runtime values should be derived from the environment whenever possible. Only prompt or require explicit input when derivation is impossible.
3. **Opt-out, not opt-in**: Prefer automatic behavior with a flag to disable it (e.g. `--no-register-hooks`, `--no-mark-all`) over requiring a separate command to enable it.
4. **Keep escape hatches**: Always provide explicit manual commands and opt-out flags for power users and debugging.

Examples:

- `forgejo-watcher init` auto-registers webhooks because `watched_repos` and `webhook_url` are in the config.
- `forgejo-watcher start` auto-runs `mark-all` because the default lifecycle expectation is "don't reprocess old events on restart".
- `webhook_url` is auto-derived from the VM IP because the VM already knows its own address.

If a user has to run more than one command to make a configured feature work, the design is probably wrong.

# Sanity Checks

Validate inputs and configuration early. A command that will obviously fail should fail immediately with a clear message, not half-run and leave the user with a cryptic downstream error.

Examples:

- If a config file references `token_file` or `admin_token_file`, verify the file exists and is non-empty before doing anything else.
- If a required external service credential is missing, stop before creating VMs, writing config, or making API calls.
- If a URL or network setting is malformed, reject it at load time.

Sanity checks prevent silent misconfiguration and save debugging time. When a check fails, tell the user exactly which file, value, or setting is wrong and what to do about it.

# Watcher Lifecycle

When a watcher daemon starts, it should not immediately process a large backlog of old events. Restarts happen for updates, maintenance, and configuration changes, and the backlog may already have been handled.

For webhook-driven watchers (e.g. Forgejo):

- `start` should automatically mark existing open issues/PRs as processed before beginning event processing.
- Provide an explicit opt-out flag (e.g. `--no-mark-all`) for users who genuinely want to process the backlog.
- Keep `mark-all` as a separate command so users can run it independently.

This prevents the agent from re-triggering on stale events every time the service restarts.

# Documentation of External Service Requirements

Any integration that depends on an external service (e.g. Forgejo, GitHub, GitLab) must document the exact setup requirements in the user-facing docs under `docs/`.

At minimum, document:

1. **Required API token scopes / permissions**, including any distinction between normal-operation tokens and admin-only tokens.
2. **Network requirements**, especially when containers, VMs, NAT, or proxies are involved. Include common failure symptoms (e.g. "No route to host", `403 reqAdmin`, webhook delivery timeouts).
3. **How to verify connectivity** from the external service to the watcher (curl, test delivery, logs).
4. **Security-relevant configuration** on the external service side (e.g. `ALLOWED_HOST_LIST` for Forgejo webhooks).

Do not rely on error messages alone to teach users how to set up the integration. Assume the user has never configured the external service before.

# No Silent Failures

CLI commands and helper scripts must **never succeed when the underlying operation failed**. A command that cannot complete its primary task must exit with a non-zero status and print a clear, actionable error message.

Examples:

- A webhook registration command that receives `403 Forbidden` must exit non-zero and explain that the token lacks admin permissions.
- A clone/setup command that cannot reach the remote must fail loudly, not warn and continue.
- A `status` command that cannot contact the daemon must say so, not print stale "running" output.

Err on the side of being too noisy. Users can ignore a clear error; they cannot fix a silent failure.

## Surface Remote Errors in the CLI

When a command runs a helper inside a VM or container, the **host CLI must print the actual error**, not just "command failed". Remote log files are useful for debugging, but they are not a substitute for immediate console output.

If a remote helper writes a detailed error to `/root/.config/.../some.log`, the host CLI should tail or cat that log when the helper exits non-zero, so the user sees the root cause in the same terminal where they ran the command.

# Validation

Run `./scripts/shellcheck.sh` and `./scripts/syntax-check.sh` before committing.
