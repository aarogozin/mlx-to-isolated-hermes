#!/usr/bin/env python3
import json
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

def wait_for_syncthing(timeout=30):
    start = time.time()
    while time.time() - start < timeout:
        res = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Running}}", "mlx-syncthing"],
            capture_output=True,
            text=True
        )
        if res.returncode == 0 and res.stdout.strip() == "true":
            return True
        time.sleep(1)
    return False

def get_api_key():
    res = subprocess.run(
        ["docker", "exec", "mlx-syncthing", "cat", "/var/syncthing/config/config.xml"],
        capture_output=True,
        text=True
    )
    if res.returncode != 0:
        return None
    try:
        root = ET.fromstring(res.stdout)
        gui = root.find(".//gui")
        if gui is not None:
            apikey = gui.findtext("apikey")
            return apikey
    except Exception as e:
        print(f"Error parsing config.xml: {e}", file=sys.stderr)
    return None

def run_curl(path, apikey, method="GET", data=None):
    cmd = [
        "docker", "exec", "mlx-syncthing",
        "curl", "-s", "-X", method,
        "-H", f"X-API-Key: {apikey}"
    ]
    if data:
        cmd.extend(["-H", "Content-Type: application/json", "-d", json.dumps(data)])
    cmd.append(f"http://localhost:8384{path}")
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.stdout

def main():
    print("Checking if Syncthing container is running...", flush=True)
    if not wait_for_syncthing():
        print("Syncthing container is not running or not healthy. Exiting.", file=sys.stderr)
        return 1

    # Wait a bit for the web service to start
    time.sleep(2)

    apikey = get_api_key()
    if not apikey:
        print("Failed to retrieve Syncthing API key from config.xml.", file=sys.stderr)
        return 1

    # Fetch system status to get myID
    status_output = run_curl("/rest/system/status", apikey)
    try:
        status_data = json.loads(status_output)
        my_id = status_data["myID"]
    except Exception as e:
        print(f"Failed to fetch system status or parse myID: {e}", file=sys.stderr)
        print(f"Raw output: {status_output}", file=sys.stderr)
        return 1

    # Fetch current config
    config_output = run_curl("/rest/system/config", apikey)
    try:
        config_data = json.loads(config_output)
    except Exception as e:
        print(f"Failed to fetch or parse Syncthing config: {e}", file=sys.stderr)
        return 1

    folders = config_data.get("folders", [])
    has_sync_folder = False
    for folder in folders:
        if folder.get("path") == "/var/syncthing/Sync":
            has_sync_folder = True
            print(f"Syncthing folder already exists for /var/syncthing/Sync (ID: {folder.get('id')}).", flush=True)
            break

    if not has_sync_folder:
        print("Configuring the 'hermes' sync folder for '/var/syncthing/Sync'...", flush=True)
        new_folder = {
            "id": "hermes",
            "label": "hermes",
            "filesystemType": "basic",
            "path": "/var/syncthing/Sync",
            "type": "sendreceive",
            "devices": [
                {
                    "deviceID": my_id,
                    "introducedBy": "",
                    "encryptionPassword": ""
                }
            ],
            "rescanIntervalS": 3600,
            "fsWatcherEnabled": True,
            "fsWatcherDelayS": 10,
            "fsWatcherTimeoutS": 0,
            "ignorePerms": False,
            "autoNormalize": True,
            "minDiskFree": {
                "value": 1,
                "unit": "%"
            },
            "versioning": {
                "type": "",
                "params": {},
                "cleanupIntervalS": 3600,
                "fsPath": "",
                "fsType": "basic"
            },
            "copiers": 0,
            "pullerMaxPendingKiB": 0,
            "hashers": 0,
            "order": "random",
            "ignoreDelete": False,
            "scanProgressIntervalS": 0,
            "pullerPauseS": 0,
            "pullerDelayS": 1,
            "maxConflicts": 10,
            "disableSparseFiles": False,
            "paused": False,
            "markerName": ".stfolder",
            "copyOwnershipFromParent": False,
            "modTimeWindowS": 0,
            "maxConcurrentWrites": 16,
            "disableFsync": False,
            "blockPullOrder": "standard",
            "copyRangeMethod": "standard",
            "caseSensitiveFS": False,
            "junctionsAsDirs": False,
            "syncOwnership": False,
            "sendOwnership": False,
            "syncXattrs": False,
            "sendXattrs": False,
            "blockIndexing": True
        }
        folders.append(new_folder)
        config_data["folders"] = folders

        # Send back the modified config
        post_res = run_curl("/rest/system/config", apikey, method="POST", data=config_data)
        print("Updated Syncthing configuration successfully.", flush=True)

        # Trigger restart to apply changes
        run_curl("/rest/system/restart", apikey, method="POST")
        print("Restarted Syncthing to apply new folder configuration.", flush=True)
    else:
        print("No changes required.", flush=True)

    return 0

if __name__ == "__main__":
    sys.exit(main())
