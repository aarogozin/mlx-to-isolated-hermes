#!/usr/bin/env python3
import os
import sys
import time
import yaml
import subprocess
from pathlib import Path
from datetime import datetime

# Setup paths and configurations
VAULT_DIR = Path("/mnt/obsidian")
TASKS_DIR = VAULT_DIR / "_tasks"
LOCK_FILE = Path("/tmp/obsidian-watcher.lock")
POLL_INTERVAL_SECONDS = 5

def acquire_lock():
    """Ensure only one instance of the watcher is running inside the container."""
    if LOCK_FILE.exists():
        try:
            pid = int(LOCK_FILE.read_text().strip())
            # Check if process is actually running
            os.kill(pid, 0)
            print(f"Watcher already running with PID {pid}. Exiting.")
            sys.exit(0)
        except (ValueError, OSError):
            # Process not running, stale lock file
            LOCK_FILE.unlink(missing_ok=True)
            
    LOCK_FILE.write_text(str(os.getpid()))

def parse_note(content):
    """Robustly parse frontmatter and body from a markdown file."""
    lines = content.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, content
    
    fm_lines = []
    body_lines = []
    in_fm = True
    for line in lines[1:]:
        if in_fm and line.strip() == "---":
            in_fm = False
            continue
        if in_fm:
            fm_lines.append(line)
        else:
            body_lines.append(line)
            
    if in_fm:
        # Ending --- was never found, treat everything as body
        return {}, content
        
    try:
        fm = yaml.safe_load("\n".join(fm_lines)) or {}
    except Exception as e:
        print(f"Error parsing YAML frontmatter: {e}")
        fm = {}
        
    return fm, "\n".join(body_lines).strip()

def format_note(fm, body):
    """Serialize frontmatter and body back to a markdown string."""
    fm_str = yaml.safe_dump(fm, default_flow_style=False).strip()
    return f"---\n{fm_str}\n---\n{body}"

def process_task(file_path):
    print(f"Found pending task: {file_path.name}")
    try:
        content = file_path.read_text(encoding="utf-8")
    except Exception as e:
        print(f"Failed to read file {file_path.name}: {e}")
        return

    fm, body = parse_note(content)
    
    # Check status state
    status = fm.get("status")
    if status in ("processing", "completed", "failed"):
        return
        
    # Mark as processing
    fm["status"] = "processing"
    fm["started_at"] = datetime.now().isoformat()
    try:
        file_path.write_text(format_note(fm, body), encoding="utf-8")
    except Exception as e:
        print(f"Failed to mark task as processing: {e}")
        return

    print(f"Running agent on task: {file_path.name}")
    
    # Prepare hermes command args
    args = ["/opt/hermes/bin/hermes"]
    
    # Respect session resume tags
    if "session_id" in fm and fm["session_id"]:
        args.extend(["--resume", str(fm["session_id"])])
    elif "session" in fm and fm["session"]:
        args.extend(["--continue", str(fm["session"])])
        
    args.extend(["-z", body])
    
    # Run the agent CLI
    res = subprocess.run(
        args,
        capture_output=True,
        text=True,
        env={**os.environ, "HF_HOME": "/opt/data/.cache/huggingface"}
    )
    
    # Update frontmatter and write response
    fm["completed_at"] = datetime.now().isoformat()
    
    if res.returncode == 0:
        fm["status"] = "completed"
        agent_response = res.stdout.strip()
        timestamp = datetime.now().strftime("%d.%m.%Y %H:%M")
        
        # Append answer to body
        updated_body = (
            f"{body}\n\n"
            f"## Ответ агента ({timestamp})\n\n"
            f"{agent_response}"
        )
        print(f"Task completed successfully: {file_path.name}")
    else:
        fm["status"] = "failed"
        fm["error"] = res.stderr.strip() or res.stdout.strip() or f"Exit code {res.returncode}"
        updated_body = body
        print(f"Task failed with error: {fm['error']}")

    try:
        file_path.write_text(format_note(fm, updated_body), encoding="utf-8")
    except Exception as e:
        print(f"Failed to write results back to note {file_path.name}: {e}")

def main():
    acquire_lock()
    print("Obsidian note watcher service started.")
    print(f"Watching folder: {TASKS_DIR}")

    while True:
        try:
            if not VAULT_DIR.exists():
                # Vault is not mounted yet, sleep and wait
                time.sleep(POLL_INTERVAL_SECONDS)
                continue
                
            if not TASKS_DIR.exists():
                TASKS_DIR.mkdir(parents=True, exist_ok=True)
                
            # Scan files
            for file_path in TASKS_DIR.glob("*.md"):
                if not file_path.is_file():
                    continue
                
                try:
                    content = file_path.read_text(encoding="utf-8")
                except Exception:
                    continue
                    
                fm, _ = parse_note(content)
                status = fm.get("status")
                
                # Treat as pending if status is empty, not set, or set to 'pending'
                if not status or status == "pending":
                    process_task(file_path)
                    
        except Exception as e:
            print(f"Error in watcher loop: {e}")
            
        time.sleep(POLL_INTERVAL_SECONDS)

if __name__ == "__main__":
    main()
