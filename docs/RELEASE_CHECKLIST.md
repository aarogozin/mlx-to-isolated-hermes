# Release Checklist

## 0.4.0

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

   If another agent stack is already active, confirm that the wizard reports it and offers reuse, pause/restart, clean-all, continue-anyway, or abort as appropriate.

6. If `OBSIDIAN_SHARED_PATH` is configured, verify the shared folder and RAG:

   ```bash
   make shared-mounts-check
   make rag-preflight
   make rag-install
   make rag-up
   make rag-sync
   make rag-search QUERY="release smoke"
   make rag-status
   ```

   Stop the Docker RAG stack after the smoke when you do not want it left running:

   ```bash
   RAG_RUNTIME=docker make rag-down
   ```

   OCR/document parsing runs inside Docker parser containers. Host Tesseract and host Python RAG dependencies are not installed by default.

   Optional legacy host-RAG smoke:

   ```bash
   RAG_RUNTIME=host INSTALL_RAG_HOST=1 make rag-install
   RAG_RUNTIME=host INSTALL_RAG_HOST=1 RAG_OCR_ENABLED=1 scripts/test-rag-ocr-smoke.sh
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

9. Optional Multipass snapshot check through the low-level VM script:

   ```bash
   ./scripts/vm-control.sh stop
   ./scripts/vm-control.sh snapshot
   ./scripts/vm-control.sh start
   ```

10. Run final release gate:

   ```bash
   make release-check
   ```

   For a full local sandbox matrix before tagging, run:

   ```bash
   make matrix-e2e
   ```

11. Confirm no local runtime state is tracked:

   ```bash
   git status --short
   git ls-files .env .runtime .vm .cache
   scripts/check-english-text.py
   ```

12. Commit, tag, and push:

   ```bash
   git add .
   git commit -m "Release 0.4.0"
   git tag v0.4.0
   git push origin HEAD --tags
   ```
