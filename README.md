# Deploy OpenClaw

Interactive TUI wizard for deploying [OpenClaw](https://openclaw.bot) on Ubuntu/Debian VPS.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/PhucMPham/deploy-openclaw/main/scripts/deploy-openclaw.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/PhucMPham/deploy-openclaw.git
bash deploy-openclaw/scripts/deploy-openclaw.sh
```

## What It Does

5-phase interactive setup with arrow-key navigation:

1. **System Check** — OS, disk, internet, existing software detection
2. **User Setup** — Create `openclaw` user, workspace at `/opt/openclaw/`
3. **Security Setup** — UFW, SSH keys, SSH hardening, fail2ban, Tailscale (pick & choose)
4. **Software Install** — Docker CE, NVM, Node.js v24, OpenClaw CLI
5. **OpenClaw Setup** — Hands off to `openclaw onboard --install-daemon` for model auth + channel config

## Features

- Pure Bash, zero dependencies (works via `curl | bash`)
- Arrow-key TUI menus and checkbox selectors
- Resume from crash/disconnect via state persistence
- SSH hardening safety gate (refuses without verified SSH keys)
- Rollback on failure for critical changes (sshd_config)
- Pipe-mode detection: auto re-execs with TTY for interactive use

## Requirements

- Ubuntu 22.04+ or Debian 11+
- Root access or sudo
- Internet connectivity
- 2GB+ free disk space

## Channel Setup

Channel configuration (Discord, Telegram, WhatsApp, Slack, Signal, iMessage) is handled by `openclaw onboard` — this script does not hardcode any specific messaging platform.

## Post-Install Commands

```bash
openclaw doctor           # Health check
openclaw configure        # Add/modify channels
openclaw gateway status   # Check gateway
```

## License

MIT
