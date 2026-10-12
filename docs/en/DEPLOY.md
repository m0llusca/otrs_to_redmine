> **Language:** **English** · [Русский](../ru/DEPLOY.md) · [Español](../es/DEPLOY.md)

# Install

Build the `.opm`, install it in Package Manager, then set SysConfig (or the Admin screen).

## Before you install

1. A Redmine **service** account (not a personal API key) that can create issues in the target project.
2. Agreed `project_id` / `tracker_id`.
3. Network path from OTRS to Redmine (TLS, proxy, DNS).
   - From the OTRS host: `curl -vI --max-time 15 https://redmine.example.org/` (expect HTTP 200/302, not a timeout).
   - TLS: `openssl s_client -connect redmine.example.org:443 -tls1_2 </dev/null` — must finish without `handshake failure`.
   - If curl/openssl succeed but the bridge fails on SSL — Admin → TLS diagnostics; use `Redmine::AllowLegacyTLS` only temporarily.
   - If outbound traffic must go through a proxy — SysConfig `WebUserAgent::Proxy`.
4. `Package::AllowNotVerifiedPackages` (or sign the package per your security policy).
5. The **Daemon** must be running (`otrs.Daemon.pl` or `znuny.Daemon.pl`) — otherwise there is no Redmine → ticket-system sync / retry.

## Steps

1. Build the `.opm` from this repo (`Dev::Package::Build`).
2. Admin → Package Manager → Install/Upgrade (version **1.0.0+**).
3. Confirm `Redmine*` dynamic fields exist (including RetryPayload / LastAttachmentSyncOn). An `Escalation-Redmine` queue is **not** needed — the trigger is the Miscellaneous menu only.
4. Admin → **OTRS ↔ Redmine Bridge** (preferred) or SysConfig → `Core::Redmine`:
   - `Redmine::BaseURL` / `APIKey` / `ProjectID` / `TrackerID`
   - `Redmine::OTRSBaseURL` = `https://otrs.example.org` (public URL, not a server hostname)
   - `Redmine::AllowedProjectIDs` — projects allowed for Create (empty = ProjectID only); Link/relink — any project
   - `Redmine::UITimeout` = 5 (do not raise without a reason)
   - `Redmine::AutoRetry` = **0** until retry payload is verified; enable on purpose
   - `Redmine::SubjectPrefix` = **empty**
   - `Redmine::Enabled` = `0` until a first check
5. Admin button “Show Redmine fields on the ticket” (or Zoom DFs are already merged on install).
6. Check: Daemon health in Admin → Run sync now; TicketZoom → **Miscellaneous** → escalate/Link; second click must not create a duplicate issue.
7. Then `Enabled=1` for the agents who need it + ACL / `Redmine::AgentGroup` if needed.

## Sync (from 1.0.27)

Ticket mail and notes are **not** pushed to Redmine after create/link. Link/unlink write only a short journal (ticket link + agent), without a bridge stamp. Redmine → OTRS needs the Daemon and `Redmine::InboundSync`.

`Redmine::StatusSync` — one rule per line, Redmine status name = OTRS state:

| Value | Effect |
|-------|--------|
| `open` | Set the OTRS state only |
| `open\|note` | Set the state **and** write an internal note (status + that journal comment) |
| `note` | Internal note only, no state change |

Example: `Проверка решения = open|note`. Comments without such a status transition stay in Redmine.

What is copied and what is not: [PRODUCT.md](./PRODUCT.md).

## Do not

- Do not commit the API key.
- Do not enable the bridge for everyone without ACL and a way to turn it off (`Enabled=0`).

## Resource limits and synchronization scheduling

Inbound synchronization uses bounded ticket-ID pages. OTRS cache stores the traversal cursor; clearing the cache restarts traversal. Archived tickets are excluded when OTRS archiving is enabled. Sibling tickets share an issue snapshot and journal within one group while retaining independent checkpoints. An unchanged issue needs only a compact GET and a check timestamp update.

Configure these limits in SysConfig `Core::Redmine`:

| Setting | Default | Meaning |
|---|---:|---|
| `Redmine::MaxAttachmentBytes` | 5,000,000 | Per-file bytes |
| `Redmine::MaxAttachmentTotalBytes` | 20,000,000 | Total file bytes per create operation / inbound note |
| `Redmine::MaxAttachmentCount` | 20 | Files per operation; also bounds inbound download attempts |

Create preflight rejects an over-budget selection before creating the issue. Inbound over-budget files are listed in the internal note and marked seen; importing them after raising a limit requires a deliberate attachment-cursor reset. Downloads stop at the byte limit, and binary content is not UTF-8 decoded. Shared issue attachments use automatically cleaned disk spools.

