# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
package Kernel::Language::ru_OTRSRedmineBridge;

use strict;
use warnings;
use utf8;

sub Data {
    my $Self = shift;

    my %Trans = (
        'Create Redmine issue' => 'Создать задачу в Redmine',
        'Create a linked Redmine issue for this ticket' =>
            'Создать связанную задачу в Redmine по этому тикету',
        'Could not create Redmine issue.' => 'Не удалось создать задачу в Redmine.',
        'Redmine issue already linked: #%s' => 'Задача Redmine уже связана: #%s',
        'Already linked'                    => 'Уже связана',
        'Open in Redmine'                   => 'Открыть в Redmine',
        'Redmine URL'                       => 'URL Redmine',
        'Actions'                           => 'Действия',
        'Redmine sync'                      => 'Синхронизация Redmine',
        'Already linked — details and sync from Redmine' =>
            'Уже связана — детали и синхронизация из Redmine',
        'Open linked Redmine issue'         => 'Открыть связанную задачу Redmine',
        'Open linked Redmine issue in a new tab' =>
            'Открыть связанную задачу Redmine в новой вкладке',
        'Sync from Redmine now'             => 'Синхронизировать из Redmine',
        'Synced from Redmine.'              => 'Синхронизация из Redmine выполнена.',
        'Could not sync from Redmine.'      => 'Не удалось синхронизировать из Redmine.',
        'No Redmine issue is linked to this ticket.' =>
            'К этому тикету не привязана задача Redmine.',
        'Other linked OTRS tickets'         => 'Другие связанные тикеты OTRS',
        'No other OTRS tickets are linked to this Redmine issue.' =>
            'Других тикетов OTRS на этой задаче Redmine нет.',
        'Unlink from Redmine'               => 'Отвязать от Redmine',
        'I confirm unlinking this ticket from Redmine' =>
            'Подтверждаю отвязку этого тикета от Redmine',
        'Unlink'                            => 'Отвязать',
        'Relink to another Redmine issue'   => 'Перепривязать к другой задаче Redmine',
        'I confirm relinking to another Redmine issue' =>
            'Подтверждаю перепривязку к другой задаче Redmine',
        'Relink'                            => 'Перепривязать',
        'Redmine issue ID or URL'           => 'ID или URL задачи Redmine',
        'Please confirm unlinking from the Redmine issue.' =>
            'Подтвердите отвязку от задачи Redmine.',
        'Please confirm relinking to another Redmine issue.' =>
            'Подтвердите перепривязку к другой задаче Redmine.',
        'Could not unlink Redmine issue.'   => 'Не удалось отвязать задачу Redmine.',
        'Could not relink Redmine issue.'   => 'Не удалось перепривязать задачу Redmine.',
        'Unlinked from Redmine.'            => 'Отвязано от Redmine.',
        'Relinked to Redmine.'              => 'Перепривязано к Redmine.',
        'Redmine issue #%s is no longer linked.' =>
            'Задача Redmine #%s больше не связана.',
        'Notify on status note'             => 'Уведомлять при заметке статуса',
        'When a Redmine status change writes an OTRS note (|note, e.g. Проверка решения), notify the ticket owner and responsible.' =>
            'Когда смена статуса Redmine пишет заметку в OTRS (|note, например Проверка решения), уведомлять владельца и ответственного тикета.',
        'Redmine project'                   => 'Проект Redmine',
        'Redmine tracker'                   => 'Трекер Redmine',
        'Issue subject'                     => 'Тема задачи',
        'Issue description'                 => 'Описание задачи',
        'Please fill in subject and description.' =>
            'Заполните тему и описание задачи.',
        'All fields marked with an asterisk (*) are mandatory.' =>
            'Поля, отмеченные звёздочкой (*), обязательны для заполнения.',
        'Confirmation'                      => 'Подтверждение',
        'I confirm creating a new Redmine issue for this ticket' =>
            'Подтверждаю создание новой задачи в Redmine по этому тикету',
        'Please confirm issue creation.' => 'Подтвердите создание задачи.',
        'Please select project and tracker.' => 'Выберите проект и трекер.',
        'Could not load Redmine projects' => 'Не удалось загрузить проекты Redmine',
        'A Redmine issue will be created and linked to this OTRS ticket. This action cannot be undone from OTRS.' =>
            'Будет создана задача в Redmine и связана с этим тикетом OTRS. Отменить действие из OTRS нельзя.',
        'Cancel'  => 'Отменить',
        'or'      => 'или',
        'Ticket'  => 'Заявка',
        'Redmine' => 'Redmine',
        'OTRS ↔ Redmine Bridge' => 'OTRS ↔ Redmine',
        'Configure Redmine connection, sync and status rules.' =>
            'Настройка подключения к Redmine, синхронизации и правил статусов.',
        'Settings saved and deployed.' => 'Настройки сохранены и применены.',
        'Could not save settings.'     => 'Не удалось сохранить настройки.',
        'Configuration deploy failed.' => 'Не удалось применить конфигурацию.',
        'These settings are stored in SysConfig and deployed automatically on save. Daemon must be running for Redmine → OTRS sync.' =>
            'Настройки пишутся в SysConfig и применяются при сохранении. Для синхронизации Redmine → OTRS должен работать Daemon.',
        'These settings are stored in SysConfig and deployed automatically on save.' =>
            'Настройки пишутся в SysConfig и применяются при сохранении.',
        'Numeric IDs are taken from Redmine URLs or Administration → Settings (projects, trackers, priorities).' =>
            'Числовые ID берутся из URL Redmine или Администрирование → настройки (проекты, трекеры, приоритеты).',
        'OTRS Daemon must be running for Redmine → OTRS sync (every 5 minutes).' =>
            'Для синхронизации Redmine → OTRS (каждые 5 мин.) должен работать OTRS Daemon.',
        'Show Redmine fields on TicketZoom' =>
            'Показать поля Redmine в карточке тикета',
        'TicketZoom dynamic fields updated.' =>
            'Поля Redmine на TicketZoom обновлены.',
        'Could not update TicketZoom dynamic fields.' =>
            'Не удалось обновить поля Redmine на TicketZoom.',
        'Redmine fields enabled on TicketZoom (Theme and other keys kept)' =>
            'Поля Redmine включены на TicketZoom (Theme и другие ключи сохранены)',
        'TicketZoom already shows Redmine fields' =>
            'Поля Redmine на TicketZoom уже включены',
        'Master switch. When off, create/sync do nothing.' =>
            'Главный выключатель. Если выкл. — создание и синхронизация не работают.',
        'Root URL without trailing slash, e.g. https://redmine.example.org' =>
            'Корневой URL без слэша в конце, например https://redmine.example.org',
        'Service account key from Redmine → My account → API access key. Prefer a dedicated service user, not a personal key.' =>
            'Ключ сервисной УЗ: Redmine → Моя учётная запись → ключ API. Лучше отдельный сервисный пользователь, не личный ключ.',
        'How long OTRS waits for Redmine HTTP responses (create issue, sync).' =>
            'Сколько OTRS ждёт ответ Redmine по HTTP (создание задачи, синхронизация).',
        'Numeric Redmine project_id pre-selected in the escalate form. From URL /projects/NAME or projects.json (field id), e.g. 191.' =>
            'Числовой project_id Redmine, заранее выбранный в форме эскалации. Из URL /projects/... или projects.json (поле id), например 191.',
        'Numeric tracker_id (issue type) for new issues, e.g. Bug/Defect. From project settings or trackers.json.' =>
            'Числовой tracker_id (тип задачи) для новых issues. Инцидент=13, Дефект=15, Задача=1. Трекер должен быть включён в проекте.',
        'Optional. Numeric Redmine priority_id. Leave empty to use Redmine default priority.' =>
            'Необязательно. Числовой priority_id Redmine. Пусто — приоритет по умолчанию в Redmine.',
        'Optional text prepended to the Redmine issue subject. Leave empty in production; useful only for lab/pilot marking.' =>
            'Необязательный текст в начале темы задачи Redmine. В продуктиве оставьте пустым; удобно только для пометки пилота/лаба.',
        'Leave empty in production.' => 'В продуктиве оставьте пустым.',
        'When off (recommended): form loads only the default project and its trackers — fast. When on: full project list from Redmine — slower.' =>
            'Если выкл. (рекомендуется): в форме только проект по умолчанию и его трекеры — быстро. Если вкл.: полный список проектов — медленнее.',
        'Slower. When off, only the default project is loaded (cached).' =>
            'Медленнее. Если выкл. — только проект по умолчанию (с кэшем).',
        'How long project/tracker lists are cached in OTRS (default 900). Speeds up the escalate popup.' =>
            'Как долго списки проектов/трекеров кэшируются в OTRS (по умолчанию 900). Ускоряет всплывающее окно эскалации.',
        'Attach files when creating or linking a Redmine issue, and when a status-change note is imported from Redmine. Ticket correspondence is not copied to Redmine.' =>
            'Вложения — при создании или привязке задачи и при импорте заметки со сменой статуса из Redmine. Переписка тикета в Redmine не копируется.',
        'Daemon polls linked issues every 5 minutes for status, comments and attachments. Requires OTRS Daemon running.' =>
            'Daemon каждые 5 минут опрашивает связанные задачи: статус, комментарии, вложения. Нужен запущенный OTRS Daemon.',
        'Daemon retries tickets that failed to create a Redmine issue (every 10 minutes).' =>
            'Daemon повторяет тикеты, у которых не удалось создать задачу Redmine (каждые 10 минут).',
        'One rule per line: Redmine status name = OTRS state.' =>
            'По одной строке: имя статуса Redmine = состояние OTRS.',
        'Add |note to also write an internal OTRS note, e.g. Проверка решения = open|note' =>
            'Добавьте |note, чтобы писать внутреннюю заметку (статус + комментарий из того же журнала), например: Проверка решения = open|note',
        'Use note alone for a note without changing OTRS state. Status names must match Redmine exactly.' =>
            'Одно слово note — только заметка без смены состояния OTRS. Обычные комментарии Redmine без такой смены статуса в OTRS не копируются. Имена статусов — точно как в Redmine.',
        'One rule per line, e.g. Проверка решения = open|note' =>
            'По одной строке, например: Проверка решения = open|note',
        'Status sync lines: RedmineStatus = OTRSState or OTRSState|note or note' =>
            'Строки статусов: СтатусRedmine = СостояниеOTRS или СостояниеOTRS|note или note',
        'Connection'                 => 'Подключение',
        'Enable bridge'              => 'Включить мост',
        'Redmine base URL'           => 'Базовый URL Redmine',
        'Redmine API key'            => 'API-ключ Redmine',
        '(unchanged — enter a new key to replace)' =>
            '(не меняется — введите новый ключ, чтобы заменить)',
        'HTTP timeout (seconds)'     => 'Таймаут HTTP (сек.)',
        'Defaults for create form'   => 'Значения по умолчанию для формы создания',
        'Default project ID'         => 'ID проекта по умолчанию',
        'Default tracker ID'         => 'ID трекера по умолчанию',
        'Default priority ID'        => 'ID приоритета по умолчанию',
        'Subject prefix'             => 'Префикс темы',
        'Leave empty in production.' => 'В продуктиве оставьте пустым.',
        'Load all projects in form'  => 'Загружать все проекты в форме',
        'Slower. When off, only the default project is loaded (cached).' =>
            'Медленнее. Если выкл. — только проект по умолчанию (с кэшем).',
        'Catalog cache TTL (seconds)' => 'TTL кэша каталога (сек.)',
        'Synchronization'             => 'Синхронизация',
        'Sync attachments'            => 'Синхронизировать вложения',
        'Inbound sync (Redmine → OTRS)' => 'Входящая синхронизация (Redmine → OTRS)',
        'Auto-retry failed escalations' => 'Автоповтор неудачных эскалаций',
        'Status sync rules'           => 'Правила статусов',
        'One rule per line, e.g. Проверка решения = open|note' =>
            'По одной строке, например: Проверка решения = open|note',
        'Save' => 'Сохранить',
        'Test connection' => 'Проверить подключение',
        'Test project'    => 'Проверить проект',
        'Test tracker'    => 'Проверить трекер',
        'TLS diagnostics' => 'Диагностика TLS',
        'TLS diagnostics: OpenSSL/Perl SSL versions and a TLS handshake to Base URL (no API key). Use this when connection fails with handshake errors.' =>
            'Диагностика TLS: версии OpenSSL/Perl SSL и handshake к Base URL (без API-ключа). Нужна при ошибках handshake.',
        'Connection successful.' => 'Подключение успешно.',
        'Connection failed.' => 'Подключение не удалось.',
        'Check successful.' => 'Проверка успешна.',
        'Check failed.' => 'Проверка не удалась.',
        'Checks URL + API key via Redmine /users/current.json. Uses the key from the field above, or the saved key if the field is empty.' =>
            'Проверяет URL и API-ключ через Redmine /users/current.json. Берёт ключ из поля выше или сохранённый, если поле пустое.',
        'Checks URL + API key via Redmine /users/current.json. Uses the key from the field above, or the saved key if the field is empty. If project ID is set, also verifies access to that project.' =>
            'Проверяет URL и API-ключ через Redmine /users/current.json. Берёт ключ из поля выше или сохранённый, если поле пустое. Если задан ID проекта — дополнительно проверяет доступ к нему.',
        'Loads the project by ID and lists trackers enabled for it.' =>
            'Загружает проект по ID и показывает трекеры, включённые для него.',
        'If project ID is set, checks that this tracker is enabled for that project. Otherwise only checks that the tracker exists in Redmine.' =>
            'Если задан ID проекта — проверяет, что трекер включён в этом проекте. Иначе только что трекер существует в Redmine.',
        'If the test times out, the OTRS server cannot reach Redmine on HTTPS (firewall/DNS). Configure SysConfig WebUserAgent::Proxy when outbound traffic must go through a proxy.' =>
            'Если тест зависает по таймауту — сервер OTRS не достучится до Redmine по HTTPS (firewall/DNS). При выходе через proxy задайте SysConfig WebUserAgent::Proxy.',
        'Public OTRS URL (for Redmine links)' => 'Публичный URL OTRS (для ссылок в Redmine)',
        'Required for correct «OTRS Link» in Redmine. Example: https://otrs.example.org/otrs — then Save. Already created Redmine descriptions are not rewritten.' =>
            'Нужен для корректного «OTRS Link» в Redmine. Пример: https://otrs.example.org/otrs — затем Сохранить. Уже созданные описания в Redmine сами не переписываются.',
        'Link preview' => 'Превью ссылки',
        'Now empty → links use OTRS FQDN (often the server hostname, e.g. otrs-01).' =>
            'Сейчас пусто → в ссылках используется FQDN OTRS (часто hostname сервера, например otrs-01).',
        'Used in «OTRS Link» inside Redmine issues. Without trailing slash, e.g. https://otrs.example.org/otrs. Empty = HttpType+FQDN+ScriptAlias (hostname like otrs-01).' =>
            'Пишется в «OTRS Link» внутри задач Redmine. Без слэша в конце, например https://otrs.example.org/otrs. Пусто = HttpType+FQDN+ScriptAlias (часто hostname вроде otrs-01).',
        'Create new Redmine issue' => 'Создать новую задачу Redmine',
        'Link existing Redmine issue' => 'Привязать существующую задачу Redmine',
        'Link mode: attach this OTRS ticket to an already created Redmine issue (several tickets can share one issue).' =>
            'Режим привязки: связать этот тикет OTRS с уже созданной задачей Redmine (несколько тикетов могут ссылаться на одну задачу).',
        'Existing Redmine issue' => 'Существующая задача Redmine',
        'Issue ID or full URL. The issue must already exist; this ticket will be linked without creating a new one.' =>
            'ID задачи или полный URL. Задача должна уже существовать; новая не создаётся.',
        'I confirm linking this ticket to the existing Redmine issue' =>
            'Подтверждаю привязку этого тикета к существующей задаче Redmine',
        'Past Redmine comments will not be copied; only new activity will sync. A short note with the OTRS link is added to the Redmine issue.' =>
            'Старые комментарии Redmine не копируются; синхронизируется только новая активность. В задачу Redmine добавляется короткая заметка со ссылкой на OTRS (без штампа моста).',
        'Link Redmine issue' => 'Привязать задачу Redmine',
        'Please confirm linking to the existing issue.' => 'Подтвердите привязку к существующей задаче.',
        'Please enter Redmine issue ID or URL.' => 'Укажите ID или URL задачи Redmine.',
        'Could not link Redmine issue.' => 'Не удалось привязать задачу Redmine.',
        'Priority' => 'Приоритет',
        'Assignee' => 'Ответственный',
        'Redmine issue priority. Empty = Redmine default (or SysConfig Redmine::PriorityID).' =>
            'Приоритет задачи в Redmine. Пусто = приоритет по умолчанию Redmine (или SysConfig Redmine::PriorityID).',
        'Redmine project member to assign. Empty = unassigned.' =>
            'Участник проекта Redmine. Пусто = без ответственного.',
        'Required by Redmine for Инцидент (field «Назначена»).' =>
            'Обязательно для трекера «Инцидент» (поле «Назначена»).',
        'Due date' => 'Срок завершения',
        'Required by Redmine for Инцидент (field «Срок завершения»).' =>
            'Обязательно для трекера «Инцидент» (поле «Срок завершения»).',
        'Required by Redmine for Инцидент (field «Срок завершения»). Use the datepicker.' =>
            'Обязательно для трекера «Инцидент» (поле «Срок завершения»). Выберите дату в календаре.',
        'Mass incident' => 'Массовый инцидент',
        'Please choose mass incident: Yes or No.' =>
            'Укажите, является ли инцидент массовым: Да или Нет.',
        'Redmine field «Массовый инцидент».' =>
            'Поле Redmine «Массовый инцидент».',
        'Redmine custom field «Массовый инцидент» (id 84). Unchecked = no.' =>
            'Поле Redmine «Массовый инцидент» (id 84). Снятая галочка = нет.',
        'Please select an assignee.' => 'Выберите ответственного.',
        'Please fill in due date.' => 'Укажите срок завершения.',
        'Default due date (days from today)' => 'Срок завершения по умолчанию (дней от сегодня)',
        'Days from today for due_date on create (0 = today). Required by some trackers (e.g. Инцидент).' =>
            'Сколько дней прибавить к сегодняшней дате для due_date (0 = сегодня). Нужно для трекера «Инцидент».',
        'Default custom fields on create' => 'Custom fields по умолчанию при создании',
        'Default Redmine custom fields on create, one per line: id=value. Example: 84=0 (Массовый инцидент=нет).' =>
            'Custom fields Redmine при создании, по одному на строку: id=значение. Пример: 84=0 (Массовый инцидент=нет).',
        'Changing the project reloads available trackers and assignees.' =>
            'При смене проекта обновляются доступные трекеры и ответственные.',
        'Issue type (tracker) must be enabled for the selected project. Example: Инцидент = 13.' =>
            'Тип задачи (трекер) должен быть включён в выбранном проекте. Пример: Инцидент = 13.',
        'Attachments' => 'Вложения',
        'Attach selected files to the Redmine issue' =>
            'Прикрепить выбранные файлы к задаче Redmine',
        'Include ticket files' => 'Включить файлы из тикета',
        'Drop files here or click to upload' => 'Перетащите файлы сюда или нажмите для выбора',
        'Extra files will be attached to the Redmine issue only (not stored on the OTRS ticket).' =>
            'Дополнительные файлы уйдут только в задачу Redmine (в тикет OTRS не сохраняются).',
        'extra files go to Redmine only' => 'доп. файлы только в Redmine',
        'Uploading...' => 'Загрузка...',
        'Files ready to attach.' => 'Файлы готовы к прикреплению.',
        'File too large' => 'Файл слишком большой',
        'Upload failed' => 'Не удалось загрузить',
        'Remove' => 'Удалить',
        'Unchecked files will not be uploaded. Oversized files are listed but cannot be selected.' =>
            'Снятые с галочки файлы не загружаются. Слишком большие файлы показаны, но выбрать их нельзя.',
        'too large' => 'слишком большой',
        'Open' => 'Открыть',

        # Admin → Advanced
        'Advanced' => 'Дополнительно',
        'UI timeout (seconds)' => 'Таймаут UI (секунды)',
        'Short timeout for escalate popup catalog calls (default 5). Daemon keeps using HTTP timeout above.' =>
            'Короткий таймаут для загрузки списков в окне эскалации (по умолчанию 5). Daemon по-прежнему использует HTTP-таймаут выше.',
        'Allow legacy TLS' => 'Разрешить устаревший TLS',
        'Only if Redmine cannot negotiate TLS 1.2+. Prefer fixing the server; leave off in production.' =>
            'Только если Redmine не может согласовать TLS 1.2+. Лучше исправить сервер; в проде оставляйте выключенным.',
        'SSL version strategy' => 'Стратегия версии SSL',
        'Perl SSL strategy: auto, or explicit IO::Socket::SSL SSL_version e.g. TLSv1_2.' =>
            'Стратегия SSL в Perl: auto или явное SSL_version для IO::Socket::SSL, например TLSv1_2.',
        'Incident tracker' => 'Трекер «Инцидент»',
        'Redmine tracker for «Инцидент». Escalation form requires mass-incident Yes/No for this tracker.' =>
            'Трекер Redmine для «Инцидент». В форме эскалации для него обязательно Да/Нет по «Массовый инцидент».',
        'Allowed projects (Create)' => 'Разрешённые проекты (создание)',
        'Projects allowed when creating a Redmine issue. Linking an existing issue works from any project. Empty = only the default project.' =>
            'Проекты, в которых разрешено создавать задачи Redmine. Привязка к существующей задаче — из любого проекта. Пусто = только проект по умолчанию.',
        'Max attachment bytes' => 'Макс. размер вложения (байты)',
        'Max attachment size to sync (bytes). Default 5000000.' =>
            'Максимальный размер вложения для синхронизации (байты). По умолчанию 5000000.',
        'Sync batch limit' => 'Лимит пакета синхронизации',
        'Max tickets per inbound sync cron run.' =>
            'Максимум тикетов за один запуск входящей синхронизации (cron).',
        'Retry batch limit' => 'Лимит пакета повторов',
        'Max tickets per auto-retry cron run.' =>
            'Максимум тикетов за один запуск автоповтора (cron).',
        'Timeouts and TLS' => 'Таймауты и TLS',
        'Incident and create' => 'Инцидент и создание',
        'Limits' => 'Лимиты',
        'Access and defaults' => 'Доступ и значения по умолчанию',
        'Agent group' => 'Группа агентов',
        'If set, only members of this OTRS group may open the escalate dialog. Empty = any agent with ticket permission.' =>
            'Если задано — диалог эскалации только для членов этой группы OTRS. Пусто = любой агент с правом на тикет.',
        'Redmine lists' => 'Списки Redmine',
        'Reload lists from Redmine' => 'Обновить списки из Redmine',
        'Lists below are filled from Redmine (cached). Reload after changing URL/API key or when trackers change.' =>
            'Списки ниже заполняются из Redmine (с кэшем). Обновите после смены URL/API-ключа или трекеров.',
        'Could not load lists yet — check connection, then click Reload.' =>
            'Списки пока не загрузились — проверьте подключение и нажмите «Обновить».',
        'Lists reloaded from Redmine.' => 'Списки обновлены из Redmine.',
        'Could not load lists from Redmine.' => 'Не удалось загрузить списки из Redmine.',
        'Default project' => 'Проект по умолчанию',
        'Pre-selected Redmine project in the escalate form.' =>
            'Проект Redmine, заранее выбранный в форме эскалации.',
        'Default tracker' => 'Трекер по умолчанию',
        'Issue type for new issues. List is filtered by the selected project when possible.' =>
            'Тип задачи для новых issues. Список по возможности фильтруется по выбранному проекту.',
        'Default priority' => 'Приоритет по умолчанию',
        'Optional. Empty = Redmine default priority.' =>
            'Необязательно. Пусто = приоритет по умолчанию в Redmine.',
        'Subject prefix' => 'Префикс темы',
        'Test project' => 'Проверить проект',
        'Test tracker' => 'Проверить трекер',
        'Run sync now' => 'Запустить синхронизацию',
        'Inbound sync finished.' => 'Входящая синхронизация завершена.',
        'Inbound sync failed.' => 'Входящая синхронизация не удалась.',
        'Defaults for create form' => 'Значения по умолчанию для формы создания',
    );

    for my $Key ( keys %Trans ) {
        $Self->{Translation}->{$Key} = $Trans{$Key};
    }

    return 1;
}

1;
