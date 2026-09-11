<p align="center">
  <a href="./README.md">English</a> ·
  <strong>Русский</strong> ·
  <a href="./README.es.md">Español</a>
</p>

# OTRSRedmineBridge

Мост OTRS 6 CE / Znuny 7 ↔ Redmine: эскалация или привязка тикетов; заметки Redmine при смене статуса приходят в OTRS.

[![Version](https://img.shields.io/badge/version-1.0.29-0B5FFF)](./OTRSRedmineBridge.sopm)
[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-green)](./LICENSE)
[![OTRS](https://img.shields.io/badge/OTRS-6.0-informational)](https://community.znuny.org/)
[![Znuny](https://img.shields.io/badge/Znuny-7.x-informational)](https://www.znuny.org/)

## Возможности

- **Разное → Создать задачу в Redmine** — создание или привязка, проект / трекер / исполнитель / приоритет, подтверждение
- **Разное → Open in Redmine** — URL из `Redmine::BaseURL`
- Окно уже привязанного тикета: соседние тикеты, отвязка / перепривязка, синк сейчас
- Redmine → OTRS: статус и комментарии по правилу StatusSync `|note` (Daemon)
- Письма и заметки тикета в Redmine **не** копируются (только создание/привязка)
- Admin UI: проверка связи / TLS, таймауты, здоровье Daemon, поля Ticket Zoom
- Защита: UI-таймаут, circuit breaker, allow-list URL вложений, список проектов только для Create

## Требования

- OTRS 6.0+ или Znuny 7.x (Perl 5.16+)
- Redmine с REST API и **сервисным** ключом
- Сеть от OTRS до Redmine (HTTPS / proxy / DNS)
- **Daemon** (`otrs.Daemon.pl` / `znuny.Daemon.pl`) для синка Redmine → тикеты и повторов

## Установка

1. Собрать `.opm` (`Dev::Package::Build`).
2. Admin → Package Manager → Install / Upgrade.
3. Admin → **OTRS ↔ Redmine Bridge** (или SysConfig `Core::Redmine`):
   - `Redmine::BaseURL`, `APIKey`, `ProjectID`, `TrackerID`
   - `Redmine::OTRSBaseURL` — публичный URL OTRS, не hostname сервера
   - `Redmine::Enabled` = `0` до первой проверки
4. Daemon должен быть запущен. API-ключ не коммитить.

Подробности: [docs/ru/DEPLOY.md](./docs/ru/DEPLOY.md). Что копируется: [docs/ru/PRODUCT.md](./docs/ru/PRODUCT.md).

## Архитектура

```
Kernel/System/Redmine.pm          фасад
Kernel/System/Redmine/HTTP.pm     HTTP / TLS
Kernel/System/Redmine/Issue.pm    создание / привязка / отвязка
Kernel/System/Redmine/Sync.pm     синк Redmine → OTRS
Kernel/System/Redmine/Catalog.pm  проекты / трекеры / пользователи
Kernel/System/Redmine/TicketDF.pm динамические поля
Kernel/System/Redmine/Diagnostics.pm  проверки в Admin
```

## Документация

| Тема | EN | RU | ES |
|------|----|----|----|
| Оглавление | [en](./docs/README.md) | [ru](./docs/README.ru.md) | [es](./docs/README.es.md) |
| Установка | [en](./docs/en/DEPLOY.md) | [ru](./docs/ru/DEPLOY.md) | [es](./docs/es/DEPLOY.md) |
| Product brief | [en](./docs/en/PRODUCT.md) | [ru](./docs/ru/PRODUCT.md) | [es](./docs/es/PRODUCT.md) |

## Лицензия

[GNU GPL v3](./LICENSE).
