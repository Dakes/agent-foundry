Never spawn Agents using your native "Task" feature. always spawn agents using the gemini and codex skills. This is to conserve tokens used.

## Installation Updates

When updating the foundry binary after code changes, always use the install script instead of manually copying:

```bash
./install.sh --prefix ~/.local --no-setup
```

This ensures:
- Proper file permissions are set
- Library paths are correctly resolved
- Shell RC files are automatically sourced (user doesn't need manual sourcing)
- Works with any shell (bash, zsh, fish)

Do NOT manually copy the binary with `cp` as it bypasses these setup steps.

## Commit Messages

Keep commit messages compact:
- For small changes: One sentence is sufficient
- Avoid lengthy descriptions for trivial fixes

