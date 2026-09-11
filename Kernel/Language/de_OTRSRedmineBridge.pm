# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
package Kernel::Language::de_OTRSRedmineBridge;

use strict;
use warnings;
use utf8;

sub Data {
    my $Self = shift;

    my %Trans = (
        'Create Redmine issue' => 'Redmine-Ticket erstellen',
        'Create a linked Redmine issue for this ticket' =>
            'Verknüpftes Redmine-Ticket für dieses Ticket erstellen',
        'Could not create Redmine issue.' => 'Redmine-Ticket konnte nicht erstellt werden.',
        'Redmine issue already linked: #%s' => 'Redmine-Ticket bereits verknüpft: #%s',
        'Already linked'                    => 'Bereits verknüpft',
        'Open in Redmine'                   => 'In Redmine öffnen',
        'Redmine URL'                       => 'Redmine-URL',
        'Actions'                           => 'Aktionen',
        'Redmine sync'                      => 'Redmine-Sync',
        'Already linked — details and sync from Redmine' =>
            'Bereits verknüpft — Details und Sync aus Redmine',
        'Open linked Redmine issue in a new tab' =>
            'Verknüpftes Redmine-Ticket in neuem Tab öffnen',
        'Sync from Redmine now'             => 'Jetzt aus Redmine synchronisieren',
        'Synced from Redmine.'              => 'Synchronisation aus Redmine abgeschlossen.',
        'Could not sync from Redmine.'      => 'Synchronisation aus Redmine fehlgeschlagen.',
        'No Redmine issue is linked to this ticket.' =>
            'Mit diesem Ticket ist kein Redmine-Ticket verknüpft.',
        'Other linked OTRS tickets'         => 'Weitere verknüpfte OTRS-Tickets',
        'No other OTRS tickets are linked to this Redmine issue.' =>
            'Keine weiteren OTRS-Tickets sind mit diesem Redmine-Ticket verknüpft.',
        'Unlink from Redmine'               => 'Von Redmine trennen',
        'I confirm unlinking this ticket from Redmine' =>
            'Ich bestätige das Trennen dieses Tickets von Redmine',
        'Unlink'                            => 'Trennen',
        'Relink to another Redmine issue'   => 'Mit anderem Redmine-Ticket neu verknüpfen',
        'I confirm relinking to another Redmine issue' =>
            'Ich bestätige die Neuverknüpfung mit einem anderen Redmine-Ticket',
        'Relink'                            => 'Neu verknüpfen',
        'Redmine issue ID or URL'           => 'Redmine-Ticket-ID oder URL',
        'Please confirm unlinking from the Redmine issue.' =>
            'Bitte bestätigen Sie das Trennen vom Redmine-Ticket.',
        'Please confirm relinking to another Redmine issue.' =>
            'Bitte bestätigen Sie die Neuverknüpfung.',
        'Please enter Redmine issue ID or URL.' =>
            'Bitte Redmine-Ticket-ID oder URL eingeben.',
        'Could not unlink Redmine issue.'   => 'Redmine-Verknüpfung konnte nicht getrennt werden.',
        'Could not relink Redmine issue.'   => 'Neuverknüpfung fehlgeschlagen.',
        'Unlinked from Redmine.'            => 'Von Redmine getrennt.',
        'Relinked to Redmine.'              => 'Neu mit Redmine verknüpft.',
        'Redmine issue #%s is no longer linked.' =>
            'Redmine-Ticket #%s ist nicht mehr verknüpft.',
        'Notify on status note'             => 'Benachrichtigung bei Statusnotiz',
        'When a Redmine status change writes an OTRS note (|note, e.g. Проверка решения), notify the ticket owner and responsible.' =>
            'Wenn eine Redmine-Statusänderung eine OTRS-Notiz schreibt (|note), Owner und Responsible benachrichtigen.',
        'Open linked Redmine issue'         => 'Verknüpftes Redmine-Ticket öffnen',
        'Redmine project'                   => 'Redmine-Projekt',
        'Redmine tracker'                   => 'Redmine-Tracker',
        'Issue subject'                     => 'Ticket-Betreff',
        'Issue description'                 => 'Ticket-Beschreibung',
        'Please fill in subject and description.' =>
            'Bitte Betreff und Beschreibung ausfüllen.',
        'All fields marked with an asterisk (*) are mandatory.' =>
            'Alle mit einem Stern (*) markierten Felder sind Pflichtfelder.',
        'Confirmation'                      => 'Bestätigung',
        'I confirm creating a new Redmine issue for this ticket' =>
            'Ich bestätige die Erstellung eines neuen Redmine-Tickets für dieses Ticket',
        'Please confirm issue creation.' => 'Bitte bestätigen Sie die Erstellung.',
        'Please select project and tracker.' => 'Bitte Projekt und Tracker wählen.',
        'Could not load Redmine projects' => 'Redmine-Projekte konnten nicht geladen werden',
        'A Redmine issue will be created and linked to this OTRS ticket. This action cannot be undone from OTRS.' =>
            'Es wird ein Redmine-Ticket erstellt und mit diesem OTRS-Ticket verknüpft. Dies kann in OTRS nicht rückgängig gemacht werden.',
        'Cancel' => 'Abbrechen',
        'OTRS ↔ Redmine Bridge' => 'OTRS ↔ Redmine-Brücke',
        'Configure Redmine connection, sync and status rules.' =>
            'Redmine-Verbindung, Sync und Statusregeln konfigurieren.',
        'Settings saved and deployed.' => 'Einstellungen gespeichert und übernommen.',
        'Could not save settings.'     => 'Einstellungen konnten nicht gespeichert werden.',
        'Enable bridge'                => 'Brücke aktivieren',
        'Redmine base URL'             => 'Redmine-Basis-URL',
        'Redmine API key'              => 'Redmine-API-Schlüssel',
        'Save'                         => 'Speichern',
        'Test connection'              => 'Verbindung prüfen',
        'Test project'                 => 'Projekt prüfen',
        'Test tracker'                 => 'Tracker prüfen',
        'Connection successful.'       => 'Verbindung erfolgreich.',
        'Connection failed.'           => 'Verbindung fehlgeschlagen.',
        'Check successful.'            => 'Prüfung erfolgreich.',
        'Check failed.'                => 'Prüfung fehlgeschlagen.',
        'Synchronization'              => 'Synchronisation',
        'Status sync rules'            => 'Status-Sync-Regeln',
    );

    for my $Key ( keys %Trans ) {
        $Self->{Translation}->{$Key} = $Trans{$Key};
    }

    return 1;
}

1;
