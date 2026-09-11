> **Idioma:** [English](../en/DEPLOY.md) · [Русский](../ru/DEPLOY.md) · **Español**

# Instalación

Genere el `.opm`, instálelo en Package Manager y configure SysConfig (o la pantalla Admin).

## Antes de instalar

1. Cuenta de **servicio** en Redmine (no una clave API personal) con permiso para crear incidencias en el proyecto destino.
2. `project_id` / `tracker_id` acordados.
3. Red desde OTRS hacia Redmine (TLS, proxy, DNS).
   - Desde el host OTRS: `curl -vI --max-time 15 https://redmine.example.org/` (HTTP 200/302, no timeout).
   - TLS: `openssl s_client -connect redmine.example.org:443 -tls1_2 </dev/null` — debe terminar sin `handshake failure`.
   - Si curl/openssl van bien pero el puente falla en SSL — Admin → TLS diagnostics; `Redmine::AllowLegacyTLS` solo de forma temporal.
   - Si la salida va por proxy — SysConfig `WebUserAgent::Proxy`.
4. `Package::AllowNotVerifiedPackages` (o firme el paquete según su política).
5. El **Daemon** debe estar en marcha (`otrs.Daemon.pl` o `znuny.Daemon.pl`); si no, no hay sync / reintento Redmine → sistema de tickets.

## Pasos

1. Compilar el `.opm` desde este repo (`Dev::Package::Build`).
2. Admin → Package Manager → Install/Upgrade (versión **1.0.0+**).
3. Comprobar que existen los DF `Redmine*` (incluidos RetryPayload / LastSyncAt). La cola `Escalation-Redmine` **no** hace falta: el disparador es solo el menú Varios.
4. Admin → **OTRS ↔ Redmine Bridge** (preferible) o SysConfig → `Core::Redmine`:
   - `Redmine::BaseURL` / `APIKey` / `ProjectID` / `TrackerID`
   - `Redmine::OTRSBaseURL` = `https://otrs.example.org` (URL pública, no el hostname del servidor)
   - `Redmine::AllowedProjectIDs` — proyectos permitidos para Create (vacío = solo ProjectID); Link/relink — cualquier proyecto
   - `Redmine::UITimeout` = 5 (no lo suba sin motivo)
   - `Redmine::AutoRetry` = **0** hasta verificar el payload de reintento; actívelo a propósito
   - `Redmine::SubjectPrefix` = **vacío**
   - `Redmine::Enabled` = `0` hasta la primera comprobación
5. Botón Admin «Mostrar campos Redmine en el ticket» (o los DF de Zoom ya se mezclan al instalar).
6. Comprobar: salud del Daemon en Admin → Run sync now; TicketZoom → **Varios** → escalar/Link; el segundo clic no debe duplicar la incidencia.
7. Luego `Enabled=1` para los agentes que lo necesiten + ACL / `Redmine::AgentGroup` si hace falta.

## Sincronización (desde 1.0.27)

El correo y las notas del ticket **no** se envían a Redmine tras crear/vincular, y el puente no escribe un comentario al vincular/desvincular. Redmine → OTRS requiere Daemon y `Redmine::InboundSync`.

`Redmine::StatusSync` — una regla por línea, nombre de estado Redmine = estado OTRS:

| Valor | Efecto |
|-------|--------|
| `open` | Solo cambia el estado OTRS |
| `open\|note` | Estado **y** nota interna (estado + comentario de ese diario) |
| `note` | Solo nota, sin cambiar el estado |

Ejemplo: `Проверка решения = open|note`. Los comentarios sin ese cambio de estado se quedan en Redmine.

Qué se copia y qué no: [PRODUCT.md](./PRODUCT.md).

## No hacer

- No commitear la clave API.
- No activar el puente para todos sin ACL y una forma de apagarlo (`Enabled=0`).
