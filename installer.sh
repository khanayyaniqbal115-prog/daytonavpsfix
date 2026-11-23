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
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) // 1024
    except OSError:
        pass
    return 0

def cpu_percent():
    def snap():
        vals = [int(v) for v in Path("/proc/stat").read_text().splitlines()[0].split()[1:]]
        return sum(vals), vals[3] + vals[4]
    try:
        t1, i1 = snap()
        time.sleep(0.15)
        t2, i2 = snap()
    except (OSError, IndexError):
        return 0
    return int(100 * ((t2 - t1) - (i2 - i1)) / (t2 - t1)) if t2 > t1 else 0

def ram_percent():
    try:
        info = {l.split(":")[0]: int(l.split()[1])
                for l in Path("/proc/meminfo").read_text().splitlines() if l.split()[1].isdigit()}
        return int(100 * (info["MemTotal"] - info["MemAvailable"]) / info["MemTotal"])
    except (OSError, KeyError, ValueError, IndexError):
        return 0

def uptime():
    try:
        secs = int(float(Path("/proc/uptime").read_text().split()[0]))
    except (OSError, ValueError):
        return "?"
    return f"{secs//86400}d {secs%86400//3600}h {secs%3600//60}m"

def dependencies():
    admin("apt-get", "update")
    admin("apt-get", "install", "-y", "--no-install-recommends", "qemu-system-x86", "qemu-utils",
          "cloud-image-utils", "openssh-client", "curl", "ca-certificates", "tmux", "novnc",
          "websockify", "ttyd")

def download(url, dest):
    run("curl", "--fail", "--show-error", "--location", "--proto", "=https",
        "--proto-redir", "=https", "--retry", "2", "--connect-timeout", "15", "-o", dest, url)

def blocked_hint(url):
    if not DAYTONA or not url:
        return
    for host in BLOCKED_ON_DAYTONA:
        if host in url:
            print(f"Note: {host} is not on Daytona's free-tier egress allow list.")
            print("      If this hangs or 403s, upload the file into the sandbox and pick")
            print("      'Local x86-64 installer ISO' instead of a download entry.")
            return

def media(url):
    if not url:
        path = Path(input("Full path to installer ISO on this host > ").strip()).expanduser().resolve()
        if not path.is_file() or path.suffix.lower() != ".iso":
            raise ValueError("Choose an existing .iso file.")
        return path
    dest = IMAGES / url.rsplit("/", 1)[1]
    if dest.exists():
        return dest
    blocked_hint(url)
    with tempfile.TemporaryDirectory(dir=IMAGES) as tmp:
        part = Path(tmp) / "image"
        try:
            download(url, part)
        except sp.CalledProcessError:
            raise ValueError(f"Download failed: {url}\nEgress is filtered here. Upload the ISO "
                             "with the Daytona UI/CLI, then choose the local ISO entry.")
        if url == PVE:
            expected = PVE_HASH
        else:
            sums = Path(tmp) / "checksums"
            manifest = "SHA512SUMS" if "debian.org" in url else "SHA256SUMS"
            download(url.rsplit("/", 1)[0] + "/" + manifest, sums)
            expected = next((line.split()[0] for line in sums.read_text().splitlines()
                             if len(line.split()) == 2 and line.split()[1].lstrip("*").removeprefix("./") == dest.name), "")
        if len(expected) not in (64, 128):
            raise ValueError("No matching publisher checksum.")
        digest = hashlib.new("sha256" if len(expected) == 64 else "sha512")
        with part.open("rb") as src:
            for block in iter(lambda: src.read(2**20), b""):
                digest.update(block)
        if digest.hexdigest() != expected.lower():
            raise ValueError("Image checksum mismatch. Retry the download.")
        part.rename(dest)
    return dest

def load(vm):
    return json.loads((vm / "settings.json").read_text())

def machines():
    return sorted(p.parent for p in VMS.glob("*/settings.json"))

def live(vm):
    with socket.socket(socket.AF_UNIX) as s:
        try:
            s.settimeout(1)
            s.connect(str(vm / "control"))
            return True
        except (FileNotFoundError, ConnectionRefusedError):
            return False

