# HackNet

A Bash tool that creates an **isolated network namespace** for cybersecurity lab work on Linux. Your scans, exploits, and lab traffic stay locked inside a sandbox — they can never reach the internet or your school network.

## What Problem Does This Solve?

When you're learning penetration testing, you run tools like Nmap, Metasploit, and Burp Suite against vulnerable VMs. If those tools accidentally hit the wrong network, that's a bad day. HackNet puts a wall around your lab traffic so that can't happen.

## How It Works

HackNet uses Linux **network namespaces** — think of it like putting your lab network adapter inside a locked room. Only tools running *inside that room* can talk to your lab VMs. Everything else on your system (browser, email, etc.) keeps using the internet normally.

1. You pick which network adapter connects to your VirtualBox lab
2. `hn-start` moves that adapter into an isolated namespace
3. A red-prompt terminal opens — anything you run there is contained
4. `hn-stop` unlocks the room and puts everything back to normal

## Requirements

- Linux (tested on Kali and Debian)
- VirtualBox with a host-only or internal lab network
- Root/sudo access
- `iproute2`, `NetworkManager`, and a DHCP client (`dhcpcd` or `dhclient`)

## Install

```bash
sudo ./hacknet.sh install
```

Follow the prompts to select your lab and internet interfaces.

## Commands

| Command | What it does |
|---|---|
| `hn-start` | Start the isolated lab environment |
| `hn-stop` | Stop and restore your network to normal |
| `hn-status` | Check isolation, connectivity, and DNS |
| `hn-panic` | Emergency hard-reset if something breaks |
| `hn-help` | Show detailed usage docs |

## Uninstall

```bash
sudo ./hacknet.sh uninstall
```

## Troubleshooting

| Problem | Fix |
|---|---|
| Can't reach lab VMs | Is VirtualBox running? Is the DHCP VM on? |
| Lost internet | Run `hn-stop`, then `sudo systemctl restart NetworkManager` |
| Interface missing | Run `hn-panic` or reboot |

## Status

Early / testing phase — use at your own risk. Feedback and bug reports welcome.

## License

[MIT](LICENSE)
