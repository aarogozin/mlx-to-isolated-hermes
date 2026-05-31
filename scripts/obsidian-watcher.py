#!/usr/bin/env python3
import os
import sys
import time
import yaml
import subprocess
import shutil
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

# Global active process tracking state
active_proc = None
active_file = None
active_log_file = None
active_fm = None
active_body = None

def main():
    global active_proc, active_file, active_log_file, active_fm, active_body
    
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

            # ── 1. CHECK RUNNING ACTIVE PROCESS ──
            if active_proc is not None:
                ret = active_proc.poll()
                if ret is not None:
                    # Active process finished!
                    print(f"Active process finished with return code: {ret}")
                    active_log_file.close()
                    
                    log_path = Path("/tmp/active_task.log")
                    log_content = ""
                    if log_path.exists():
                        try:
                            log_content = log_path.read_text(encoding="utf-8")
                        except Exception as e:
                            log_content = f"[Error reading execution logs: {e}]"
                    
                    # Directories
                    RESEARCHES_DIR = VAULT_DIR / "researches"
                    ARCHIVE_DIR = TASKS_DIR / "archive"
                    
                    active_fm["completed_at"] = datetime.now().isoformat()
                    
                    if ret == 0:
                        active_fm["status"] = "completed"
                        agent_response = log_content.strip()
                        date_str = datetime.now().strftime("%Y-%m-%d")
                        
                        daily_dir = RESEARCHES_DIR / date_str
                        daily_dir.mkdir(parents=True, exist_ok=True)
                        research_file_name = active_file.name
                        research_file_path = daily_dir / research_file_name
                        
                        research_content = (
                            f"# Research: {active_file.stem.replace('_', ' ').title()}\n"
                            f"**Date:** {date_str}\n\n"
                            f"## Request\n"
                            f"{active_body}\n\n"
                            f"---\n\n"
                            f"## Response\n\n"
                            f"{agent_response}\n"
                        )
                        try:
                            research_file_path.write_text(research_content, encoding="utf-8")
                            active_fm["research_file"] = f"researches/{date_str}/{research_file_name}"
                        except Exception as e:
                            print(f"Failed to write research file: {e}")
                            active_fm["research_file_error"] = str(e)
                            
                        print(f"Task completed successfully: {active_file.name}")
                        
                        # Write updated task file (with completed status)
                        try:
                            active_file.write_text(format_note(active_fm, active_body), encoding="utf-8")
                        except Exception as e:
                            print(f"Failed to write task file before archiving: {e}")
                            
                        # Move the task file to archive/
                        try:
                            ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
                            archive_path = ARCHIVE_DIR / active_file.name
                            if archive_path.exists():
                                archive_path.unlink()
                            shutil.move(str(active_file), str(archive_path))
                            print(f"Archived task: {active_file.name} -> {archive_path.name}")
                        except Exception as e:
                            print(f"Failed to archive task file: {e}")
                    else:
                        active_fm["status"] = "failed"
                        active_fm["error"] = log_content.strip() or f"Exit code {ret}"
                        print(f"Task failed with error: {active_fm['error']}")
                        try:
                            active_file.write_text(format_note(active_fm, active_body), encoding="utf-8")
                        except Exception as e:
                            print(f"Failed to write failed status back to note {active_file.name}: {e}")
                    
                    # Reset active state
                    active_proc = None
                    active_file = None
                    active_log_file = None
                    active_fm = None
                    active_body = None
                else:
                    # Process is still running, check if task has been cancelled/modified by user
                    if not active_file.exists():
                        print(f"Active task file {active_file.name} was deleted. Terminating process...")
                        active_proc.terminate()
                        try:
                            active_proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            active_proc.kill()
                        active_log_file.close()
                        
                        # Reset active state
                        active_proc = None
                        active_file = None
                        active_log_file = None
                        active_fm = None
                        active_body = None
                    else:
                        try:
                            content = active_file.read_text(encoding="utf-8")
                            fm, _ = parse_note(content)
                            status = fm.get("status")
                            # If user changed status away from processing, abort the task
                            if status != "processing":
                                print(f"Active task status changed to {status}. Aborting research process...")
                                active_proc.terminate()
                                try:
                                    active_proc.wait(timeout=5)
                                except subprocess.TimeoutExpired:
                                    active_proc.kill()
                                active_log_file.close()
                                
                                # Read current logs for partial output
                                log_path = Path("/tmp/active_task.log")
                                partial_log = ""
                                if log_path.exists():
                                    try:
                                        partial_log = log_path.read_text(encoding="utf-8")
                                    except Exception:
                                        pass
                                
                                # Update to failed / aborted
                                active_fm["status"] = "failed"
                                active_fm["error"] = f"Aborted by user (status changed to {status})"
                                if partial_log:
                                    active_fm["partial_output"] = partial_log.strip()
                                active_fm["completed_at"] = datetime.now().isoformat()
                                
                                try:
                                    active_file.write_text(format_note(active_fm, active_body), encoding="utf-8")
                                except Exception as e:
                                    print(f"Failed to write aborted status to note: {e}")
                                    
                                # Archive the aborted task note
                                ARCHIVE_DIR = TASKS_DIR / "archive"
                                try:
                                    ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
                                    archive_path = ARCHIVE_DIR / active_file.name
                                    if archive_path.exists():
                                        archive_path.unlink()
                                    shutil.move(str(active_file), str(archive_path))
                                    print(f"Archived aborted task: {active_file.name} -> {archive_path.name}")
                                except Exception as e:
                                    print(f"Failed to archive aborted task note: {e}")
                                    
                                # Reset active state
                                active_proc = None
                                active_file = None
                                active_log_file = None
                                active_fm = None
                                active_body = None
                        except Exception as e:
                            print(f"Error checking status of active task file: {e}")

            # ── 2. SCAN FOR NEW PENDING TASKS (ONLY if no active task is running) ──
            if active_proc is None:
                for file_path in TASKS_DIR.glob("*.md"):
                    if not file_path.is_file():
                        continue
                    
                    try:
                        content = file_path.read_text(encoding="utf-8")
                    except Exception:
                        continue
                        
                    fm, body = parse_note(content)
                    status = fm.get("status")
                    
                    if status == "pending":
                        try:
                            mtime = file_path.stat().st_mtime
                            if time.time() - mtime < 5:
                                continue  # Debounce: still being written to, skip
                        except Exception:
                            continue
                        
                        print(f"Found pending task: {file_path.name}")
                        # Mark as processing
                        fm["status"] = "processing"
                        fm["started_at"] = datetime.now().isoformat()
                        try:
                            file_path.write_text(format_note(fm, body), encoding="utf-8")
                        except Exception as e:
                            print(f"Failed to mark task as processing: {e}")
                            continue
                            
                        print(f"Starting agent process on task: {file_path.name}")
                        
                        args = ["/opt/hermes/bin/hermes"]
                        if "session_id" in fm and fm["session_id"]:
                            args.extend(["--resume", str(fm["session_id"])])
                        elif "session" in fm and fm["session"]:
                            args.extend(["--continue", str(fm["session"])])
                        args.extend(["-z", body])
                        
                        log_path = Path("/tmp/active_task.log")
                        if log_path.exists():
                            try:
                                log_path.unlink()
                            except Exception:
                                pass
                        
                        try:
                            log_file = open(log_path, "w", encoding="utf-8")
                        except Exception as e:
                            print(f"Failed to open task log file: {e}")
                            # Revert note status to failed
                            fm["status"] = "failed"
                            fm["error"] = f"Failed to open task log file: {e}"
                            file_path.write_text(format_note(fm, body), encoding="utf-8")
                            continue
                            
                        try:
                            proc = subprocess.Popen(
                                args,
                                stdout=log_file,
                                stderr=subprocess.STDOUT,
                                text=True,
                                env={**os.environ, "HF_HOME": "/opt/data/.cache/huggingface"}
                            )
                            # Set active state
                            active_proc = proc
                            active_file = file_path
                            active_log_file = log_file
                            active_fm = fm
                            active_body = body
                            
                            # Break so we don't start other pending tasks concurrently
                            break
                        except Exception as e:
                            print(f"Failed to spawn agent process: {e}")
                            log_file.close()
                            fm["status"] = "failed"
                            fm["error"] = f"Failed to spawn process: {e}"
                            file_path.write_text(format_note(fm, body), encoding="utf-8")
                            continue
                            
        except Exception as e:
            print(f"Error in watcher loop: {e}")
            
        # If a task is actively running, sleep 2 seconds for high responsiveness.
        # Otherwise, sleep for the configured POLL_INTERVAL_SECONDS to reduce idle load.
        if active_proc is not None:
            time.sleep(2)
        else:
            time.sleep(POLL_INTERVAL_SECONDS)

if __name__ == "__main__":
    main()
