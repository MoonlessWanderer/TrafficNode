import re

from node import (
    build_body,
    choose_primary,
    cpu_fields,
    cpu_percent,
    load_config,
    main_interfaces,
    parse_meminfo,
    parse_net_dev,
    parse_os_release,
)


def test_meminfo_uses_kibibytes():
    text = "MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\n"
    total, used, free = parse_meminfo(text)
    assert total == 1000 * 1024
    assert free == 400 * 1024
    assert used == 600 * 1024


def test_net_dev_reads_counters():
    text = """Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 10 1 0 0 0 0 0 0 20 1 0 0 0 0 0 0
  eth0: 100 2 1 3 0 0 0 0 200 4 5 6 0 0 0 0
"""
    rows = parse_net_dev(text)
    assert [row["name"] for row in rows] == ["lo", "eth0"]
    eth = rows[1]
    assert eth["rx_bytes"] == 100
    assert eth["tx_bytes"] == 200
    assert eth["rx_errors"] == 1
    assert eth["rx_dropped"] == 3
    assert eth["tx_errors"] == 5
    assert eth["tx_dropped"] == 6


def test_main_interface_follows_the_default_route():
    interfaces = [
        {"name": "lo", "rx_bytes": 1, "tx_bytes": 1},
        {"name": "docker0", "rx_bytes": 9000, "tx_bytes": 9000},
        {"name": "veth123", "rx_bytes": 50, "tx_bytes": 50},
        {"name": "eth0", "rx_bytes": 100, "tx_bytes": 40},
        {"name": "eth1", "rx_bytes": 5, "tx_bytes": 5},
    ]
    route = (
        "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n"
        "docker0 00000000 00000000 0001 0 0 0 00000000 0 0 0\n"
        "eth0 00000000 0100000A 0003 0 0 100 00000000 0 0 0\n"
    )
    assert choose_primary(interfaces, route) == "eth0"
    chosen = main_interfaces(interfaces, route)
    assert [item["name"] for item in chosen] == ["eth0"]
    assert chosen[0]["primary"] is True


def test_main_interface_uses_the_busiest_physical_nic_without_a_route():
    interfaces = [
        {"name": "eth0", "rx_bytes": 10, "tx_bytes": 10},
        {"name": "eth1", "rx_bytes": 500, "tx_bytes": 20},
        {"name": "veth1", "rx_bytes": 9999, "tx_bytes": 9999},
    ]
    assert choose_primary(interfaces, "Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n") == "eth1"


def test_cpu_percent_is_busy_share():
    assert cpu_percent((100, 50), (200, 100)) == 50.0


def test_cpu_fields_do_not_count_guest_time_twice():
    text = "cpu 100 0 0 100 0 0 0 0 40 10\n"
    total, idle = cpu_fields(text)
    assert total == 200
    assert idle == 100


def test_os_release_prefers_pretty_name():
    text = 'NAME="Debian GNU/Linux"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n'
    assert parse_os_release(text) == "Debian GNU/Linux 12 (bookworm)"


def test_body_carries_a_matching_nonce():
    body, nonce = build_body(
        {
            "cpu_percent": 1,
            "ram_total_bytes": 1,
            "ram_used_bytes": 1,
            "ram_free_bytes": 0,
            "disk_total_bytes": 1,
            "disk_used_bytes": 0,
            "disk_free_bytes": 1,
            "load_1": 0,
            "load_5": 0,
            "load_15": 0,
            "uptime_seconds": 1,
            "os_name": "Debian",
            "kernel_version": "6.8.0",
            "interfaces": [{"name": "eth0", "rx_bytes": 1, "tx_bytes": 1, "rx_packets": 0, "tx_packets": 0, "rx_errors": 0, "tx_errors": 0, "rx_dropped": 0, "tx_dropped": 0}],
        }
    )
    assert body["nonce"] == nonce
    assert re.fullmatch(r"[A-Za-z0-9_-]{16,128}", nonce)
    assert body["agent_version"]
    assert body["collected_at"].endswith("Z")


def test_load_config_reads_quoted_values(tmp_path, monkeypatch):
    for key in ("PANEL_URL", "NODE_ID", "NODE_KEY", "INTERVAL", "VERIFY_TLS"):
        monkeypatch.delenv(key, raising=False)
    path = tmp_path / "node.env"
    path.write_text(
        'PANEL_URL="https://panel.example"\n'
        'NODE_ID="nd_0123456789abcdef"\n'
        'NODE_KEY="nk_abcdefghijklmnop"\n'
        'INTERVAL="30"\n'
        'VERIFY_TLS="1"\n',
        encoding="utf-8",
    )
    config = load_config(path)
    assert config["PANEL_URL"] == "https://panel.example"
    assert config["NODE_ID"] == "nd_0123456789abcdef"
    assert config["INTERVAL"] == "30"
    assert config["VERIFY_TLS"] == "1"
