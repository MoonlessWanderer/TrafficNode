#!/usr/bin/env python3
"""Report this server's resources and network counters to a Traffic Panel."""

from __future__ import annotations

import json
import os
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

VERSION = "1.0.0"
USER_AGENT = f"traffic-node/{VERSION}"


def config_path() -> Path:
    override = os.environ.get("NODE_CONFIG", "").strip()
    if override:
        return Path(override)
    return Path(__file__).resolve().parent / "node.env"


def load_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if path.is_file():
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    for key in ("PANEL_URL", "NODE_ID", "NODE_KEY", "INTERVAL", "VERIFY_TLS"):
        if os.environ.get(key, "").strip():
            values[key] = os.environ[key].strip()
    missing = [key for key in ("PANEL_URL", "NODE_ID", "NODE_KEY") if not values.get(key)]
    if missing:
        raise SystemExit("Missing " + ", ".join(missing) + f" in {path}")
    values["PANEL_URL"] = values["PANEL_URL"].rstrip("/")
    if not values["PANEL_URL"].startswith(("http://", "https://")):
        raise SystemExit("PANEL_URL must start with http:// or https://")
    try:
        interval = int(values.get("INTERVAL") or "30")
    except ValueError as exc:
        raise SystemExit("INTERVAL must be a whole number of seconds.") from exc
    if not 5 <= interval <= 3600:
        raise SystemExit("INTERVAL must be from 5 to 3600 seconds.")
    values["INTERVAL"] = str(interval)
    values["VERIFY_TLS"] = "0" if values.get("VERIFY_TLS", "1") in {"0", "false", "no"} else "1"
    return values


def parse_meminfo(text: str) -> tuple[int, int, int]:
    found: dict[str, int] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        name, raw = line.split(":", 1)
        parts = raw.split()
        if not parts:
            continue
        amount = int(parts[0])
        if len(parts) > 1 and parts[1] == "kB":
            amount *= 1024
        found[name] = amount
    total = found.get("MemTotal", 0)
    free = found.get("MemAvailable", found.get("MemFree", 0))
    used = max(0, total - free)
    return total, used, free


VIRTUAL_PREFIXES = (
    "docker",
    "veth",
    "br-",
    "virbr",
    "vnet",
    "dummy",
    "ifb",
    "kube",
    "flannel",
    "cali",
    "cni",
    "lxc",
    "podman",
    "vboxnet",
    "vmnet",
    "azv",
    "sit",
    "gre",
    "gretap",
    "erspan",
    "teql",
    "ip6tnl",
    "ip6_vti",
    "ip_vti",
)


def is_virtual_interface(name: str) -> bool:
    text = name.strip().lower()
    if not text or text == "lo":
        return True
    return any(text.startswith(prefix) for prefix in VIRTUAL_PREFIXES)


def choose_primary(interfaces: list[dict], route_text: str) -> str | None:
    usable = [
        item
        for item in interfaces
        if item.get("name") and not is_virtual_interface(item["name"]) and not any(char.isspace() for char in item["name"])
    ]
    if not usable:
        return None
    names = {item["name"] for item in usable}
    routes: list[tuple[int, str]] = []
    for line in route_text.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 7 or parts[1] != "00000000":
            continue
        try:
            metric = int(parts[6])
        except ValueError:
            continue
        routes.append((metric, parts[0]))
    for _metric, name in sorted(routes):
        if name in names:
            return name
    return max(usable, key=lambda item: item["rx_bytes"] + item["tx_bytes"])["name"]


def main_interfaces(interfaces: list[dict], route_text: str) -> list[dict]:
    primary = choose_primary(interfaces, route_text)
    if primary is None:
        return []
    chosen = []
    for item in interfaces:
        if item["name"] != primary:
            continue
        copy = dict(item)
        copy["primary"] = True
        chosen.append(copy)
    return chosen[:1]


def parse_net_dev(text: str) -> list[dict]:
    rows = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        name, raw = line.split(":", 1)
        name = name.strip()
        parts = raw.split()
        if len(parts) < 16 or not name:
            continue
        rows.append(
            {
                "name": name,
                "rx_bytes": int(parts[0]),
                "rx_packets": int(parts[1]),
                "rx_errors": int(parts[2]),
                "rx_dropped": int(parts[3]),
                "tx_bytes": int(parts[8]),
                "tx_packets": int(parts[9]),
                "tx_errors": int(parts[10]),
                "tx_dropped": int(parts[11]),
            }
        )
    return rows


def parse_os_release(text: str) -> str:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"')
    return values.get("PRETTY_NAME") or values.get("NAME") or "Linux"


def cpu_fields(text: str) -> tuple[int, int]:
    for line in text.splitlines():
        parts = line.split()
        if parts and parts[0] == "cpu":
            numbers = [int(item) for item in parts[1:]]
            # guest and guest_nice are already counted inside user and nice.
            if len(numbers) > 8:
                numbers = numbers[:8]
            idle = numbers[3] + (numbers[4] if len(numbers) > 4 else 0)
            return sum(numbers), idle
    raise ValueError("cpu line missing")


