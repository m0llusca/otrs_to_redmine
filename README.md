<p align="center">
  <strong>English</strong> ·
  <a href="./README.ru.md">Русский</a> ·
  <a href="./README.es.md">Español</a>
</p>

# OTRSRedmineBridge

OTRS 6 CE / Znuny 7 ↔ Redmine bridge: escalate or link tickets; Redmine status notes sync back to OTRS.

[![Version](https://img.shields.io/badge/version-1.0.27-0B5FFF)](./OTRSRedmineBridge.sopm)
[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-green)](./LICENSE)
[![OTRS](https://img.shields.io/badge/OTRS-6.0-informational)](https://community.znuny.org/)
[![Znuny](https://img.shields.io/badge/Znuny-7.x-informational)](https://www.znuny.org/)

## Features

- **Miscellaneous → Create Redmine issue** — create or link, project / tracker / assignee / priority, confirmation
- **Miscellaneous → Open in Redmine** — uses `Redmine::BaseURL`
- Already-linked popup: siblings, unlink / relink, sync now
- Redmine → OTRS: status and comments on StatusSync `|note` (Daemon); ticket correspondence is not copied to Redmine
- Admin UI: connectivity / TLS checks, timeouts, Daemon health, Ticket Zoom fields
- Hardening: UI timeout, circuit breaker, content URL allow-list, create-only project allow-list

## Requirements

- OTRS 6.0+ or Znuny 7.x (Perl 5.16+)
- Redmine with REST API and a **service** API key
- Network path from OTRS to Redmine (HTTPS / proxy / DNS)
- **Daemon** (`otrs.Daemon.pl` / `znuny.Daemon.pl`) for Redmine → ticket sync and retries

## Install

1. Build the `.opm` (`Dev::Package::Build`).
2. Admin → Package Manager → Install / Upgrade.
3. Admin → **OTRS ↔ Redmine Bridge** (or SysConfig `Core::Redmine`):
   - `Redmine::BaseURL`, `APIKey`, `ProjectID`, `TrackerID`
   - `Redmine::OTRSBaseURL` — public OTRS URL, not the server hostname
   - `Redmine::Enabled` = `0` until a first check passes
4. Keep Daemon running. Do not commit API keys.

Details: [docs/en/DEPLOY.md](./docs/en/DEPLOY.md).

## Architecture

```
Kernel/System/Redmine.pm          facade
Kernel/System/Redmine/HTTP.pm     HTTP / TLS
Kernel/System/Redmine/Issue.pm    create / link / unlink
Kernel/System/Redmine/Sync.pm     Redmine → OTRS sync
Kernel/System/Redmine/Catalog.pm  projects / trackers / users
Kernel/System/Redmine/TicketDF.pm dynamic fields
Kernel/System/Redmine/Diagnostics.pm  Admin checks
```

## Documentation

| Topic | EN | RU | ES |
|-------|----|----|----|
| Docs index | [en](./docs/README.md) | [ru](./docs/README.ru.md) | [es](./docs/README.es.md) |
| Install | [en](./docs/en/DEPLOY.md) | [ru](./docs/ru/DEPLOY.md) | [es](./docs/es/DEPLOY.md) |
| Product brief | [en](./docs/en/PRODUCT.md) | [ru](./docs/ru/PRODUCT.md) | [es](./docs/es/PRODUCT.md) |

## License

[GNU GPL v3](./LICENSE).
