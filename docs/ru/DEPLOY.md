> **Язык:** [English](../en/DEPLOY.md) · **Русский** · [Español](../es/DEPLOY.md)

# Установка

Собрать `.opm`, поставить в Package Manager, затем задать SysConfig (или экран Admin).

## Перед установкой

1. Сервисная УЗ Redmine (не личный API-ключ) с правом создавать задачи в целевом проекте.
2. Согласованные `project_id` / `tracker_id`.
3. Сеть от OTRS до Redmine (TLS, proxy, DNS).
   - С хоста OTRS: `curl -vI --max-time 15 https://redmine.example.org/` (ожидается HTTP 200/302, не timeout).
   - TLS: `openssl s_client -connect redmine.example.org:443 -tls1_2 </dev/null` — должен завершиться без `handshake failure`.
   - Если curl/openssl OK, а мост падает на SSL — Admin → TLS diagnostics; при необходимости `Redmine::AllowLegacyTLS` только временно.
   - Если выход только через proxy — SysConfig `WebUserAgent::Proxy`.
4. `Package::AllowNotVerifiedPackages` (или подпись пакета по политике ИБ).
5. **OTRS Daemon** должен быть запущен (иначе нет Redmine→OTRS sync / retry).

## Шаги

1. Собрать `.opm` из этого репо (`Dev::Package::Build`).
2. Admin → Package Manager → Install/Upgrade (версия **1.0.0+**).
3. Убедиться, что созданы DF `Redmine*` (включая RetryPayload / LastSyncAt). Очередь `Escalation-Redmine` **не нужна** — триггер только меню «Разное».
4. Admin → **OTRS ↔ Redmine Bridge** (предпочтительно) или SysConfig → `Core::Redmine`:
   - `Redmine::BaseURL` / `APIKey` / `ProjectID` / `TrackerID`
   - `Redmine::OTRSBaseURL` = `https://otrs.example.org` (публичный URL, не hostname сервера)
   - `Redmine::AllowedProjectIDs` — проекты, разрешённые для Create (пусто = только ProjectID); Link/relink — любой проект
   - `Redmine::UITimeout` = 5 (не поднимать без нужды)
   - `Redmine::AutoRetry` = **0** до проверки retry payload; включать осознанно
   - `Redmine::SubjectPrefix` = **пусто**
   - `Redmine::Enabled` = `0` до первой проверки
5. Кнопка Admin «Показать поля Redmine в карточке» (или Zoom DF уже мержатся на install).
6. Проверка: Daemon health в Admin → Run sync now; TicketZoom → **Разное** → эскалация/Link; второй клик без дубля issue.
7. Затем `Enabled=1` для нужных агентов + ACL/`Redmine::AgentGroup` при необходимости.

## Не делать

- Не коммитить API-ключ.
- Не включать мост всем сразу без ACL и способа выключить (`Enabled=0`).
