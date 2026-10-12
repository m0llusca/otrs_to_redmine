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
3. Comprobar que existen los DF `Redmine*` (incluidos RetryPayload / LastAttachmentSyncOn). La cola `Escalation-Redmine` **no** hace falta: el disparador es solo el menú Varios.
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

El correo y las notas del ticket **no** se envían a Redmine tras crear/vincular. Al vincular/desvincular solo hay una nota breve (enlace del ticket + agente), sin sello del puente. Redmine → OTRS requiere Daemon y `Redmine::InboundSync`.

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

## Límites de recursos y planificación

La sincronización entrante recorre páginas limitadas por ID de ticket. La caché de OTRS conserva el cursor; al vaciarla, el recorrido empieza de nuevo. Se excluyen tickets archivados cuando el archivo está habilitado. Los tickets vinculados comparten la consulta de la tarea y su diario dentro de un grupo, conservando cursores independientes. Una tarea sin cambios solo necesita un GET compacto y actualizar la hora de comprobación.

Configure estos límites en SysConfig `Core::Redmine`:

| Ajuste | Predeterminado | Función |
|---|---:|---|
| `Redmine::MaxAttachmentBytes` | 5 000 000 | Bytes por archivo |
| `Redmine::MaxAttachmentTotalBytes` | 20 000 000 | Bytes totales por creación / nota entrante |
| `Redmine::MaxAttachmentCount` | 20 | Archivos por operación; también limita los intentos de descarga entrante |

Si la selección supera el límite, la creación se rechaza antes de crear la tarea. Los archivos entrantes omitidos por límites se enumeran en la nota interna y se marcan como vistos; para importarlos después de aumentar el límite hay que restablecer deliberadamente el cursor de adjuntos. Las descargas se interrumpen al superar el límite y los bytes binarios no se decodifican como UTF-8. Los adjuntos compartidos usan archivos temporales eliminados automáticamente.

Los archivos de artículos se leen y envían uno por uno. La API pública UploadCache de OTRS 6 devuelve juntos los contenidos de cargas adicionales, por lo que se valida su tamaño total mediante metadatos antes de leerlos. Este límite de la API y la memoria del OTRS instalado requieren medición en ejecución.

## Validación local

`prove -I tests/lib -I . tests/*.t`

Requiere Perl, Test::More, DBI, DBD::SQLite, JSON::PP, LWP::UserAgent y HTTP::Daemon. Las pruebas usan dobles de servicios OTRS, SQL real en SQLite y un servidor HTTP local; no contactan OTRS/Redmine de producción. `perl tests/performance_counts.pl` muestra recuentos de operaciones de un escenario reproducible, no mediciones de CPU/RSS en producción.

Durante la creación o vinculación de una tarea, el cliente HTTP reutiliza como máximo una conexión dentro de la operación y se libera al salir. Un cambio de URL, proxy, timeout o configuración TLS crea un cliente nuevo; cada petición utiliza la clave API actual. Los archivos adjuntos se siguen procesando uno por uno. Las mediciones locales de CPU/RSS y la verificación TLS se documentan en `tests/runtime/results/cpu-investigation/REPORT.md`.

La versión 1.0.30 crea el campo interno `RedmineLastAttachmentSyncOn`, un cursor separado para reactivar la sincronización de adjuntos con seguridad. Los enlaces existentes consultan los detalles una vez tras la actualización y después vuelven al GET compacto. Los archivos del formulario se fijan en archivos temporales antes de crear la tarea; se rechaza un cambio entre metadatos y contenido. UploadCache de OTRS 6 solo ofrece una lectura agregada: los cambios simultáneos pueden superar el pico previsto dentro de esa llamada, aunque el conjunto modificado se rechaza antes de las peticiones de red. Un fallo de adjuntos no impide cambiar el estado; los fallos de notas conservan los cursores para reintentar.

## Sincronización en 1.0.31

Solo cambia la extensión OTRS. Se usa la API REST estándar de Redmine sin plugins ni webhooks. `DaemonModules###RedmineBridgePoller` consulta tareas vinculadas únicas en lotes de hasta 100 ID. `Redmine::SyncPollInterval` define la pausa entre recorridos (5 segundos por defecto), no el plazo de entrega. Mil tareas distintas requieren al menos diez peticiones por recorrido; mil tickets de una misma tarea requieren una. Una detección más rápida puede aumentar la frecuencia de peticiones respecto al cron anterior de cinco minutos.

Las tablas `redmine_sync_issue` y `redmine_sync_lock` de la base de datos existente guardan versiones, progreso y reintentos. Scheduler entrega hasta `Redmine::SyncBatchLimit` tickets por proceso (50 por defecto), comprobando un presupuesto de diez segundos entre tickets; una llamada de red puede tardar más. `Redmine::SyncWorkers` limita los procesos activos (1 por defecto, rango 1–4). El trabajo pendiente se recupera tras errores o reinicios. Se elimina `Daemon::SchedulerCronTaskManager::Task###95-RedmineBridgeSync`; no añada un cron externo paralelo. Reinicie el Daemon después de instalar/actualizar. “Run sync now” detecta cambios y entrega un lote; Daemon continúa el resto.

Los tickets sin cambios no reciben escrituras técnicas de campos, historial ni eventos. Ya no se crea ni actualiza `RedmineLastSyncAt`; una actualización conserva el campo anterior y sus valores históricos. Las comprobaciones operativas se guardan en el caché de salud. Se reproducen los diarios de estado por ID, incluso un cambio seguido del regreso al estado original. Se mantienen `StatusSync |note`, cursores independientes, tickets cerrados y la exclusión de comentarios ordinarios/notas solo de archivos. Hasta dos consultas de detalle por recorrido verifican cambios con el mismo `updated_on`, permitiendo consultas más frecuentes de tareas recientes y conciliando periódicamente las demás; en este caso la detección no es instantánea.

HTTP 429/502/503/504 activa una pausa compartida por origen, respetando `Retry-After` hasta una hora o una demora exponencial. Los archivos fallidos conservan el trabajo pendiente y se intentan una vez por lote de la misma tarea. La sincronización manual y automática comparten bloqueos. Nota entrante, archivos en base de datos y cursores se confirman en una transacción corta después de las llamadas de red. Se requieren tablas transaccionales. El rollback del almacenamiento en archivos puede dejar archivos sin referencia; las acciones externas de manejadores inmediatos de terceros no se revierten mediante la base de datos.

El proceso recarga la configuración mediante el reinicio estándar del módulo aproximadamente cada minuto, tras terminar el recorrido actual.

Las notificaciones nativas de OTRS se envían después de la transacción. Una caída entre commit y el envío no garantiza la entrega de la notificación; la garantía de rollback se refiere a la nota y los cursores de la base de datos.

Las actualizaciones continuas conservan el cursor del recorrido activo; una ronda posterior actualiza los tickets ya procesados. Las tareas listas se ordenan por su última atención para evitar que una tarea muy activa o un reintento bloquee las demás. El lease y la versión de la ronda activa permiten terminar descargas lentas mientras la versión nueva sigue pendiente.

Un ticket fallido no bloquea a los demás: la base de datos conserva el primer fallo y el cursor, y el recorrido vuelve a ese punto al terminar. Las notas exitosas mantienen cursores independientes. Los cambios intermedios se guardan en la nota; el estado OTRS sigue el estado actual de Redmine, sin repetir cambios históricos open/close al fallar un archivo.
