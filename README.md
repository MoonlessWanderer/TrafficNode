# Traffic Node

Traffic Node reports this server's CPU, memory, disk, and network counters to a Traffic Panel. It has no web interface.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/MoonlessWanderer/TrafficNode/main/install.sh | sudo -E bash
```

Run that command again whenever you need the node. The menu is where you install, connect to the panel, update, start, stop, restart, read logs, check status, change the interval, and uninstall.

Install asks for a directory after the packages. The default is `traffic-node` in the current directory, usually `/root/traffic-node`.

Connect asks for the panel address, the node id, and the node key. Create the node in the panel first. The panel shows a command that installs this node and connects it. The key stays in `node.env` on this server. Until the panel has a certificate, the address starts with `http://`, for example `http://203.0.113.10:443`.

Update keeps that connection. Uninstall removes the service, the files, and the key.

A proxy already set in the shell, `/etc/environment`, or apt is used for the download. The command above keeps those variables with `sudo -E`.
