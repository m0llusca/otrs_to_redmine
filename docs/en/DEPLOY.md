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
5. **OTRS Daemon** must be running (otherwise there is no Redmine → OTRS sync / retry).

## Steps

1. Build the `.opm` from this repo (`Dev::Package::Build`).
2. Admin → Package Manager → Install/Upgrade (version **1.0.0+**).
3. Confirm `Redmine*` dynamic fields exist (including RetryPayload / LastSyncAt). An `Escalation-Redmine` queue is **not** needed — the trigger is the Miscellaneous menu only.
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

## Do not

- Do not commit the API key.
- Do not enable the bridge for everyone without ACL and a way to turn it off (`Enabled=0`).
