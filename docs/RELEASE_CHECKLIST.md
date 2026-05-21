# Release Checklist

## 0.1.0

1. Start from a clean public workspace.
2. Run `make bootstrap`.
3. Launch LM Studio once if `lms` was not initialized, then rerun `make bootstrap`.
4. Download at least one MLX safetensors LLM in LM Studio.
5. Run `make models-list`.
6. Run `make vm-create` if the Multipass VM does not exist.
7. Run `make e2e-ready`.
8. Stop, snapshot, and restart the VM:

   ```bash
   make vm-stop
   make vm-snapshot
   make vm-start
   ```

9. Run Docker preview smoke:

   ```bash
   make docker-e2e
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
    git commit -m "Release 0.1.0"
    git tag v0.1.0
    git push origin HEAD --tags
    ```
