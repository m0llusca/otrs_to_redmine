# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Redmine::Issue;

use strict;
use warnings;
use utf8;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
    'Kernel::System::DateTime',
    'Kernel::System::JSON',
    'Kernel::System::Log',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
    'Kernel::System::User',
    'Kernel::System::Web::UploadCache',
);

# ---------------------------------------------------------------------------
# Escalate / Link / Create
# ---------------------------------------------------------------------------

sub EscalateTicket {
    my ( $Self, %Param ) = @_;

    for my $Needed (qw(TicketID UserID)) {
        return ( Success => 0, Status => 'error', Error => "Need $Needed" ) if !$Param{$Needed};
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    if ( !$ConfigObject->Get('Redmine::Enabled') ) {
        return (
            Success => 0,
            Status  => 'error',
            Error   => 'Redmine bridge is disabled (Redmine::Enabled)',
        );
    }

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my %Ticket       = $TicketObject->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $Param{UserID},
        Silent        => 1,
    );
    return ( Success => 0, Status => 'error', Error => 'Ticket not found' ) if !%Ticket;

    if ( IsStringWithData( $Ticket{DynamicField_RedmineID} ) ) {
        return (
            Success => 1,
            Status  => 'linked',
            IssueID => $Ticket{DynamicField_RedmineID},
            URL     => $Ticket{DynamicField_RedmineURL} || '',
        );
    }

    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $LockKey     = 'EscalateLock::' . $Param{TicketID};
    if (
        $CacheObject->Get(
            Type => 'RedmineBridge',
            Key  => $LockKey,
        )
        )
    {
        return (
            Success => 0,
            Status  => 'error',
            Error   => 'Escalation already in progress',
        );
    }
    $CacheObject->Set(
        Type  => 'RedmineBridge',
        Key   => $LockKey,
        Value => 1,
        TTL   => 120,
    );

    my $ClearLock = sub {
        $CacheObject->Delete(
            Type => 'RedmineBridge',
            Key  => $LockKey,
        );
    };

    # Re-read RedmineID before create (cross-process race).
    my %TicketFresh = $TicketObject->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $Param{UserID},
        Silent        => 1,
    );
    if ( IsStringWithData( $TicketFresh{DynamicField_RedmineID} ) ) {
        $ClearLock->();
        return (
            Success => 1,
            Status  => 'linked',
            IssueID => $TicketFresh{DynamicField_RedmineID},
            URL     => $TicketFresh{DynamicField_RedmineURL} || '',
        );
    }

    my $ProjectID = $Param{ProjectID} // $ConfigObject->Get('Redmine::ProjectID');
    my $TrackerID = $Param{TrackerID} // $ConfigObject->Get('Redmine::TrackerID');

    if ( !$Self->_IsAllowedRedmineProjectID($ProjectID) ) {
        $ClearLock->();
        return (
            Success => 0,
            Status  => 'error',
            Error   => 'Проект Redmine #'
                . ( $ProjectID // '?' )
                . ' не разрешён для создания задачи (Redmine::AllowedProjectIDs / Redmine::ProjectID).',
        );
    }

    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineEscalationStatus',
        Value    => 'pending',
        UserID   => $Param{UserID},
    );

    my %User = $Kernel::OM->Get('Kernel::System::User')->GetUserData( UserID => $Param{UserID} );
    my $AgentLabel = $User{UserLogin} || $Param{UserID};

    my $Body = $Param{Description};
    if ( !IsStringWithData($Body) ) {
        $Body = $Self->_BuildDescription( %Ticket, AgentLabel => $AgentLabel );
    }
    else {
        $Body =~ s{\s+\z}{};
    }

    my $Subject = $Param{Subject};
    if ( !IsStringWithData($Subject) ) {
        my $Prefix = $ConfigObject->Get('Redmine::SubjectPrefix') || '';
        $Prefix =~ s{\s+\z}{};
        $Subject = '';
        $Subject .= "$Prefix " if length $Prefix;
        $Subject .= "[OTRS#$Ticket{TicketNumber}] $Ticket{Title}";
    }
    else {
        $Subject =~ s{\A\s+}{};
        $Subject =~ s{\s+\z}{};
    }
    $Subject = substr( $Subject, 0, 250 );

    if ( !length $Subject || !length $Body ) {
        $ClearLock->();
        return (
            Success => 0,
            Status  => 'error',
            Error   => 'Subject and Description are required',
        );
    }

    # Persist retry payload for AutoRetry / CronRetry (JSON object DF).
    eval {
        my $PayloadJSON = $Kernel::OM->Get('Kernel::System::JSON')->Encode(
            Data => {
                AssignedToID       => $Param{AssignedToID},
                DueDate            => $Param{DueDate},
                PriorityID         => $Param{PriorityID},
                MassIncident       => $Param{MassIncident},
                Subject            => $Subject,
                Description        => $Body,
                ProjectID          => $ProjectID,
                TrackerID          => $TrackerID,
                IncludeAttachments => $Param{IncludeAttachments},
            },
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineRetryPayload',
            Value    => $PayloadJSON // '',
            UserID   => $Param{UserID},
        );
        1;
    };

    # Collect file bytes only — mint Redmine upload tokens after create+fix.
    my @PendingUploads = (
        $Self->_CollectEscalateUploadFiles(
            TicketID           => $Param{TicketID},
            IncludeAttachments => $Param{IncludeAttachments},
            AttachmentKeys     => $Param{AttachmentKeys},
        ),
        $Self->_CollectFormIDUploadFiles(
            FormID => $Param{FormID},
        ),
    );

    my %Create = eval {
        $Self->CreateIssue(
            Subject        => $Subject,
            Description    => $Body,
            ProjectID      => $ProjectID,
            TrackerID      => $TrackerID,
            PriorityID     => $Param{PriorityID},
            AssignedToID   => $Param{AssignedToID},
            DueDate        => $Param{DueDate},
            MassIncident   => $Param{MassIncident},
            PendingUploads => \@PendingUploads,
        );
    };
    if ($@) {
        my $Die = $@;
        $Die =~ s{\s+at\s+\S+.*}{}s;
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Redmine CreateIssue died: $Die",
        );
        eval {
            $Self->_EscalateFailureRecord(
                TicketID  => $Param{TicketID},
                UserID    => $Param{UserID},
                ProjectID => $ProjectID,
                TrackerID => $TrackerID,
                Error     => "CreateIssue failed: $Die",
            );
            1;
        };
        $ClearLock->();
        return ( Success => 0, Status => 'error', Error => "CreateIssue failed: $Die" );
    }

    if ( !$Create{Success} ) {
        eval {
            # Orphan / partial issue may already exist — still store the link.
            if ( IsNumber( $Create{IssueID} ) ) {
                $Self->_SetDF(
                    TicketID => $Param{TicketID},
                    Name     => 'RedmineID',
                    Value    => "$Create{IssueID}",
                    UserID   => $Param{UserID},
                );
                $Self->_SetDF(
                    TicketID => $Param{TicketID},
                    Name     => 'RedmineURL',
                    Value    => $Create{URL} || '',
                    UserID   => $Param{UserID},
                );
            }
            $Self->_EscalateFailureRecord(
                TicketID  => $Param{TicketID},
                UserID    => $Param{UserID},
                ProjectID => $ProjectID,
                TrackerID => $TrackerID,
                Error     => $Create{Error} || 'unknown',
            );
            1;
        };
        $ClearLock->();
        return (
            Success => 0,
            Status  => 'error',
            Error   => $Create{Error} || 'unknown',
            (
                IsNumber( $Create{IssueID} )
                ? ( IssueID => $Create{IssueID}, URL => $Create{URL} )
                : ()
            ),
        );
    }

    # Remote issue already exists — never let local bookkeeping throw a 500.
    eval {
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineID',
            Value    => "$Create{IssueID}",
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineURL',
            Value    => $Create{URL},
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineEscalationStatus',
            Value    => 'created',
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineLastError',
            Value    => '',
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineProjectID',
            Value    => "$ProjectID",
            UserID   => $Param{UserID},
        ) if IsNumber($ProjectID);
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineTrackerID',
            Value    => "$TrackerID",
            UserID   => $Param{UserID},
        ) if IsNumber($TrackerID);

        $Self->_AddInternalArticle(
            TicketID       => $Param{TicketID},
            UserID         => $Param{UserID},
            Subject        => "Redmine: создана задача #$Create{IssueID}",
            Body           => "Агент: $AgentLabel\nСоздана задача Redmine #$Create{IssueID}.\nСсылка: $Create{URL}"
                . (
                length( $Create{Warning} // '' )
                ? "\n\nВнимание: $Create{Warning}"
                : ''
                ),
            HistoryComment => '%%RedmineBridge',
        );

        $TicketObject->HistoryAdd(
            Name         => "Redmine issue #$Create{IssueID} created by $AgentLabel",
            HistoryType  => 'Misc',
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
        );

        # Seed sync cursors so create-time uploads / description journals are not re-imported.
        $Self->_BumpLastJournalID(
            TicketID => $Param{TicketID},
            IssueID  => $Create{IssueID},
            UserID   => $Param{UserID},
        );
        $Self->_BumpLastAttachmentID(
            TicketID => $Param{TicketID},
            IssueID  => $Create{IssueID},
            UserID   => $Param{UserID},
        );
        1;
    };
    if ($@) {
        my $Die = $@;
        $Die =~ s{\s+at\s+\S+.*}{}s;
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Redmine escalate bookkeeping failed after issue #$Create{IssueID}: $Die",
        );
        eval {
            $Self->_SetDF(
                TicketID => $Param{TicketID},
                Name     => 'RedmineID',
                Value    => "$Create{IssueID}",
                UserID   => $Param{UserID},
            );
            $Self->_SetDF(
                TicketID => $Param{TicketID},
                Name     => 'RedmineURL',
                Value    => $Create{URL},
                UserID   => $Param{UserID},
            );
            1;
        };
    }

    $ClearLock->();
    return (
        Success => 1,
        Status  => 'created',
        IssueID => $Create{IssueID},
        URL     => $Create{URL},
        (
            length( $Create{Warning} // '' )
            ? ( Warning => $Create{Warning} )
            : ()
        ),
    );
}