def details(vm):
    c = load(vm)
    state = "running" if live(vm) else "stopped"
    print(f"{vm.name}  |  {c['os']}  |  {state}  |  {c['ram']//1024} GB / {c['cpu']} vCPU")
    print(f"  SSH: ssh -p {c['ssh']} {c['user']}@127.0.0.1   VNC viewer: 127.0.0.1::{c['vnc']}")
    if c['os'].startswith("Proxmox"):
        print(f"  After installation: https://127.0.0.1:{c['web']}  |  guest IP 10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3")
        print("  Guest shell: sed -i 's/^deb /#deb /' /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list")
    if c['user'] == 'phoenix':
        print(f"  SSH identity: add -i {ROOT / 'guest-key'}")

def boot(vm, installer=False):
    if live(vm):
        raise ValueError("Already running. Shut the guest down before changing boot mode.")
    c = load(vm)
    kvm = has_kvm()
    if not kvm:
        print("No /dev/kvm here — falling back to software emulation (TCG). Expect it to be slow,")
        print("and keep guest RAM at or under roughly half of this host's free memory.")
        if c["os"].startswith("Proxmox"):
            print("Proxmox on TCG: budget an hour or more for the installer alone.")
    net = f"user,id=n,hostfwd=tcp:127.0.0.1:{c['ssh']}-:22"
    if c["os"].startswith("Proxmox"):
        net += f",hostfwd=tcp:127.0.0.1:{c['web']}-:8006"
    args = ["qemu-system-x86_64", "-name", vm.name,
            "-accel", "kvm" if kvm else "tcg,thread=multi",
            "-cpu", "host" if kvm else "max", "-smp", c["cpu"], "-m", c["ram"],
            "-drive", "file=disk.qcow2,if=virtio,format=qcow2", "-netdev", net, "-device", "virtio-net-pci,netdev=n",
            "-monitor", "unix:control,server=on,wait=off", "-vnc", f"127.0.0.1:{c['vnc']-5900}",
            "-serial", "file:boot.log", "-daemonize"]
    if installer:
        if not c["iso"]:
            raise ValueError("Cloud image already installed. Use Start.")
        args += ["-cdrom", c["iso"], "-boot", "once=d"]
    elif (vm / "seed.iso").exists():
        args += ["-cdrom", "seed.iso"]
    run(*args, cwd=vm)
    details(vm)

def build(name, label, ram, cpu, size, src=None):
    if not re.fullmatch("[a-z][a-z0-9-]{0,30}", name):
        raise ValueError("Use 1–31 lowercase letters, numbers or hyphens. Start with a letter.")
    vm = VMS / name
    if vm.exists():
        raise ValueError("Name already in use.")
    iso = label.startswith(("Proxmox", "Local"))
    if size > disk_capacity(label, local_iso=src is not None):
        raise ValueError(f"Insufficient disk space in {ROOT} for a {size} GiB disk.")
    total = host_ram_mb()
    if total and ram > total * 0.85:
        print(f"Heads up: {ram//1024} GB guest RAM on a {total//1024} GB host will swap. "
              "Drop it if the boot stalls.")
    used = {load(v)["slot"] for v in machines()}
    slot = next(i for i in range(1000) if i not in used) if len(used)<1000 else None
    if slot is None:
        raise ValueError("No available port slots.")
    if src is None:
        src = media(CATALOG[label])
    c = dict(os=label, cpu=cpu, ram=ram, slot=slot, ssh=22000+slot, web=18000+slot,
             vnc=5900+slot, iso=str(src) if iso else "", user="root" if label.startswith("Proxmox") else ("LOGIN" if iso else "phoenix"))
    with tempfile.TemporaryDirectory(dir=ROOT) as temp:
        stage = Path(temp) / name
        stage.mkdir()
        disk = stage / "disk.qcow2"
        if iso:
            run("qemu-img", "create", "-f", "qcow2", disk, f"{size}G")
        else:
            key = ROOT / "guest-key"
            if not key.exists():
                run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key)
            pub = run("ssh-keygen", "-y", "-f", key, capture_output=True, text=True).stdout.strip()
            run("qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", src, disk)
            run("qemu-img", "resize", disk, f"{size}G")
            cfg = {"users":[{"name":"phoenix","shell":"/bin/bash","sudo":"ALL=(ALL) NOPASSWD:ALL",
                             "ssh_authorized_keys":[pub]}], "ssh_pwauth":False}
            (stage / "user-data").write_text("#cloud-config\n" + json.dumps(cfg))
            (stage / "meta-data").write_text(f"instance-id: {name}\nlocal-hostname: {name}\n")
            run("cloud-localds", "seed.iso", "user-data", "meta-data", cwd=stage)
        (stage / "settings.json").write_text(json.dumps(c))
        stage.rename(vm)
    boot(vm, installer=iso)

