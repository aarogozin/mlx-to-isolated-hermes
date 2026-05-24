# Release Checklist

## 0.3.0

1. Start from a clean public workspace.
2. Run host bootstrap and diagnostics:

   ```bash
   make bootstrap
   make doctor
   ```

3. Launch LM Studio once if `lms` was not initialized, then rerun `make bootstrap`.
4. Download at least one MLX safetensors LLM in LM Studio.
5. Run the standard setup flow:

   ```bash
   make setup
   make agent-status
   make agent-open-dashboard
   ```

6. If `OBSIDIAN_SHARED_PATH` is configured, verify the shared folder:

   ```bash
   make shared-mounts-check
   ```

7. Scan local model stores before release:

   ```bash
   make models-doctor
   ```

   Use `make models-prune-incomplete` only for artifacts that are clearly stale/incomplete.

8. Smoke the selected OpenClaw paths when changing OpenClaw wiring:

   ```bash
   AGENT_RUNTIME=openclaw SANDBOX_BACKEND=docker make agent-start
   AGENT_RUNTIME=openclaw SANDBOX_BACKEND=docker make agent-stop
   AGENT_RUNTIME=openclaw SANDBOX_BACKEND=multipass make agent-switch
   AGENT_RUNTIME=openclaw SANDBOX_BACKEND=multipass make agent-pause
   ```

   Confirm Hermes and OpenClaw use separate VMs:

   ```bash
   AGENT_RUNTIME=hermes make vm-status
   AGENT_RUNTIME=openclaw make vm-status
   ```

9. Stop, snapshot, and restart the Multipass VM:

   ```bash
   make vm-stop
   make vm-snapshot
   make vm-start
   ```

10. Run final release gate:

   ```bash
   make release-check
   ```

11. Confirm no local runtime state is tracked:

   ```bash
   git status --short
   git ls-files .env .runtime .vm .cache
   ```

12. Commit, tag, and push:

   ```bash
   git add .
   git commit -m "Release 0.3.0"
   git tag v0.3.0
   git push origin HEAD --tags
   ```