# Link this OTRS ticket to an existing Redmine issue (no create). Enables N tickets → 1 issue.
sub LinkTicketToIssue {
    my ( $Self, %Param ) = @_;

    for my $Needed (qw(TicketID UserID IssueID)) {
        return ( Success => 0, Status => 'error', Error => "Need $Needed" ) if !$Param{$Needed};
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    if ( !$ConfigObject->Get('Redmine::Enabled') ) {
        return (
            Success => 0,
            Status  => 'error',
            Error   => 'Redmine bridge is disabled (Redmine::Enabled)',
        );
    }

    my $IssueID = $Self->ParseIssueID( $Param{IssueID} );
    return (
        Success => 0,
        Status  => 'error',
        Error   => 'Некорректный ID или URL задачи Redmine',
    ) if !IsNumber($IssueID);

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my %Ticket       = $TicketObject->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $Param{UserID},
        Silent        => 1,
    );
    return ( Success => 0, Status => 'error', Error => 'Ticket not found' ) if !%Ticket;

    if ( IsStringWithData( $Ticket{DynamicField_RedmineID} ) ) {
        return (
            Success => 1,
            Status  => 'linked',
            IssueID => $Ticket{DynamicField_RedmineID},
            URL     => $Ticket{DynamicField_RedmineURL} || '',
        );
    }

    my %Res = $Self->_Request(
        Method => 'GET',
        Path   => "/issues/$IssueID.json?include=journals,attachments",
    );
    return ( Success => 0, Status => 'error', Error => $Res{Error} || 'Issue not found' )
        if !$Res{Success};

    my $Issue = $Res{Data}->{issue} || {};
    return (
        Success => 0,
        Status  => 'error',
        Error   => 'Redmine response missing issue',
    ) if !IsHashRefWithData($Issue);

    # Link/relink: any Redmine project is allowed (create stays gated by AllowedProjectIDs).

    my $URL = ( $Res{BaseURL} || $ConfigObject->Get('Redmine::BaseURL') || '' );
    $URL =~ s{/\z}{};
    $URL .= "/issues/$IssueID";

    # Seed cursors from one include=journals,attachments response (no second GET).
    my $MaxJournal = 0;
    for my $Journal ( @{ $Issue->{journals} || [] } ) {
        my $JID = 0 + ( $Journal->{id} || 0 );
        $MaxJournal = $JID if $JID > $MaxJournal;
    }
    my $MaxAtt = 0;
    for my $Att ( @{ $Issue->{attachments} || [] } ) {
        my $AID = 0 + ( $Att->{id} || 0 );
        $MaxAtt = $AID if $AID > $MaxAtt;
    }

    my %User = $Kernel::OM->Get('Kernel::System::User')->GetUserData( UserID => $Param{UserID} );
    my $AgentLabel = $User{UserLogin} || $Param{UserID};

    # Link is local DFs only — do not write a Redmine journal comment.
    eval {
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineID',
            Value    => "$IssueID",
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineURL',
            Value    => $URL,
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineEscalationStatus',
            Value    => 'linked',
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineLastError',
            Value    => '',
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineStatus',
            Value    => $Issue->{status}->{name} || '',
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineLastJournalID',
            Value    => "$MaxJournal",
            UserID   => $Param{UserID},
        );
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineLastAttachmentID',
            Value    => "$MaxAtt",
            UserID   => $Param{UserID},
        );
        if ( IsNumber( $Issue->{project}->{id} ) ) {
            $Self->_SetDF(
                TicketID => $Param{TicketID},
                Name     => 'RedmineProjectID',
                Value    => '' . $Issue->{project}->{id},
                UserID   => $Param{UserID},
            );
        }
        if ( IsNumber( $Issue->{tracker}->{id} ) ) {
            $Self->_SetDF(
                TicketID => $Param{TicketID},
                Name     => 'RedmineTrackerID',
                Value    => '' . $Issue->{tracker}->{id},
                UserID   => $Param{UserID},
            );
        }
        1;
    } or do {
        my $Err = $@ || 'DF update failed';
        $Err =~ s{\s+at\s+\S+.*}{}s;
        return (
            Success => 0,
            Status  => 'error',
            IssueID => $IssueID,
            URL     => $URL,
            Error   => "Задача #$IssueID найдена, но поля связи в OTRS не записались: $Err",
        );
    };

    eval {
        $Self->_AddInternalArticle(
            TicketID       => $Param{TicketID},
            UserID         => $Param{UserID},
            Subject        => "Redmine: связана задача #$IssueID",
            Body           => "Агент: $AgentLabel\nТикет связан с существующей задачей Redmine #$IssueID.\n"
                . "Тема: "
                . ( $Issue->{subject} || '-' ) . "\n"
                . "Ссылка: $URL",
            HistoryComment => '%%RedmineBridge',
        );
        $TicketObject->HistoryAdd(
            Name         => "Redmine issue #$IssueID linked by $AgentLabel",
            HistoryType  => 'Misc',
            TicketID     => $Param{TicketID},
            CreateUserID => $Param{UserID},
        );
        1;
    };

    return ( Success => 1, Status => 'linked', IssueID => $IssueID, URL => $URL );
}

