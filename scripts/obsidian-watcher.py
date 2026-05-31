#!/usr/bin/env python3
import os
import sys
import time
import yaml
import subprocess
from pathlib import Path
from datetime import datetime

def load_env():
    env_path = Path("/opt/data/.env")
    if env_path.exists():
        try:
            for line in env_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    # Strip quotes if any
                    k_str = k.strip()
                    v_str = v.strip().strip("'").strip('"')
                    os.environ[k_str] = v_str
        except Exception as e:
            print(f"Warning: failed to load environment file: {e}")

load_env()

# Setup paths and configurations
VAULT_DIR = Path("/mnt/obsidian")
TASKS_DIR = VAULT_DIR / "_tasks"
LOCK_FILE = Path("/tmp/obsidian-watcher.lock")
POLL_INTERVAL_SECONDS = int(os.environ.get("OBSIDIAN_WATCH_INTERVAL_SECONDS", "30"))

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
    
    # Setup directories
    RESEARCHES_DIR = VAULT_DIR / "researches"
    ARCHIVE_DIR = TASKS_DIR / "archive"

    # Update frontmatter and write response
    fm["completed_at"] = datetime.now().isoformat()
    
    if res.returncode == 0:
        fm["status"] = "completed"
        agent_response = res.stdout.strip()
        date_str = datetime.now().strftime("%Y-%m-%d")
        
        # Save detailed response to researches/YYYY-MM-DD/
        daily_dir = RESEARCHES_DIR / date_str
        daily_dir.mkdir(parents=True, exist_ok=True)
        research_file_name = file_path.name
        research_file_path = daily_dir / research_file_name
        
        research_content = (
            f"# Research: {file_path.stem.replace('_', ' ').title()}\n"
            f"**Date:** {date_str}\n\n"
            f"## Request\n"
            f"{body}\n\n"
            f"---\n\n"
            f"## Response\n\n"
            f"{agent_response}\n"
        )
        try:
            research_file_path.write_text(research_content, encoding="utf-8")
            # Point to the research file in frontmatter
            fm["research_file"] = f"researches/{date_str}/{research_file_name}"
        except Exception as e:
            print(f"Failed to write research file: {e}")
            fm["research_file_error"] = str(e)
            
        print(f"Task completed successfully: {file_path.name}")
        
        # Write updated task file (with completed status)
        try:
            file_path.write_text(format_note(fm, body), encoding="utf-8")
        except Exception as e:
            print(f"Failed to write task file before archiving: {e}")
            
        # Move the task file to archive/
        try:
            ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
            archive_path = ARCHIVE_DIR / file_path.name
            
            # If a file already exists in archive, delete it to overwrite
            if archive_path.exists():
                archive_path.unlink()
            
            import shutil
            shutil.move(str(file_path), str(archive_path))
            print(f"Archived task: {file_path.name} -> {archive_path.name}")
        except Exception as e:
            print(f"Failed to archive task file: {e}")
            
    else:
        fm["status"] = "failed"
        fm["error"] = res.stderr.strip() or res.stdout.strip() or f"Exit code {res.returncode}"
        print(f"Task failed with error: {fm['error']}")
        
        try:
            file_path.write_text(format_note(fm, body), encoding="utf-8")
        except Exception as e:
            print(f"Failed to write failed status back to note {file_path.name}: {e}")

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
                
                # ONLY process task if status is explicitly set to 'pending'
                # and the file has not been modified in the last 5 seconds (debounce to prevent reading partial edits)
                if status == "pending":
                    try:
                        mtime = file_path.stat().st_mtime
                        if time.time() - mtime < 5:
                            continue  # Note is still being written to, skip for now
                    except Exception:
                        continue
                    process_task(file_path)
                    
        except Exception as e:
            print(f"Error in watcher loop: {e}")
            
        time.sleep(POLL_INTERVAL_SECONDS)

if __name__ == "__main__":
    main()
