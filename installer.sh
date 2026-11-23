#!/usr/bin/env bash
# Install PhoenixCloud for the current user on Debian or Ubuntu.
set -euo pipefail

if ! command -v python3 >/dev/null || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
    echo 'PhoenixCloud needs Python 3.9 or newer. Install python3 on this host, then rerun.' >&2
    exit 1
fi

install_dir="$HOME/.local/bin"
mkdir -p -- "$install_dir"
temp_launcher=$(mktemp "$install_dir/.phoenixcloud.XXXXXXXX")
trap 'rm -f -- "$temp_launcher"' EXIT
cat > "$temp_launcher" <<'END_PHOENIX_MENU'
#!/usr/bin/env python3
"""PhoenixCloud • personal VM console for x86-64 Debian and Ubuntu hosts."""
import fcntl
import getpass
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess as sp
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(os.getenv("PHOENIX_DATA_DIR") or Path.home() / ".local/share/phoenixcloud").expanduser().resolve()
VMS = ROOT / "machines"
IMAGES = ROOT / "images"
PVE = "https://download.proxmox.com/iso/proxmox-ve_9.2-1.iso"
PVE_HASH = "4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c"
CLOUDFLARED_GH = ("https://github.com/cloudflare/cloudflared/releases/latest/download/"
                  "cloudflared-linux-amd64")
BLOCKED_ON_DAYTONA = ("download.proxmox.com", "pkg.cloudflare.com", "free.pinggy.io",
                      "argotunnel.com", "ngrok.com", "localhost.run", "serveo.net")
CATALOG = {
    "Ubuntu 22.04": "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
    "Ubuntu 24.04": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img",
    "Debian 12": "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2",
    "Debian 13": "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2",
    "Proxmox VE 9.2": PVE,
    "Local x86-64 installer ISO": None,
}
BANNER = [
    "████ █  █ ████ ████ █  █ ███ █   █",
    "█  █ █  █ █  █ █    ██ █  █   █ █ ",
    "████ ████ █  █ ███  █ ██  █    █  ",
    "█    █  █ █  █ █    █  █  █   █ █ ",
    "█    █  █ ████ ████ █  █ ███ █   █",
]
W = 78
LW = 34

DAYTONA = bool(os.environ.get("PHOENIX_DAYTONA") or os.environ.get("DAYTONA_SANDBOX_ID")
               or Path("/etc/daytona").exists())

def run(*args, **kw):
    return sp.run([str(a) for a in args], check=True, **kw)

def admin(*args):
    run(*([] if os.geteuid() == 0 else ["sudo"]), *args)

def as_admin(*args):
    return sp.run(([] if os.geteuid() == 0 else ["sudo"]) + [str(a) for a in args],
                  capture_output=True)

def number(label, default, low, high):
    while True:
        raw = input(f"{label} ({low}–{high}) [{default}] > ").strip()
        try:
            value = int(raw or default)
        except ValueError:
            value = None
        if value is not None and low <= value <= high:
            return value
        print(f"Enter a whole number from {low} to {high}, or press Enter for {default}.")

def has_kvm():
    return (platform.machine() in ("x86_64", "amd64")
            and os.access("/dev/kvm", os.R_OK | os.W_OK))

def reachable(host, port=443, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False

def host_ram_mb():