# Clear local Redmine link DFs; best-effort note on the Redmine issue.
sub UnlinkTicketFromIssue {
    my ( $Self, %Param ) = @_;

    for my $Needed (qw(TicketID UserID)) {
        return ( Success => 0, Status => 'error', Error => "Need $Needed" ) if !$Param{$Needed};
    }

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my %Ticket       = $TicketObject->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $Param{UserID},
        Silent        => 1,
    );
    return ( Success => 0, Status => 'error', Error => 'Ticket not found' ) if !%Ticket;

    my $IssueID = $Ticket{DynamicField_RedmineID} // '';
    if ( !IsStringWithData($IssueID) ) {
        return ( Success => 1, Status => 'unlinked', IssueID => '' );
    }

    my %User = $Kernel::OM->Get('Kernel::System::User')->GetUserData( UserID => $Param{UserID} );
    my $AgentLabel = $User{UserLogin} || $Param{UserID};

    # Local unlink only — do not write a Redmine journal comment.
    for my $Name (
        qw(
            RedmineID RedmineURL RedmineStatus RedmineLastError
            RedmineLastJournalID RedmineLastAttachmentID
            RedmineLastUpdatedOn RedmineLastSyncAt
            RedmineProjectID RedmineTrackerID
        )
        )
    {
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => $Name,
            Value    => '',
            UserID   => $Param{UserID},
        );
    }
    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineEscalationStatus',
        Value    => 'none',
        UserID   => $Param{UserID},
    );

    $Self->_AddInternalArticle(
        TicketID       => $Param{TicketID},
        UserID         => $Param{UserID},
        Subject        => "Redmine: отвязана задача #$IssueID",
        Body           => "Агент: $AgentLabel\nТикет отвязан от задачи Redmine #$IssueID.",
        HistoryComment => '%%RedmineBridge',
    );
    $TicketObject->HistoryAdd(
        Name         => "Redmine issue #$IssueID unlinked by $AgentLabel",
        HistoryType  => 'Misc',
        TicketID     => $Param{TicketID},
        CreateUserID => $Param{UserID},
    );

    return ( Success => 1, Status => 'unlinked', IssueID => $IssueID );
}

sub RelinkTicketToIssue {
    my ( $Self, %Param ) = @_;

    for my $Needed (qw(TicketID UserID IssueID)) {
        return ( Success => 0, Status => 'error', Error => "Need $Needed" ) if !$Param{$Needed};
    }

    my $NewID = $Self->ParseIssueID( $Param{IssueID} );
    return ( Success => 0, Status => 'error', Error => 'Invalid Redmine issue ID or URL' )
        if !IsNumber($NewID);

    my %Ticket = $Kernel::OM->Get('Kernel::System::Ticket')->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $Param{UserID},
        Silent        => 1,
    );
    my $OldID = $Ticket{DynamicField_RedmineID} // '';
    if ( IsStringWithData($OldID) && ( 0 + $OldID ) == ( 0 + $NewID ) ) {
        return (
            Success => 1,
            Status  => 'linked',
            IssueID => $NewID,
            URL     => $Ticket{DynamicField_RedmineURL} || '',
        );
    }

    if ( IsStringWithData($OldID) ) {
        my %Un = $Self->UnlinkTicketFromIssue(
            TicketID => $Param{TicketID},
            UserID   => $Param{UserID},
        );
        return %Un if !$Un{Success};
    }

    return $Self->LinkTicketToIssue(
        TicketID => $Param{TicketID},
        UserID   => $Param{UserID},
        IssueID  => $NewID,
    );
}