def cpu_percent(previous: tuple[int, int], current: tuple[int, int]) -> float:
    total = current[0] - previous[0]
    idle = current[1] - previous[1]
    if total <= 0:
        return 0.0
    return max(0.0, min(100.0, (1 - idle / total) * 100))


def read_cpu() -> tuple[int, int]:
    return cpu_fields(Path("/proc/stat").read_text(encoding="utf-8"))


def disk_bytes(path: str = "/") -> tuple[int, int, int]:
    stats = os.statvfs(path)
    total = stats.f_blocks * stats.f_frsize
    free = stats.f_bfree * stats.f_frsize
    return total, max(0, total - free), free


def load_average() -> tuple[float, float, float]:
    parts = Path("/proc/loadavg").read_text(encoding="utf-8").split()
    return float(parts[0]), float(parts[1]), float(parts[2])


def uptime_seconds() -> float:
    return float(Path("/proc/uptime").read_text(encoding="utf-8").split()[0])


def collect(previous_cpu: tuple[int, int] | None) -> tuple[dict, tuple[int, int]]:
    if previous_cpu is None:
        previous_cpu = read_cpu()
        time.sleep(0.2)
    current_cpu = read_cpu()
    total, used, free = parse_meminfo(Path("/proc/meminfo").read_text(encoding="utf-8"))
    disk_total, disk_used, disk_free = disk_bytes("/")
    load_1, load_5, load_15 = load_average()
    os_name = "Linux"
    os_release = Path("/etc/os-release")
    if os_release.is_file():
        os_name = parse_os_release(os_release.read_text(encoding="utf-8"))
    route_text = ""
    route_path = Path("/proc/net/route")
    if route_path.is_file():
        route_text = route_path.read_text(encoding="utf-8")
    interfaces = main_interfaces(parse_net_dev(Path("/proc/net/dev").read_text(encoding="utf-8")), route_text)
    sample = {
        "cpu_percent": round(cpu_percent(previous_cpu, current_cpu), 2),
        "ram_total_bytes": total,
        "ram_used_bytes": used,
        "ram_free_bytes": free,
        "disk_total_bytes": disk_total,
        "disk_used_bytes": disk_used,
        "disk_free_bytes": disk_free,
        "load_1": load_1,
        "load_5": load_5,
        "load_15": load_15,
        "uptime_seconds": uptime_seconds(),
        "os_name": os_name[:128],
        "kernel_version": os.uname().release[:128],
        "interfaces": interfaces,
    }
    return sample, current_cpu


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def build_body(sample: dict) -> tuple[dict, str]:
    nonce = secrets.token_urlsafe(18)
    body = {
        "nonce": nonce,
        "collected_at": stamp(),
        "agent_version": VERSION,
        **sample,
    }
    return body, nonce


def post_metrics(config: dict[str, str], body: dict, nonce: str) -> dict:
    payload = json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        config["PANEL_URL"] + "/api/v1/ingest/metrics",
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
            "X-Node-Id": config["NODE_ID"],
            "X-Node-Key": config["NODE_KEY"],
            "X-Node-Timestamp": str(int(time.time())),
            "X-Node-Nonce": nonce,
        },
    )
    context = None
    if config["PANEL_URL"].startswith("https://") and config["VERIFY_TLS"] == "0":
        context = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(request, timeout=20, context=context) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Panel rejected the report ({exc.code}): {error_text(detail)}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"Could not reach the panel: {exc.reason}") from exc
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit("The panel returned a response that was not JSON.") from exc
    if not parsed.get("ok"):
        error = parsed.get("error") or {}
        raise SystemExit(error.get("message") or "The panel rejected the report.")
    return parsed.get("data") or {}


def error_text(detail: str) -> str:
    try:
        parsed = json.loads(detail)
    except json.JSONDecodeError:
        text = detail.strip()
    else:
        error = parsed.get("error") if isinstance(parsed, dict) else None
        text = (error.get("message") if isinstance(error, dict) else None) or detail
    text = " ".join(str(text).split())
    return text[:300]


def report_once(config: dict[str, str], previous_cpu: tuple[int, int] | None) -> tuple[int, int]:
    sample, current_cpu = collect(previous_cpu)
    if not sample["interfaces"]:
        raise SystemExit("No main network interface was found.")
    body, nonce = build_body(sample)
    result = post_metrics(config, body, nonce)
    print(f"Report accepted. duplicate={str(bool(result.get('duplicate'))).lower()}", flush=True)
    return current_cpu


def main(argv: list[str]) -> int:
    once = "--once" in argv
    config = load_config(config_path())
    interval = int(config["INTERVAL"])
    previous = None
    while True:
        try:
            previous = report_once(config, previous)
        except SystemExit as exc:
            if once:
                print(exc, file=sys.stderr, flush=True)
                return 1
            print(exc, file=sys.stderr, flush=True)
        except Exception as exc:
            print(f"Report failed: {exc}", file=sys.stderr, flush=True)
            if once:
                return 1
        if once:
            return 0
        time.sleep(interval)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
