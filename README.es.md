<p align="center">
  <a href="./README.md">English</a> ·
  <a href="./README.ru.md">Русский</a> ·
  <strong>Español</strong>
</p>

# OTRSRedmineBridge

Puente OTRS 6 CE / Znuny 7 ↔ Redmine: escalar o vincular tickets; las notas de estado de Redmine vuelven a OTRS.

[![Version](https://img.shields.io/badge/version-1.0.29-0B5FFF)](./OTRSRedmineBridge.sopm)
[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-green)](./LICENSE)
[![OTRS](https://img.shields.io/badge/OTRS-6.0-informational)](https://community.znuny.org/)
[![Znuny](https://img.shields.io/badge/Znuny-7.x-informational)](https://www.znuny.org/)

## Funciones

- **Varios → Crear incidencia en Redmine** — crear o vincular, proyecto / tracker / asignado / prioridad, confirmación
- **Varios → Abrir en Redmine** — usa `Redmine::BaseURL`
- Ventana de ticket ya vinculado: tickets hermanos, desvincular / volver a vincular, sincronizar ahora
- Redmine → OTRS: estado y comentarios con StatusSync `|note` (Daemon)
- El correo y las notas del ticket **no** se copian a Redmine (solo crear/vincular)
- Admin UI: conectividad / TLS, timeouts, salud del Daemon, campos de Ticket Zoom
- Endurecimiento: timeout de UI, circuit breaker, lista de URL de contenido, lista de proyectos solo para Create

## Requisitos

- OTRS 6.0+ o Znuny 7.x (Perl 5.16+)
- Redmine con API REST y clave de **cuenta de servicio**
- Red desde OTRS hacia Redmine (HTTPS / proxy / DNS)
- **Daemon** (`otrs.Daemon.pl` / `znuny.Daemon.pl`) para el sync Redmine → tickets y reintentos

## Instalación

1. Genere el `.opm` (`Dev::Package::Build`).
2. Admin → Package Manager → Install / Upgrade.
3. Admin → **OTRS ↔ Redmine Bridge** (o SysConfig `Core::Redmine`):
   - `Redmine::BaseURL`, `APIKey`, `ProjectID`, `TrackerID`
   - `Redmine::OTRSBaseURL` — URL pública de OTRS, no el hostname del servidor
   - `Redmine::Enabled` = `0` hasta la primera comprobación
4. El Daemon debe estar en marcha. No suba claves API al repositorio.

Detalles: [docs/es/DEPLOY.md](./docs/es/DEPLOY.md). Qué se copia: [docs/es/PRODUCT.md](./docs/es/PRODUCT.md).

## Arquitectura

```
Kernel/System/Redmine.pm          fachada
Kernel/System/Redmine/HTTP.pm     HTTP / TLS
Kernel/System/Redmine/Issue.pm    crear / vincular / desvincular
Kernel/System/Redmine/Sync.pm     sync Redmine → OTRS
Kernel/System/Redmine/Catalog.pm  proyectos / trackers / usuarios
Kernel/System/Redmine/TicketDF.pm campos dinámicos
Kernel/System/Redmine/Diagnostics.pm  comprobaciones Admin
```

## Documentación

| Tema | EN | RU | ES |
|------|----|----|----|
| Índice | [en](./docs/README.md) | [ru](./docs/README.ru.md) | [es](./docs/README.es.md) |
| Instalación | [en](./docs/en/DEPLOY.md) | [ru](./docs/ru/DEPLOY.md) | [es](./docs/es/DEPLOY.md) |
| Brief del producto | [en](./docs/en/PRODUCT.md) | [ru](./docs/ru/PRODUCT.md) | [es](./docs/es/PRODUCT.md) |

## Licencia

[GNU GPL v3](./LICENSE).