sub CreateIssue {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    for my $Needed (qw(Subject Description)) {
        return ( Success => 0, Error => "Need $Needed" )
            if !defined $Param{$Needed} || !length $Param{$Needed};
    }

    my $ProjectID    = $Param{ProjectID}  // $ConfigObject->Get('Redmine::ProjectID');
    my $TrackerID    = $Param{TrackerID}  // $ConfigObject->Get('Redmine::TrackerID');
    my $PriorityID   = $Param{PriorityID} // $ConfigObject->Get('Redmine::PriorityID');
    my $AssignedToID = $Param{AssignedToID};
    my $DueDate      = $Param{DueDate};

    return ( Success => 0, Error => 'Redmine::ProjectID and Redmine::TrackerID must be numeric' )
        if !IsNumber($ProjectID) || !IsNumber($TrackerID);

    if ( !$Self->_IsAllowedRedmineProjectID($ProjectID) ) {
        return (
            Success => 0,
            Error   => 'Проект Redmine #'
                . $ProjectID
                . ' не разрешён для создания задачи (Redmine::AllowedProjectIDs / Redmine::ProjectID).',
        );
    }

    # Инцидент: if priority empty, use Redmine default (is_default) — some roles
    # no-op tracker changes when priority_id is omitted from the payload.
    if ( !IsNumber($PriorityID) || !$PriorityID ) {
        my %PrioRes = $Self->ListPriorities();
        if ( $PrioRes{Success} ) {
            my ($DefaultPrio)
                = grep { $_->{is_default} } @{ $PrioRes{Priorities} || [] };
            $PriorityID = $DefaultPrio->{id} if $DefaultPrio && IsNumber( $DefaultPrio->{id} );
        }
        $PriorityID = 2 if !IsNumber($PriorityID) || !$PriorityID;    # Redmine default priority id
    }

    # Redmine silently remaps tracker_id that is not enabled for the project.
    my %TrackersRes = $Self->ListTrackers( ProjectID => $ProjectID );
    if ( $TrackersRes{Success} ) {
        my @Trackers = @{ $TrackersRes{Trackers} || [] };
        my ($Hit) = grep { ( 0 + ( $_->{id} // 0 ) ) == ( 0 + $TrackerID ) } @Trackers;
        if ( !$Hit ) {
            my $Available = join ', ', map {
                ( $_->{name} // '?' ) . ' (#' . ( $_->{id} // '?' ) . ')'
            } @Trackers;
            $Available ||= '(none)';
            return (
                Success => 0,
                Error   => "Tracker #$TrackerID is not enabled for project #$ProjectID. Available: $Available",
            );
        }
    }

    if ( !IsNumber($AssignedToID) || !$AssignedToID ) {
        return (
            Success => 0,
            Error   => 'Assignee is required (Redmine field «Назначена»). Select a project member.',
        );
    }

    $DueDate = $Self->_NormalizeDueDate($DueDate);
    if ( !length $DueDate ) {
        $DueDate = $Self->DefaultDueDate();
    }
    if ( !length $DueDate ) {
        return (
            Success => 0,
            Error   => 'Due date is required (Redmine field «Срок завершения»).',
        );
    }

    my $IncidentTrackerID = $ConfigObject->Get('Redmine::IncidentTrackerID') // 13;
    my $WantIncident
        = ( IsNumber($IncidentTrackerID) && ( 0 + $TrackerID ) == ( 0 + $IncidentTrackerID ) )
        ? 1
        : 0;

    my @CustomFields = $Self->_BuildCustomFields(
        %Param,
        TrackerID    => $TrackerID,
        WantIncident => $WantIncident,
    );

    # CF 84 «Массовый инцидент» ONLY for incident tracker.
    my $MassValue = '0';
    if ( exists $Param{MassIncident} && defined $Param{MassIncident} ) {
        $MassValue = ( $Param{MassIncident} && $Param{MassIncident} ne '0' ) ? '1' : '0';
    }
    if ($WantIncident) {
        my $Has84 = 0;
        for my $CF (@CustomFields) {
            next if !IsHashRefWithData($CF) || !IsNumber( $CF->{id} ) || ( 0 + $CF->{id} ) != 84;
            $Has84 = 1;
            my $V = $CF->{value};
            if ( !defined $V || $V =~ m{\A\s*\z} ) {
                $CF->{value} = $MassValue;
            }
            elsif ( $V eq '1' || $V eq 'Да' || lc($V) eq 'yes' || lc($V) eq 'true' ) {
                $CF->{value} = '1';
            }
            else {
                $CF->{value} = '0';
            }
            $MassValue = $CF->{value};
        }
        if ( !$Has84 ) {
            push @CustomFields, { id => 84, value => $MassValue };
        }
    }
    else {
        @CustomFields = grep {
            !( IsHashRefWithData($_) && IsNumber( $_->{id} ) && ( 0 + $_->{id} ) == 84 )
        } @CustomFields;
    }

    my @PendingUploads;
    if ( IsArrayRefWithData( $Param{PendingUploads} ) ) {
        @PendingUploads = @{ $Param{PendingUploads} };
    }
    elsif ( IsArrayRefWithData( $Param{Uploads} ) ) {

        # Legacy: already-minted tokens (outbound sync still uses this shape).
        @PendingUploads = map {
            IsHashRefWithData($_) && $_->{token}
                ? { TokenReady => 1, %$_ }
                : ()
        } @{ $Param{Uploads} };
    }

    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'notice',
        Message  => sprintf(
            'Redmine CreateIssue project=%s tracker=%s assignee=%s due=%s priority=%s cf=[%s] pending_files=%d',
            $ProjectID,
            $TrackerID,
            $AssignedToID,
            $DueDate,
            ( IsNumber($PriorityID) ? $PriorityID : '-' ),
            join(
                ',',
                map { ( $_->{id} // '?' ) . '=' . ( $_->{value} // '' ) } @CustomFields
            ),
            scalar @PendingUploads,
        ),
    );

    my %Issue = (
        project_id     => 0 + $ProjectID,
        tracker_id     => 0 + $TrackerID,
        subject        => $Param{Subject},
        description    => $Param{Description},
        assigned_to_id => 0 + $AssignedToID,
        due_date       => $DueDate,
    );
    $Issue{priority_id}   = 0 + $PriorityID if IsNumber($PriorityID) && $PriorityID;
    $Issue{custom_fields} = \@CustomFields if @CustomFields;

    my %Res = $Self->_Request(
        Method => 'POST',
        Path   => '/issues.json',
        JSON   => { issue => \%Issue },
    );
    if ( !$Res{Success} ) {
        return ( Success => 0, Error => $Self->_FormatRedmineAPIError(%Res) );
    }

    my $Created = $Res{Data}->{issue} || {};
    my $IssueID = $Created->{id};
    return ( Success => 0, Error => 'Redmine response missing issue.id' ) if !IsNumber($IssueID);

    my %Check = $Self->_Request( Method => 'GET', Path => "/issues/$IssueID.json" );
    if ( $Check{Success} ) {
        $Created = $Check{Data}->{issue} || $Created;
    }
    my $GotTracker = $Created->{tracker}->{id};

    # NeedFix only on tracker mismatch OR (WantIncident && CF84 missing/wrong).
    my $NeedFix = 0;
    if ( !IsNumber($GotTracker) || ( 0 + $GotTracker ) != ( 0 + $TrackerID ) ) {
        $NeedFix = 1;
    }
    elsif ($WantIncident) {
        my $Got84 = $Self->_IssueCustomFieldValue( Issue => $Created, ID => 84 );
        my $Norm84 = $Self->_NormalizeMassIncidentValue($Got84);
        if ( !defined $Norm84 || "$Norm84" ne "$MassValue" ) {
            $NeedFix = 1;
        }
    }

    my $FixErr = '';
    if ($NeedFix) {
        my %FixPayload = (
            tracker_id     => 0 + $TrackerID,
            assigned_to_id => 0 + $AssignedToID,
            due_date       => $DueDate,
        );
        $FixPayload{priority_id} = 0 + $PriorityID if IsNumber($PriorityID) && $PriorityID;
        if ($WantIncident) {
            $FixPayload{custom_fields} = [ { id => 84, value => $MassValue } ];
        }
        elsif (@CustomFields) {
            $FixPayload{custom_fields} = \@CustomFields;
        }

        ATTEMPT:
        for my $Try ( 1 .. 2 ) {
            my %Fix = $Self->_Request(
                Method => 'PUT',
                Path   => "/issues/$IssueID.json",
                JSON   => { issue => \%FixPayload },
            );
            if ( !$Fix{Success} ) {
                $FixErr = $Self->_FormatRedmineAPIError(%Fix) || $Fix{Error} || 'PUT failed';
                next ATTEMPT;
            }
            $FixErr = '';
            my %Again = $Self->_Request( Method => 'GET', Path => "/issues/$IssueID.json" );
            if ( $Again{Success} ) {
                $Created    = $Again{Data}->{issue} || $Created;
                $GotTracker = $Created->{tracker}->{id};
            }
            last ATTEMPT
                if IsNumber($GotTracker) && ( 0 + $GotTracker ) == ( 0 + $TrackerID );
            $FixErr = 'PUT accepted but tracker still #' . ( $GotTracker // '?' );
        }
    }

    # Attach files after create/fix — mint tokens immediately before PUT.
    # Attach even if tracker is still wrong.
    my $AttachErr = '';
    if (@PendingUploads) {
        my @Uploads;
        PENDING:
        for my $Pending (@PendingUploads) {
            next PENDING if !IsHashRefWithData($Pending);
            if ( $Pending->{TokenReady} && $Pending->{token} ) {
                push @Uploads, {
                    token        => $Pending->{token},
                    filename     => $Pending->{filename} // 'file',
                    content_type => $Pending->{content_type} || 'application/octet-stream',
                };
                next PENDING;
            }
            my $Filename = $Pending->{Filename} // $Pending->{filename} // '';
            my $Content  = $Pending->{Content};
            $Content = ${$Content} if ref $Content eq 'SCALAR';
            next PENDING if !length $Filename || !defined $Content || !length $Content;
            my %Up = $Self->UploadFile(
                Filename    => $Filename,
                Content     => $Content,
                ContentType => $Pending->{ContentType}
                    || $Pending->{content_type}
                    || 'application/octet-stream',
            );
            if ( !$Up{Success} || !$Up{Token} ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "Redmine UploadFile failed for $Filename: "
                        . ( $Up{Error} || 'no token' ),
                );
                next PENDING;
            }
            push @Uploads, {
                token        => $Up{Token},
                filename     => $Filename,
                content_type => $Pending->{ContentType}
                    || $Pending->{content_type}
                    || 'application/octet-stream',
            };
        }
        if (@Uploads) {
            my %Up = $Self->_Request(
                Method => 'PUT',
                Path   => "/issues/$IssueID.json",
                JSON   => { issue => { uploads => \@Uploads } },
            );
            if ( !$Up{Success} ) {
                $AttachErr = $Self->_FormatRedmineAPIError(%Up) || $Up{Error} || 'upload failed';
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "Redmine issue #$IssueID created but attachments failed: $AttachErr",
                );
            }
        }
        elsif (@PendingUploads) {
            $AttachErr = 'could not mint Redmine upload tokens for attachments';
        }
    }

    if ( !IsNumber($GotTracker) || ( 0 + $GotTracker ) != ( 0 + $TrackerID ) ) {
        my $GotName = ( $Created->{tracker}->{name} // '?' );

        # PUT 204 with no tracker change almost always means the API key user
        # cannot set this tracker / CF (service account lacks project rights).
        my $APIUserHint = '';
        my %Who = $Self->_Request( Method => 'GET', Path => '/users/current.json' );
        if ( $Who{Success} ) {
            my $U     = $Who{Data}->{user} || {};
            my $Login = $U->{login} || '?';
            my $Name  = join ' ', grep { length $_ } ( $U->{firstname}, $U->{lastname} );
            $Name ||= $Login;
            $APIUserHint
                = " API key user: $Name ($Login)."
                . " Grant this user permission to create/update tracker #$TrackerID"
                . " and CF 84 on project #$ProjectID (Roles → trackers / custom fields);"
                . " then delete orphan #$IssueID and retry.";
        }

        return (
            Success => 0,
            IssueID => $IssueID,
            URL     => ( $Res{BaseURL} || '' ) . '/issues/' . $IssueID,
            Error   => "Redmine created issue #$IssueID as «$GotName» (#"
                . ( $GotTracker // '?' )
                . ") instead of requested tracker_id=$TrackerID (project=$ProjectID). "
                . ( length $FixErr ? "Tracker fix failed: $FixErr. " : '' )
                . ( length $AttachErr ? "Attachments: $AttachErr. " : '' )
                . "For «Инцидент» need assignee, due date, priority and CF 84 «Массовый инцидент»."
                . $APIUserHint,
        );
    }

    if ( length $AttachErr ) {
        return (
            Success   => 1,
            IssueID   => $IssueID,
            URL       => ( $Res{BaseURL} || '' ) . '/issues/' . $IssueID,
            TrackerID => 0 + $TrackerID,
            Warning   => "Issue created, but attachments failed: $AttachErr",
        );
    }

    return (
        Success   => 1,
        IssueID   => $IssueID,
        URL       => ( $Res{BaseURL} || '' ) . '/issues/' . $IssueID,
        TrackerID => 0 + (
            IsNumber( $Created->{tracker}->{id} )
            ? $Created->{tracker}->{id}
            : $TrackerID
        ),
    );
}

# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------

sub ParseIssueID {
    my ( $Self, $Raw ) = @_;
    return if !defined $Raw;
    $Raw =~ s{\A\s+}{};
    $Raw =~ s{\s+\z}{};
    return if !length $Raw;
    return $1 if $Raw =~ m{\A(\d+)\z};
    return $1 if $Raw =~ m{/issues/(\d+)(?:\D|\z)};
    return $1 if $Raw =~ m{\bissues?[#/\s]+(\d+)\b}i;
    return;
}

sub _ParseIssueID {
    my ( $Self, @Args ) = @_;
    return $Self->ParseIssueID(@Args);
}

sub TicketZoomURL {
    my ( $Self, %Param ) = @_;
    return '' if !$Param{TicketID};

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $Public       = $Self->NormalizeOTRSBaseURL(
        $ConfigObject->Get('Redmine::OTRSBaseURL')
    );

    if ( length $Public ) {
        return "$Public/index.pl?Action=AgentTicketZoom;TicketID=$Param{TicketID}";
    }

    my $HttpType = $ConfigObject->Get('HttpType')     || 'http';
    my $FQDN     = $ConfigObject->Get('FQDN')         || 'localhost';
    my $Script   = $ConfigObject->Get('ScriptAlias') || 'otrs/';
    return "$HttpType://$FQDN/${Script}index.pl?Action=AgentTicketZoom;TicketID=$Param{TicketID}";
}

sub _TicketZoomURL {
    my ( $Self, %Param ) = @_;
    return $Self->TicketZoomURL(%Param);
}

# Accept https://host/otrs , .../otrs/, .../otrs/index.pl , .../otrs/index.pl?...
sub NormalizeOTRSBaseURL {
    my ( $Self, $Raw ) = @_;
    return '' if !defined $Raw;
    $Raw =~ s{\A\s+}{};
    $Raw =~ s{\s+\z}{};
    return '' if !length $Raw;

    $Raw =~ s{\?.*\z}{};
    $Raw =~ s{/index\.pl\z}{}i;
    $Raw =~ s{/\z}{};
    return $Raw;
}

sub _NormalizeOTRSBaseURL {
    my ( $Self, @Args ) = @_;
    return $Self->NormalizeOTRSBaseURL(@Args);
}

sub DefaultDueDate {
    my ( $Self, %Param ) = @_;

    my $Days = $Kernel::OM->Get('Kernel::Config')->Get('Redmine::DefaultDueDateDays');
    $Days = 0 if !defined $Days || !IsNumber($Days);

    my $DateTimeObject = $Kernel::OM->Create('Kernel::System::DateTime');
    return '' if !$DateTimeObject;

    if ( $Days && $Days != 0 ) {
        my $Ok = $DateTimeObject->Add( Days => 0 + $Days );
        return '' if !$Ok;
    }

    return $DateTimeObject->Format( Format => '%Y-%m-%d' ) || '';
}

sub _DefaultDueDate {
    my ( $Self, %Param ) = @_;
    return $Self->DefaultDueDate(%Param);
}

sub FormatByteSize {
    my ( $Self, $Bytes ) = @_;
    $Bytes = 0 if !defined $Bytes || $Bytes !~ m{\A\d+\z};
    return '0 B' if !$Bytes;
    my @Units = qw(B KB MB GB);
    my $i     = 0;
    my $n     = 0 + $Bytes;
    while ( $n >= 1024 && $i < $#Units ) {
        $n /= 1024;
        $i++;
    }
    if ( $i == 0 ) {
        return "$Bytes B";
    }
    return sprintf( '%.1f %s', $n, $Units[$i] );
}

sub _FormatByteSize {
    my ( $Self, @Args ) = @_;
    return $Self->FormatByteSize(@Args);
}

sub _NormalizeDueDate {
    my ( $Self, $DueDate ) = @_;
    return '' if !defined $DueDate;
    $DueDate =~ s{\A\s+}{};
    $DueDate =~ s{\s+\z}{};
    return '' if !length $DueDate;

    # Accept YYYY-MM-DD or DD.MM.YYYY
    if ( $DueDate =~ m{\A(\d{2})\.(\d{2})\.(\d{4})\z} ) {
        return "$3-$2-$1";
    }
    return $DueDate if $DueDate =~ m{\A\d{4}-\d{2}-\d{2}\z};
    return '';
}

# Build custom_fields for Redmine create/update.
# DefaultCustomFields lines: `id=value` (all trackers) or `trackerId:id=value`.
# CF 84 ignored unless WantIncident or explicitly tracker-scoped.
sub _BuildCustomFields {
    my ( $Self, %Param ) = @_;

    my $TrackerID    = $Param{TrackerID};
    my $WantIncident = $Param{WantIncident};
    if ( !defined $WantIncident ) {
        my $IncidentTrackerID
            = $Kernel::OM->Get('Kernel::Config')->Get('Redmine::IncidentTrackerID') // 13;
        $WantIncident
            = (
            IsNumber($IncidentTrackerID)
                && IsNumber($TrackerID)
                && ( 0 + $TrackerID ) == ( 0 + $IncidentTrackerID )
            ) ? 1 : 0;
    }

    my %ByID;
    my %Explicit84;

    my $Defaults = $Kernel::OM->Get('Kernel::Config')->Get('Redmine::DefaultCustomFields') // '';
    if ( IsStringWithData($Defaults) ) {
        for my $Line ( split /\n/, $Defaults ) {
            $Line =~ s{\A\s+}{};
            $Line =~ s{\s+\z}{};
            next if !length $Line || $Line =~ m{\A#};

            my ( $ScopeTracker, $ID, $Value );
            if ( $Line =~ m{\A(\d+)\s*:\s*(\d+)\s*=(.*)\z}s ) {
                ( $ScopeTracker, $ID, $Value ) = ( $1, $2, $3 );
            }
            elsif ( $Line =~ m{\A(\d+)\s*=(.*)\z}s ) {
                ( $ID, $Value ) = ( $1, $2 );
            }
            else {
                next;
            }

            next if !IsNumber($ID);
            if ( defined $ScopeTracker ) {
                next if !IsNumber($TrackerID);
                next if ( 0 + $ScopeTracker ) != ( 0 + $TrackerID );
            }

            $Value = '' if !defined $Value;
            $Value =~ s{\A\s+}{};
            $Value =~ s{\s+\z}{};

            if ( ( 0 + $ID ) == 84 ) {
                if ( defined $ScopeTracker ) {
                    $Explicit84{1} = 1;
                    $ByID{84} = $Value;
                }
                elsif ($WantIncident) {
                    $ByID{84} = $Value;
                }

                # Unscoped 84 ignored for non-incident (empty-default semantics).
                next;
            }

            $ByID{ 0 + $ID } = $Value;
        }
    }

    if ( $WantIncident && exists $Param{MassIncident} && defined $Param{MassIncident} ) {
        my $Mass = $Param{MassIncident};
        $Mass = ( $Mass && $Mass ne '0' ) ? '1' : '0';
        $ByID{84} = $Mass;
    }
    elsif ( !$WantIncident && !$Explicit84{1} ) {
        delete $ByID{84};
    }

    if ( IsArrayRefWithData( $Param{CustomFields} ) ) {
        for my $CF ( @{ $Param{CustomFields} } ) {
            next if !IsHashRefWithData($CF) || !IsNumber( $CF->{id} );
            my $ID = 0 + $CF->{id};
            if ( $ID == 84 && !$WantIncident ) {
                next;
            }
            $ByID{$ID} = defined $CF->{value} ? $CF->{value} : '';
        }
    }

    return map { { id => $_, value => $ByID{$_} } } sort { $a <=> $b } keys %ByID;
}

sub ListEscalateAttachments {
    my ( $Self, %Param ) = @_;

    return () if !$Param{TicketID};

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    return () if !$ConfigObject->Get('Redmine::SyncAttachments');

    my $Max           = $ConfigObject->Get('Redmine::MaxAttachmentBytes') || 5_000_000;
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my @Articles      = $ArticleObject->ArticleList( TicketID => $Param{TicketID} );

    my @Ordered;
    my @Rest;
    for my $Meta (@Articles) {
        my $Backend = $ArticleObject->BackendForArticle( %{$Meta} );
        my %Article = $Backend->ArticleGet(
            TicketID      => $Param{TicketID},
            ArticleID     => $Meta->{ArticleID},
            DynamicFields => 0,
        );
        next if !%Article;
        next if $Self->_IsAutoReplyArticle(%Article);
        if ( lc( $Article{SenderType} // '' ) eq 'customer' ) {
            push @Ordered, { Meta => $Meta, Backend => $Backend };
        }
        else {
            push @Rest, { Meta => $Meta, Backend => $Backend };
        }
    }
    push @Ordered, @Rest;

    my @List;
    my %SeenName;

    ARTICLE:
    for my $Item (@Ordered) {
        my $Backend   = $Item->{Backend};
        my $ArticleID = $Item->{Meta}->{ArticleID};
        my %Index     = $Backend->ArticleAttachmentIndex(
            ArticleID        => $ArticleID,
            UserID           => 1,
            ExcludePlainText => 1,
            ExcludeHTMLBody  => 1,
        );
        ATTACHMENT:
        for my $FileID ( sort { $a <=> $b } keys %Index ) {
            my $Meta     = $Index{$FileID} || {};
            my $Filename = $Meta->{Filename} // '';
            next ATTACHMENT if !length $Filename;
            next ATTACHMENT if $Filename =~ m{\Afile-\d+\z};
            next ATTACHMENT if $Filename =~ m{\Afile-\d+\.(?:html|txt)\z}i;
            next ATTACHMENT if $SeenName{$Filename}++;

            my $Size = 0 + ( $Meta->{FilesizeRaw} // $Meta->{Filesize} // 0 );
            if ( $Size <= 0 && defined $Meta->{Filesize} && $Meta->{Filesize} =~ m{\A(\d+)\z} ) {
                $Size = 0 + $1;
            }

            my $ContentType = $Meta->{ContentType} || 'application/octet-stream';
            my $TooLarge    = ( $Size > 0 && $Size > $Max ) ? 1 : 0;
            my $IsImage     = ( $ContentType =~ m{\Aimage/(?:png|jpe?g|gif|webp|bmp)\b}i ) ? 1 : 0;
            my ($Ext)       = $Filename =~ m{\.([A-Za-z0-9]{1,8})\z};
            $Ext = $Ext ? uc($Ext) : 'FILE';
            $Ext = 'FILE' if length($Ext) > 5;
            my ( $BadgeBg, $BadgeFg ) = $Self->_AttachmentBadgeColors(
                Ext         => $Ext,
                ContentType => $ContentType,
                IsImage     => $IsImage,
            );

            push @List, {
                Key         => "$ArticleID:$FileID",
                ArticleID   => 0 + $ArticleID,
                FileID      => 0 + $FileID,
                Filename    => $Filename,
                ContentType => $ContentType,
                Size        => $Size,
                SizeLabel   => $Self->FormatByteSize($Size),
                IsImage     => $IsImage,
                TooLarge    => $TooLarge,
                Ext         => $Ext,
                BadgeBg     => $BadgeBg,
                BadgeFg     => $BadgeFg,
            };
        }
    }

    return @List;
}

sub _CollectEscalateUploadFiles {
    my ( $Self, %Param ) = @_;

    return () if !$Param{TicketID};

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    return () if !$ConfigObject->Get('Redmine::SyncAttachments');

    if ( exists $Param{IncludeAttachments} && !$Param{IncludeAttachments} ) {
        return ();
    }

    my @Candidates = $Self->ListEscalateAttachments( TicketID => $Param{TicketID} );
    return () if !@Candidates;

    my %Want;
    my $Filter = 0;
    if ( IsArrayRefWithData( $Param{AttachmentKeys} ) ) {
        $Filter = 1;
        for my $Key ( @{ $Param{AttachmentKeys} } ) {
            next if !defined $Key || !length $Key;
            $Want{$Key} = 1;
        }
    }

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $Max           = $ConfigObject->Get('Redmine::MaxAttachmentBytes') || 5_000_000;
    my @Files;

    CANDIDATE:
    for my $Item (@Candidates) {
        next CANDIDATE if $Filter && !$Want{ $Item->{Key} };
        next CANDIDATE if $Item->{TooLarge};

        my $Backend = $ArticleObject->BackendForArticle(
            TicketID  => $Param{TicketID},
            ArticleID => $Item->{ArticleID},
        );
        my %File = $Backend->ArticleAttachment(
            ArticleID => $Item->{ArticleID},
            FileID    => $Item->{FileID},
            UserID    => 1,
        );
        next CANDIDATE if !%File;

        my $Filename = $File{Filename} // $Item->{Filename};
        my $Content  = $File{Content};
        $Content = ${$Content} if ref $Content eq 'SCALAR';
        next CANDIDATE if !defined $Content || !length $Content;
        if ( length($Content) > $Max ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'notice',
                Message  => "Redmine escalate skip attachment $Filename (too large)",
            );
            next CANDIDATE;
        }

        push @Files, {
            Filename    => $Filename,
            Content     => $Content,
            ContentType => $File{ContentType} || $Item->{ContentType} || 'application/octet-stream',
        };
    }

    return @Files;
}

sub _CollectFormIDUploadFiles {
    my ( $Self, %Param ) = @_;

    return () if !$Param{FormID};

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $Max          = $ConfigObject->Get('Redmine::MaxAttachmentBytes') || 5_000_000;
    my @CacheFiles   = $Kernel::OM->Get('Kernel::System::Web::UploadCache')->FormIDGetAllFilesData(
        FormID => $Param{FormID},
    );
    my @Files;

    FILE:
    for my $File (@CacheFiles) {
        my $Filename = $File->{Filename} // '';
        next FILE if !length $Filename;
        my $Content = $File->{Content};
        $Content = ${$Content} if ref $Content eq 'SCALAR';
        next FILE if !defined $Content || !length $Content;
        if ( length($Content) > $Max ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'notice',
                Message  => "Redmine escalate skip FormID file $Filename (too large)",
            );
            next FILE;
        }
        push @Files, {
            Filename    => $Filename,
            Content     => $Content,
            ContentType => $File->{ContentType} || 'application/octet-stream',
        };
    }

    return @Files;
}

# ---------------------------------------------------------------------------
# Private helpers (Issue-local)
# ---------------------------------------------------------------------------

sub _EscalateFailureRecord {
    my ( $Self, %Param ) = @_;

    my $Error = substr( $Param{Error} || 'unknown', 0, 3800 );

    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineEscalationStatus',
        Value    => 'error',
        UserID   => $Param{UserID},
    );
    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineLastError',
        Value    => $Error,
        UserID   => $Param{UserID},
    );
    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineProjectID',
        Value    => "$Param{ProjectID}",
        UserID   => $Param{UserID},
    ) if IsNumber( $Param{ProjectID} );
    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineTrackerID',
        Value    => "$Param{TrackerID}",
        UserID   => $Param{UserID},
    ) if IsNumber( $Param{TrackerID} );

    $Self->_AddInternalArticle(
        TicketID       => $Param{TicketID},
        UserID         => $Param{UserID},
        Subject        => 'Redmine: ошибка эскалации',
        Body           => "Не удалось создать задачу в Redmine.\nПричина: $Error",
        HistoryComment => '%%RedmineBridge',
    );

    return 1;
}

# Create-only allow-list: Redmine::AllowedProjectIDs, or Redmine::ProjectID if empty.
# Link/relink intentionally do not use this check.
sub _IsAllowedRedmineProjectID {
    my ( $Self, $ProjectID ) = @_;

    return 0 if !IsNumber($ProjectID);

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $Raw          = $ConfigObject->Get('Redmine::AllowedProjectIDs');
    my @Allowed;

    if ( defined $Raw && length $Raw ) {
        for my $Part ( split /[\s,]+/, $Raw ) {
            next if !length $Part;
            push @Allowed, $Part if IsNumber($Part);
        }
    }

    if ( !@Allowed ) {
        my $Default = $ConfigObject->Get('Redmine::ProjectID');
        push @Allowed, $Default if IsNumber($Default);
    }

    return 0 if !@Allowed;
    return scalar grep { ( 0 + $_ ) == ( 0 + $ProjectID ) } @Allowed;
}

sub _IssueCustomFieldValue {
    my ( $Self, %Param ) = @_;

    my $Issue = $Param{Issue} || {};
    my $ID    = $Param{ID};
    return if !IsNumber($ID);

    for my $CF ( @{ $Issue->{custom_fields} || [] } ) {
        next if !IsHashRefWithData($CF) || !IsNumber( $CF->{id} );
        next if ( 0 + $CF->{id} ) != ( 0 + $ID );
        my $V = $CF->{value};
        if ( ref $V eq 'HASH' ) {
            $V = $V->{id} // $V->{value} // $V->{name};
        }
        elsif ( ref $V eq 'ARRAY' ) {
            $V = $V->[0];
        }
        return $V;
    }
    return;
}

sub _NormalizeMassIncidentValue {
    my ( $Self, $Raw ) = @_;
    return if !defined $Raw;
    my $V = "$Raw";
    $V =~ s{\A\s+}{};
    $V =~ s{\s+\z}{};
    return if !length $V;
    return '1' if $V eq '1' || $V eq 'Да' || lc($V) eq 'yes' || lc($V) eq 'true';
    return '0' if $V eq '0' || $V eq 'Нет' || lc($V) eq 'no' || lc($V) eq 'false';
    return ( $V && $V ne '0' ) ? '1' : '0';
}

sub _FormatRedmineAPIError {
    my ( $Self, %Param ) = @_;

    my $Error   = $Param{Error}   // '';
    my $Content = $Param{Content} // '';
    return $Error if !length $Content;

    my $Data = eval { $Kernel::OM->Get('Kernel::System::JSON')->Decode( Data => $Content ) };
    if ( IsHashRefWithData($Data) && IsArrayRefWithData( $Data->{errors} ) ) {
        return join( '; ', @{ $Data->{errors} } );
    }
    return $Error;
}

sub _AttachmentBadgeColors {
    my ( $Self, %Param ) = @_;
    my $Ext = uc( $Param{Ext} // 'FILE' );

    return ( '#dbe7f3', '#1e4b7a' ) if $Param{IsImage};
    return ( '#f3d6d6', '#8b1e1e' ) if $Ext eq 'PDF' || ( $Param{ContentType} // '' ) =~ m{pdf}i;
    return ( '#d6e8d6', '#1e5a1e' ) if $Ext =~ m{\A(?:XLSX?|CSV|ODS)\z};
    return ( '#d6dff3', '#1e3a7a' ) if $Ext =~ m{\A(?:DOCX?|ODT|RTF)\z};
    return ( '#e8e0d6', '#5a3e1e' ) if $Ext =~ m{\A(?:PPTX?|ODP)\z};
    return ( '#e4e4e8', '#3a3a48' ) if $Ext =~ m{\A(?:ZIP|RAR|7Z|GZ|TGZ)\z};
    return ( '#e8eef5', '#3a4a5c' );
}

1;
