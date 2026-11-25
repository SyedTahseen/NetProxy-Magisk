# NetProxy

Transparent proxy for rooted Android, powered by [Xray-core](https://github.com/XTLS/Xray-core).

![Version](https://img.shields.io/badge/version-v6.1.1-blue)
![Platform](https://img.shields.io/badge/platform-Android%20arm64-3DDC84?logo=android&logoColor=white)
![Root](https://img.shields.io/badge/root-Magisk%20%7C%20KernelSU%20%7C%20APatch-orange)
![Core](https://img.shields.io/badge/core-Xray-informational)
![Shell](https://img.shields.io/badge/made%20with-shell-89e051?logo=gnubash&logoColor=white)

## Features

- System-wide proxy with TPROXY (automatic REDIRECT fallback)
- Per-app proxy: blacklist, whitelist or off
- Instant node switching, with old connections closed so apps reconnect on the new node
- Import nodes from links, subscriptions and WireGuard configs
- Routing modes: rule, global, direct
- WebUI and command-line tool
- Optional IPv6, CN IP bypass, QUIC and DoT blocking

## Requirements

- Android 8+ (arm64) with Magisk, KernelSU or APatch
- A kernel with TPROXY support is recommended (TCP-only REDIRECT is used otherwise)

## Install

1. Download the latest zip from [Releases](../../releases).
2. Flash it in Magisk, KernelSU or APatch.
3. Reboot.
4. Open the WebUI from your root manager and add a node.

## Usage

Press the module's **Action** button to start or stop the proxy.

Command line:

```sh
su -c "/data/adb/modules/netproxy/scripts/cli <command>"
```

| Command | What it does |
| --- | --- |
| `status` | Show service status |
| `start` / `stop` / `restart` | Control the service |
| `config add <link>` | Add a node (link, `wireguard://` or `.conf` file) |
| `config list` | List nodes |
| `config switch <name>` | Switch node |
| `sub add <name> <url>` | Add a subscription |
| `sub update-all` | Update all subscriptions |
| `proxy mode <blacklist\|whitelist>` | Set the per-app mode |
| `proxy add <package>` | Add an app to the list |

Run `cli help` for everything.

## Configuration

| File | Purpose |
| --- | --- |
| `config/module.conf` | Autostart, outbound mode, current node |
| `config/tproxy/tproxy.conf` | Ports, interfaces, IPv6, app lists |
| `config/xray/confdir/` | Xray config (DNS, routing, inbounds) |
| `config/xray/outbounds/` | Your nodes |

Logs are in `logs/service.log` and `logs/xray.log`.

To keep open connections when you change the app list, add `DROP_CONNECTIONS=0` to `config/tproxy/tproxy.conf`.

## Notes

- Changing the app list or switching node closes open TCP connections, so downloads in progress may restart.
- Switching with a node that uses a hostname does not close old connections. Re-import the node so it stores an IP.
- UDP-based protocols (QUIC, WireGuard) are not closed on switch.

## Credits

- [Xray-core](https://github.com/XTLS/Xray-core)
- Original module by Fanju
