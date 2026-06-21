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