def space_text(amount):
    if amount >= 2**30:
        return f"{amount / 2**30:.2f} GiB"
    return f"{amount / 2**20:.1f} MiB"

def disk_capacity(label, local_iso=False):
    free = shutil.disk_usage(ROOT).free
    url = CATALOG[label]
    reserve = 0
    if url and not local_iso and not (IMAGES / url.rsplit("/", 1)[-1]).is_file():
        reserve = 2 * 2**30
    available = (free - reserve) // 2**30
    if available < 4:
        raise ValueError(f"{ROOT}: {space_text(free)} free. Need at least "
                         f"{space_text(4 * 2**30 + reserve)} here for this setup. "
                         "Use a larger volume or free space before creating the VM.")
    return available

def ram_limit():
    # Host MemAvailable can exceed the sandbox's own memory allowance.
    available = next((int(row.split()[1]) * 1024 for row in
                      Path("/proc/meminfo").read_text().splitlines() if row.startswith("MemAvailable:")), 0)
    for limit_file, usage_file in [("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory.current"),
                                   ("/sys/fs/cgroup/memory/memory.limit_in_bytes",
                                    "/sys/fs/cgroup/memory/memory.usage_in_bytes")]:
        try:
            remaining = int(Path(limit_file).read_text()) - int(Path(usage_file).read_text())
            available = min(available, remaining)
        except (OSError, ValueError):
            continue
    return max(0, (available - 256 * 2**20) // 2**30)

def choose_ram(minimum):
    available = ram_limit()
    default = max(minimum, min(8, available))
    while True:
        raw = input(f"Custom VM RAM in GiB (minimum {minimum}, Enter = {default}) > ").strip()
        try:
            amount = int(raw or default)
        except ValueError:
            amount = 0
        if amount < minimum:
            print(f"Enter a whole number of at least {minimum} GiB.")
            continue
        if amount > available:
            print(f"Requested {amount} GiB. Estimated available guest memory: {available} GiB.")
            print("Starting this VM may fail or exhaust the host's memory.")
            if input("Keep this RAM setting? [y/N] > ").strip().lower() not in ("y", "yes"):
                continue
        return amount

def specs(label, local_iso=False):
    ram_gb = choose_ram(2 if label.startswith("Proxmox") else 1)
    disk_max = min(disk_capacity(label, local_iso), 65536)
    cpu = number("vCPUs", 4, 1, 4 if DAYTONA else 256)
    preferred = 8 if label.startswith(("Proxmox", "Local")) else 10
    disk_gb = number("Disk in GiB", min(preferred, disk_max), 4, disk_max)
    return ram_gb * 1024, cpu, disk_gb

def finish(vm, iso):
    """Publish something usable right away: installer console, or a web shell."""
    if iso:
        publish(vm, console_port(vm), "installer console")
    else:
        shell_url(vm)

def pick_os(default=2):
    for i, label in enumerate(CATALOG, 1):
        print(f"  {i}  {label}")
    return list(CATALOG)[number("OS", default, 1, len(CATALOG))-1]

def create():
    name = input("Machine name > ").strip()
    label = pick_os()
    iso = label.startswith(("Proxmox", "Local"))
    ram, cpu, size = specs(label)
    build(name, label, ram, cpu, size)
    finish(VMS / name, iso)

def quick():
    """Same as Create, then a public URL without extra steps."""
    print("Quick machine — Enter accepts every default, then you get a public URL.")
    name = input("Machine name > ").strip()
    label = pick_os()
    iso = label.startswith(("Proxmox", "Local"))
    ram, cpu, size = specs(label)
    build(name, label, ram, cpu, size)
    vm = VMS / name
    finish(vm, iso)
    if label.startswith("Proxmox"):
        print("\nInstall with: ext4, hostname pve.local, IP 10.0.2.15/24,")
        print("gateway 10.0.2.2, DNS 10.0.2.3. No network needed.")
        print("After the reboot: menu 2 → s, the web UI URL prints itself.")

def create_proxmox():
    """Proxmox preset: local ISO only, small disk, public console on boot."""
    print("Proxmox VE preset — offline ISO install, no egress needed.")
    print("Enter accepts every default.")
    name = input("Machine name > ").strip()
    label = "Proxmox VE 9.2"
    ram, cpu, size = specs(label, local_iso=True)
    src = media(None)
    build(name, label, ram, cpu, size, src=src)
    vm = VMS / name
    publish(vm, console_port(vm), "installer console")
    print("\nInstall with: ext4, hostname pve.local, IP 10.0.2.15/24,")
    print("gateway 10.0.2.2, DNS 10.0.2.3. No network needed.")
    print("After the reboot: menu 2 → s, the web UI URL prints itself.")

def console_port(vm):
    """Ensure the browser console is bridged to a loopback HTTP port and return it."""
    c = load(vm)
    port = 16000 + c["slot"]
    session = f"phoenix-console-{vm.name}"
    if sp.run(["tmux","has-session","-t","="+session],capture_output=True).returncode:
        run("tmux","new-session","-d","-s",session,"websockify","--web=/usr/share/novnc",
            f"127.0.0.1:{port}", f"127.0.0.1:{c['vnc']}")
    return port

def shell_url(vm):
    """Wait for guest SSH, then serve a browser terminal to it."""
    c = load(vm)
    print("Waiting for guest SSH…")
    end = time.time() + 180
    while time.time() < end:
        if reachable("127.0.0.1", c["ssh"], 2):
            break
        time.sleep(2)
    else:
        print("SSH never came up; publishing the console instead.")
        publish(vm, console_port(vm), "console")
        return
    exe = shutil.which("ttyd")
    if not exe:
        print("ttyd is missing — run menu 7. Publishing the console instead.")
        publish(vm, console_port(vm), "console")
        return
    port = 17000 + c["slot"]
    session = f"phoenix-shell-{vm.name}"
    if sp.run(["tmux","has-session","-t","="+session],capture_output=True).returncode:
        run("tmux","new-session","-d","-s",session,exe,"-p",port,"-W",
            "ssh","-o","StrictHostKeyChecking=no","-o","UserKnownHostsFile=/dev/null",
            "-o","LogLevel=ERROR","-i",ROOT/"guest-key","-p",c["ssh"],"phoenix@127.0.0.1")
    publish(vm, port, "web shell")
    print(f"Local shell: http://127.0.0.1:{port}/   (host SSH: ssh -i '{ROOT / 'guest-key'}' -p {c['ssh']} phoenix@127.0.0.1)")

def manage():
    choices = machines()
    for i, vm in enumerate(choices, 1):
        print(i, end="  ")
        details(vm)
    if not choices:
        print("No machines yet.")
        return
    idx = number("Machine (0 returns)", 0, 0, len(choices))
    if not idx:
        return
    vm = choices[idx-1]
    action = input("[s] Start   [i] Boot installer   [v] Console   [w] Web shell   [p] Shutdown   [Enter] Back > ").lower()
    if action in ("s", "i"):
        boot(vm, action == "i")
        if action == "s":
            if load(vm)["os"].startswith("Proxmox"):
                publish(vm, load(vm)["web"], "Proxmox web UI")
            else:
                shell_url(vm)
    elif action == "v":
        if not live(vm):
            raise ValueError("Start this machine first.")
        port = console_port(vm)
        print(f"Local URL: http://127.0.0.1:{port}/vnc.html")
        print("Public URL: menu 5." if DAYTONA else
              f"  ssh -N -L {port}:127.0.0.1:{port} USER@HOST")
    elif action == "w" and not load(vm)["os"].startswith(("Proxmox", "Local")):
        if not live(vm):
            raise ValueError("Start this machine first.")
        shell_url(vm)
    elif action == "p" and live(vm):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect(str(vm / "control"))
            sock.sendall(b"system_powerdown\n")
        print("Shutdown requested. The guest handles ACPI shutdown.")

def network():
    for host, port in [("cloud-images.ubuntu.com",443), ("cloud.debian.org",443),
                       ("download.proxmox.com",443), ("github.com",443),
                       ("pkg.cloudflare.com",443), ("free.pinggy.io",443),
                       ("region1.v2.argotunnel.com",7844), ("app.daytona.io",443)]:
        print(f"{host}:{port}   {'TCP reachable' if reachable(host, port) else 'blocked'}"
              + ("  [blocked on free tier]" if DAYTONA and any(h in host for h in BLOCKED_ON_DAYTONA) else ""))
    print("TCP tests only. Tunnel registration appears in the connector logs.")

def install_cloudflared():
    if shutil.which("cloudflared"):
        return shutil.which("cloudflared")
    try:
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "cloudflare-main.gpg"
            download("https://pkg.cloudflare.com/cloudflare-main.gpg", key)
            admin("install", "-D", "-m", "0644", key, "/usr/share/keyrings/phoenix-cloudflare.gpg")
            source = Path(tmp) / "cloudflare.list"
            source.write_text("deb [signed-by=/usr/share/keyrings/phoenix-cloudflare.gpg] https://pkg.cloudflare.com/cloudflared any main\n")
            existing = any("https://pkg.cloudflare.com/cloudflared" in f.read_text()
                           for f in Path("/etc/apt/sources.list.d").glob("*") if f.suffix in (".list", ".sources"))
            if not existing:
                admin("install", "-m", "0644", source, "/etc/apt/sources.list.d/phoenix-cloudflare.list")
            admin("apt-get", "update")
            admin("apt-get", "install", "-y", "cloudflared")
        return shutil.which("cloudflared") or ""
    except (sp.CalledProcessError, OSError) as exc:
        print("apt route failed, using the GitHub release binary:", exc)
    dest = ROOT / "bin/cloudflared"
    dest.parent.mkdir(parents=True, exist_ok=True)
    download(CLOUDFLARED_GH, dest)
    dest.chmod(0o755)
    return str(dest)

def cloudflared_exe():
    return shutil.which("cloudflared") or (str(ROOT / "bin/cloudflared")
                                           if (ROOT / "bin/cloudflared").is_file() else "")

def wait_for_url(logfile, needle, timeout=25):
    end = time.time() + timeout
    while time.time() < end:
        if logfile.exists():
            found = re.search(r"https://[A-Za-z0-9.\-]+", logfile.read_text(errors="ignore"))
            if found and needle in found.group(0):
                return found.group(0)
        time.sleep(1)
    return ""

def signed_preview(port):
    sid = os.environ.get("DAYTONA_SANDBOX_ID", "").strip() or input("Sandbox ID > ").strip()
    if not sid:
        raise ValueError("Need the sandbox ID (daytona-v0 list shows it).")
    key = os.environ.get("DAYTONA_API_KEY", "").strip()
    if not key:
        raise ValueError("Set DAYTONA_API_KEY (app.daytona.io → API keys).")
    base = os.environ.get("DAYTONA_API_URL", "https://app.daytona.io/api").rstrip("/")
    req = urllib.request.Request(
        f"{base}/sandbox/{urllib.parse.quote(sid)}/ports/{port}/signed-preview-url?expiresInSeconds=86400",
        method="POST", headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        url = json.loads(resp.read().decode() or "{}").get("url", "")
    if not url:
        raise ValueError("No preview URL returned.")
    return url

def publish(vm, port, label):
    """Expose a loopback port. Cloudflare quick tunnel first, preview proxy as fallback."""
    if not DAYTONA:
        print(f"Local {label}: http://127.0.0.1:{port}/")
        print(f"  ssh -N -L {port}:127.0.0.1:{port} USER@HOST")
        return ""
    if reachable("region1.v2.argotunnel.com", 7844):
        exe = cloudflared_exe()
        if not exe:
            try:
                exe = install_cloudflared()
            except (sp.CalledProcessError, OSError):
                exe = ""
        if exe:
            log = ROOT / f"quick-{vm.name}-{port}.log"
            session = f"phoenix-quick-{vm.name}-{port}"
            sp.run(["tmux", "kill-session", "-t", "=" + session], capture_output=True)
            run("tmux", "new-session", "-d", "-s", session, exe, "tunnel", "--no-autoupdate",
                "--protocol", "http2", "--logfile", log, "--url", f"http://127.0.0.1:{port}")
            url = wait_for_url(log, "trycloudflare.com")
            if url:
                print(f"Public {label}: {url}")
                return url
            print("Tunnel did not register, using a preview URL instead.")
    else:
        print("argotunnel.com unreachable, using a preview URL instead.")
    url = signed_preview(port)
    print(f"Public {label}: {url}{'vnc.html' if label.startswith('installer') else ''}")
    print("Signed link, 24h. Daytona shows a one-click warning page first.")
    return url

def tunnel():
    choice = input("[1] Install connector   [2] Connect with token   [3] Quick tunnel   [4] View logs   [5] Stop > ").strip()
    if choice == "1":
        print("Installed at:", install_cloudflared() or "already present")
        return
    session = "phoenix-tunnel"
    if choice == "2":
        exe = cloudflared_exe()
        if not exe:
            raise ValueError("Install the connector first.")
        if sp.run(["tmux","has-session","-t","="+session],capture_output=True).returncode == 0:
            raise ValueError("Connector session already running. Check logs.")
        token = getpass.getpass("Paste only the Cloudflare tunnel token (hidden) > ").strip()
        if not token or any(ch.isspace() for ch in token):
            raise ValueError("Paste the token from the Cloudflare connector setup screen.")
        path = ROOT / "connector.token"
        path.write_text(token)
        run("tmux", "new-session", "-d", "-s", session, exe, "tunnel", "--logfile",
            ROOT / "tunnel.log", "run", "--token-file", path)
        print("Set the published hostname and origin in your Cloudflare dashboard. Protect admin routes with Access.")
        print("Connector launched. Check option 4 for a registered tunnel connection.")
    elif choice == "3":
        running = [vm for vm in machines() if live(vm)]
        if not running:
            raise ValueError("Start a machine first.")
        for i, vm in enumerate(running, 1):
            print(i, vm.name)
        sel = number("Quick tunnel for which machine? (0 returns)", 0, 0, len(running))
        if sel:
            vm = running[sel - 1]
            publish(vm, console_port(vm), "installer console")
    elif choice == "4":
        path = ROOT / "tunnel.log"
        print(path.read_text()[-2000:] if path.exists() else "No connector log yet.")
    elif choice == "5":
        sp.run(["tmux", "kill-session", "-t", "="+session], capture_output=True)
        for vm in machines():
            for suffix in (f"-{16000 + load(vm)['slot']}", f"-{17000 + load(vm)['slot']}",
                           f"-{load(vm)['web']}"):
                sp.run(["tmux", "kill-session", "-t", "="+f"phoenix-quick-{vm.name}{suffix}"],
                       capture_output=True)
            sp.run(["tmux", "kill-session", "-t", "="+f"phoenix-shell-{vm.name}"], capture_output=True)
        print("Stopped.")

def expose():
    """Public URL for a console, a web shell, or the Proxmox web UI."""
    running = [vm for vm in machines() if live(vm)]
    if not running:
        print("Start a machine in Manage machines first.")
        return
    for i, vm in enumerate(running, 1):
        print(f"{i}  {vm.name}")
    sel = number("Expose which machine? (0 returns)", 0, 0, len(running))
    if not sel:
        return
    vm = running[sel - 1]
    c = load(vm)
    targets = [("installer console", console_port(vm))]
    if not c["os"].startswith(("Proxmox", "Local")):
        targets.append(("web shell", 17000 + c["slot"]))
    if c["os"].startswith("Proxmox"):
        targets.append(("Proxmox web UI", c["web"]))
    for i, (label, _) in enumerate(targets, 1):
        print(i, label)
    pick = number("Target", 1, 1, len(targets))
    publish(vm, targets[pick-1][1], targets[pick-1][0])

def reload_nginx():
    for cmd in (["systemctl", "reload", "nginx"], ["service", "nginx", "reload"]):
        if as_admin(*cmd).returncode == 0:
            return True
    return False

def ssl_panel():
    """nginx reverse proxy + Let's Encrypt, driven from one screen."""
    print("SSL Panel — nginx in front of a local port, then certbot for the certificate.")
    print("Needs a domain that resolves to this host with 80/443 reachable.")
    if DAYTONA:
        print("On a sandbox: point the domain at your tunnel first, otherwise HTTP-01 fails.")
    admin("apt-get", "update")
    admin("apt-get", "install", "-y", "--no-install-recommends", "nginx", "certbot",
          "python3-certbot-nginx")
    domain = input("Domain (example.com) > ").strip().lower()
    if not re.fullmatch(r"[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}", domain):
        raise ValueError("Enter a bare domain, no scheme or path.")
    target = number("Local port to proxy", 80, 1, 65535)
    site = (
        "server {\n"
        "    listen 80;\n"
        f"    server_name {domain};\n"
        "    client_max_body_size 0;\n"
        "    location / {\n"
        f"        proxy_pass http://127.0.0.1:{target};\n"
        "        proxy_http_version 1.1;\n"
        '        proxy_set_header Upgrade $http_upgrade;\n'
        '        proxy_set_header Connection "upgrade";\n'
        "        proxy_set_header Host $http_host;\n"
        "        proxy_set_header X-Real-IP $remote_addr;\n"
        "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
        "        proxy_read_timeout 3600s;\n"
        "        proxy_buffering off;\n"
        "    }\n"
        "}\n"
    )
    with tempfile.TemporaryDirectory() as tmp:
        staged = Path(tmp) / "site"
        staged.write_text(site)
        admin("install", "-m", "0644", staged, f"/etc/nginx/sites-available/{domain}")
    admin("ln", "-sfn", f"/etc/nginx/sites-available/{domain}", f"/etc/nginx/sites-enabled/{domain}")
    admin("nginx", "-t")
    print("Reload nginx:", "ok" if reload_nginx() else "failed — reload it by hand")
    email = input("Email for Let's Encrypt (blank skips the certificate) > ").strip()
    if not email:
        print(f"Proxy live on http://{domain} → 127.0.0.1:{target}. Run certbot later.")
        return
    print(f"Requesting a certificate for {domain}…")
    result = as_admin("certbot", "--nginx", "-d", domain, "-m", email, "--agree-tos",
                      "--redirect", "-n", "--keep-until-expiring")
    print((result.stdout + result.stderr).decode(errors="ignore").strip()[-1200:] or "done")
    print(f"Certificate state: sudo certbot certificates -d {domain}")

def pinggy():
    running = [vm for vm in machines() if live(vm)]
    if not running:
        print("Start a VM in Manage machines first.")
        return
    for i, vm in enumerate(running, 1):
        print(f"{i}  {vm.name}")
    selected = number("Share SSH for which VM? (0 returns)", 0, 0, len(running))
    if selected == 0:
        return
    vm = running[selected - 1]
    cfg = load(vm)
    if DAYTONA:
        print("free.pinggy.io is not allowlisted on the free tier; it will only work on Tier 3+.")
    print(f"Sharing SSH for {vm.name}. Keep this terminal open. Ctrl+C closes the tunnel.")
    print(f"On your laptop: ssh -p PUBLIC_PORT {cfg['user']}@PUBLIC_HOST")
    if cfg["user"] == "phoenix":
        print("Use a key authorized inside the VM. To add your laptop's public key,")
        print(f"run on the host: ssh -i '{ROOT / 'guest-key'}' -p {cfg['ssh']} phoenix@127.0.0.1")
        print("Then add your laptop's .pub line to ~/.ssh/authorized_keys inside the VM.")
    run("ssh", "-F", "/dev/null", "-p", "443", "-o", "ExitOnForwardFailure=yes",
        "-o", "ConnectTimeout=12", "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3", "-o", "IdentityAgent=none",
        "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=0",
        "-R", f"0:127.0.0.1:{cfg['ssh']}", "tcp@free.pinggy.io")

def pad(text):
    return text + " " * max(0, W - 6 - len(text))

def line(text="", code=""):
    body = pad(text)
    if code:
        body = f"\033[{code}m{body}\033[0m"
    print("\033[38;5;245m  │\033[0m " + body + " \033[38;5;245m│\033[0m")

def rule(label=""):
    if label:
        print(f"\033[38;5;245m  ├─\033[0m \033[1m{label}\033[0m "
              + "\033[38;5;240m" + "─" * max(0, W - 9 - len(label)) + "\033[0m")
    else:
        print("\033[38;5;245m  ├" + "─" * (W - 4) + "\033[0m")

def two_col(left="", right=""):
    line(left.ljust(LW) + right)

def banner():
    print("\n\033[38;5;245m  ╭" + "─" * (W - 4) + "╮\033[0m")
    line(f"{getpass.getuser()}@{socket.gethostname()}", "245")
    line("")
    for row, code in zip(BANNER, ("96", "96", "95", "93", "93")):
        line(row, code)
    line("")
    line("NOBITA EDITION — OBSIDIAN NEXT GEN", "245")
    print("\033[38;5;245m  ╰" + "─" * (W - 4) + "╯\033[0m")
    net = "\033[92m● CONNECTED\033[0m" if reachable("cloudflare.com") else "\033[91m● FILTERED\033[0m"
    print(f"\033[38;5;245m  {socket.gethostname()}   {uptime()}   "
          f"CPU {cpu_percent()}%   RAM {ram_percent()}%   Network {net}"
          f"{'   KVM yes' if has_kvm() else '   KVM no (TCG)'}\033[0m")
    print(f"\033[38;5;245m  {len(machines())} machines   "
          f"{space_text(shutil.disk_usage(ROOT).free)} free"
          f"{'   Daytona sandbox' if DAYTONA else ''}\033[0m")

def menu():
    banner()
    rule("DEPLOYMENT & SERVICES")
    two_col("  ├ [1] VPS", "  ├ [5] Themes")
    two_col("  ├ [2] Panel", "  ├ [6] System")
    two_col("  ├ [3] Wings", "  ├ [7] Container")
    line("  └ [8] New Module")
    line("")
    rule("MAINTENANCE & TOOLS")
    two_col("  ├ [4] Cloudflare", "  ├ [9] SSL Panel")
    line("")
    line("                    [0] SHUTDOWN SYSTEM", "91")
    print("\n\033[1m  → Enter Option (0-9):\033[0m ", end="", flush=True)

def main():
    os.umask(0o077)
    for directory in (ROOT, VMS, IMAGES):
        directory.mkdir(parents=True, exist_ok=True)
    with (ROOT / "console.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        while True:
            menu()
            try:
                choice = input().strip()
                if choice == "0":
                    print("\n  System left running. Bye.")
                    break
                action = {"1":create, "2":manage, "3":quick, "4":tunnel, "5":expose,
                          "6":network, "7":dependencies, "8":create_proxmox,
                          "9":ssl_panel}.get(choice)
                if action:
                    print()
                    action()
            except (ValueError, OSError, sp.CalledProcessError) as exc:
                print("\n  Action stopped:", exc)
            except KeyboardInterrupt:
                print("\n  Cancelled.")
if __name__ == "__main__":
    try:
        main()
    except (EOFError, KeyboardInterrupt):
        print()
    except BlockingIOError:
        sys.exit("Another PhoenixCloud console is open for this user.")
END_PHOENIX_MENU
python3 -c 'import pathlib, sys; p = pathlib.Path(sys.argv[1]); compile(p.read_bytes(), str(p), "exec")' "$temp_launcher"
chmod 755 "$temp_launcher"
mv -fT -- "$temp_launcher" "$install_dir/phoenixcloud"
echo "Installed. Open the menu anytime with: ~/.local/bin/phoenixcloud"
if [[ -t 0 ]]; then
    exec "$install_dir/phoenixcloud"
fi