Ticket article files are read and uploaded individually. The public OTRS 6 UploadCache API returns extra-upload contents together, so their aggregate size is checked through metadata before loading them. This API boundary and the installed OTRS process memory still require runtime profiling.

## Local validation

`prove -I tests/lib -I . tests/*.t`

Requires Perl, Test::More, DBI, DBD::SQLite, JSON::PP, LWP::UserAgent and HTTP::Daemon. Tests use OTRS service-boundary doubles, actual SQLite candidate SQL and a loopback HTTP transport server. They do not contact production OTRS/Redmine. `perl tests/performance_counts.pl` reports operation counts for a reproducible fixture, not production CPU/RSS measurements.

During ticket escalation, the HTTP client reuses at most one connection within the operation and releases it on exit. A change to the URL, proxy, timeout or TLS settings creates a new client; each request uses the current API key. Attachment contents are still processed one file at a time. Local CPU/RSS comparisons and TLS verification are documented in `tests/runtime/results/cpu-investigation/REPORT.md`.

Version 1.0.30 creates the internal `RedmineLastAttachmentSyncOn` field, a separate cursor that supports safely re-enabling attachment sync. Existing links fetch issue details once after upgrade, then resume compact GET checks. Form uploads are frozen in temporary files before issue creation; a changed metadata/data snapshot is rejected. OTRS 6 UploadCache only exposes an aggregate content API: concurrent form changes can exceed the intended peak inside that API call, although the changed set is rejected before network side effects. Attachment failure does not cancel state mapping; failed notes retain retry checkpoints.

## Synchronization in 1.0.31

Only the OTRS extension changes. The standard Redmine REST API is used without Redmine plugins or webhooks. `DaemonModules###RedmineBridgePoller` polls unique linked issues in batches of up to 100 IDs. `Redmine::SyncPollInterval` is the pause between sweeps (default 5 seconds), not a delivery deadline. A thousand distinct issues need at least ten list requests per sweep; a thousand tickets sharing one issue need one. Faster detection can increase Redmine request frequency compared with the former five-minute cron.

Two tables in the existing OTRS database, `redmine_sync_issue` and `redmine_sync_lock`, retain observed generations, progress and retries. Scheduler delivers at most `Redmine::SyncBatchLimit` tickets per worker (default 50), checking a ten-second budget between tickets; an individual network call may take longer. `Redmine::SyncWorkers` limits active delivery tasks (default 1, range 1–4). Pending work recovers after failures/restarts. The old `Daemon::SchedulerCronTaskManager::Task###95-RedmineBridgeSync` setting is removed; do not add a parallel external cron. Restart the standard Daemon after install/upgrade. Admin “Run sync now” detects changes and processes one delivery batch; Daemon continues the rest.

Unchanged tickets receive no diagnostic dynamic-field writes, history or events. `RedmineLastSyncAt` is no longer created or updated; upgrades retain the old field and historical values. Operational checks live in the health cache. Status journals are replayed by ID, including a transition followed by a return to the original status. `StatusSync |note`, independent ticket cursors, closed-ticket synchronization and suppression of ordinary comments/file-only notes are preserved. Limited detail probes (up to two per sweep) cover equal `updated_on` values, allowing more frequent checks of recently changed issues and periodically reconciling older ones; detection is not instantaneous in this case.

HTTP 429/502/503/504 sets a shared source cooldown, honoring `Retry-After` up to one hour or using exponential delay. Failed attachments retain pending work; the same failing file is attempted once within an issue delivery batch. Manual/background sync share ticket leases. Incoming note creation, database attachments and business checkpoints commit in one short transaction after network IO. Transactional database tables are required. Rollback with filesystem storage can leave unreferenced files; external side effects of third-party immediate event handlers cannot be rolled back by the database.

The background process reloads settings through the standard daemon recycle about once a minute, after its current sweep finishes.

Native OTRS notifications are sent after the transaction. A process crash between commit and notification dispatch does not guarantee notification delivery; rollback coverage applies to the note and database checkpoints.

Continuous issue updates preserve the active sweep cursor. Once that round finishes, a new round catches earlier tickets up. Ready issues are ordered by their last service time so hot issues and due retries cannot starve others. The lease and active round version allow slow downloads to finish while the newer observed version remains pending.

A failed ticket does not block its siblings: the database retains the first failed ticket and the scan cursor, and delivery returns to that gap after the sweep. Successful notes retain independent checkpoints. Intermediate transitions remain in the note; OTRS state follows only the current Redmine status, avoiding repeated historical open/close transitions when a file fails.
