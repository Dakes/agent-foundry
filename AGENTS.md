# Bundling Principle

Agent Foundry uses a self-extracting archive (SFX) strategy for distribution:

1. **The Bundle**: A shell script stub fused with a compressed tarball payload.
2. **Execution**: On every run, the stub extracts the payload to a unique `/tmp` directory.
3. **Dispatch**: The CLI executes from the temporary directory and automatically deletes it upon exit.

This provides a single-binary experience while keeping the internal structure modular and dependency-free.
