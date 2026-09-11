# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Redmine::Sync;

use strict;
use warnings;
use utf8;

# Methods are mixed into Kernel::System::Redmine via use parent.
# $Self is the Redmine object. Use Kernel::OM normally.
# NO sub new — facade owns construction.

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
    'Kernel::System::HTMLUtils',
    'Kernel::System::JSON',
    'Kernel::System::Log',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
    'Kernel::System::User',
);

# ---------------------------------------------------------------------------
# Outbound sync (OTRS article → Redmine note)
# ---------------------------------------------------------------------------

sub SyncArticleToRedmine {
    my ( $Self, %Param ) = @_;

    return ( Success => 0, Error => 'Need TicketID and ArticleID' )
        if !$Param{TicketID} || !$Param{ArticleID};

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    return ( Success => 1, Status => 'Disabled' ) if !$ConfigObject->Get('Redmine::Enabled');
    return ( Success => 1, Status => 'Disabled' ) if !$ConfigObject->Get('Redmine::SyncComments');

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my %Ticket       = $TicketObject->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $Param{UserID} || 1,
        Silent        => 1,
    );
    return ( Success => 1, Status => 'Skip' ) if !IsStringWithData( $Ticket{DynamicField_RedmineID} );

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $Backend       = $ArticleObject->BackendForArticle(
        TicketID  => $Param{TicketID},
        ArticleID => $Param{ArticleID},
    );
    my %Article = $Backend->ArticleGet(
        TicketID      => $Param{TicketID},
        ArticleID     => $Param{ArticleID},
        DynamicFields => 0,
    );
    return ( Success => 1, Status => 'Skip' ) if !%Article;

    # K6: skip only when history says bridge-authored / already synced — not by subject alone.
    return ( Success => 1, Status => 'Skip' )
        if $Self->_ArticleAlreadySyncedOutbound(
            TicketID  => $Param{TicketID},
            ArticleID => $Param{ArticleID},
        );

    my $Body = $Article{Body} // '';
    if ( ( $Article{ContentType} // '' ) =~ m{html}i ) {
        $Body = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToAscii( String => $Body );
    }
    $Body =~ s{\A\s+}{};
    $Body =~ s{\s+\z}{};

    # Re-imported outbound notes — do not wrap again (RU + legacy EN)
    return ( Success => 1, Status => 'Skip' )
        if $Body =~ m{\A(?:Заметка\s+OTRS\s+от|OTRS\s+note\s+by)\s+}ms;

    my @Uploads;
    if ( $ConfigObject->Get('Redmine::SyncAttachments') ) {
        my %Index = $Backend->ArticleAttachmentIndex(
            ArticleID => $Param{ArticleID},
            UserID    => $Param{UserID} || 1,
        );
        ATTACHMENT:
        for my $FileID ( sort { $a <=> $b } keys %Index ) {
            my %File = $Backend->ArticleAttachment(
                ArticleID => $Param{ArticleID},
                FileID    => $FileID,
                UserID    => $Param{UserID} || 1,
            );
            next ATTACHMENT if !%File;
            my $Filename = $File{Filename} // '';
            next ATTACHMENT if $Filename =~ m{\Afile-\d+\z};    # skip inline html parts often
            my $Content = $File{Content};
            $Content = ${$Content} if ref $Content eq 'SCALAR';
            next ATTACHMENT if !defined $Content || !length $Content;
            my $Max = $ConfigObject->Get('Redmine::MaxAttachmentBytes') || 5_000_000;
            if ( length($Content) > $Max ) {
                $Body .= "\n\n[вложение пропущено: $Filename — слишком большое]";
                next ATTACHMENT;
            }
            my %Up = $Self->UploadFile(
                Filename    => $Filename,
                Content     => $Content,
                ContentType => $File{ContentType} || 'application/octet-stream',
            );
            if ( $Up{Success} && $Up{Token} ) {
                push @Uploads, {
                    token        => $Up{Token},
                    filename     => $Filename,
                    content_type => $File{ContentType} || 'application/octet-stream',
                };
            }
        }
    }

    return ( Success => 1, Status => 'Skip' ) if !length($Body) && !@Uploads;

    my %User = $Kernel::OM->Get('Kernel::System::User')->GetUserData( UserID => $Param{UserID} || 1 );
    my $Login = $User{UserLogin} || $Param{UserID};
    my $TN    = $Ticket{TicketNumber} // '';

    # K5: stamp ticket number so inbound echo skip is per-ticket (Russian)
    my $Note
        = "Заметка OTRS от $Login (тикет $TN):\n\n"
        . ( length($Body) ? $Body : '(только вложение)' );

    my %IssueUpdate = ( notes => $Note );
    $IssueUpdate{uploads} = \@Uploads if @Uploads;

    my %Res = $Self->_Request(
        Method => 'PUT',
        Path   => "/issues/$Ticket{DynamicField_RedmineID}.json",
        JSON   => { issue => \%IssueUpdate },
    );
    return ( Success => 0, Status => 'Error', Error => $Res{Error} ) if !$Res{Success};

    $Self->_MarkArticleSyncedOutbound(
        TicketID  => $Param{TicketID},
        ArticleID => $Param{ArticleID},
        UserID    => $Param{UserID} || 1,
    );

    # Prefer MaxJournalID when known; fallback GET only if IssueID given without max
    $Self->_BumpLastJournalID(
        TicketID => $Param{TicketID},
        IssueID  => $Ticket{DynamicField_RedmineID},
        UserID   => $Param{UserID} || 1,
    );

    # Avoid inbound re-import of files we just uploaded to Redmine.
    if (@Uploads) {
        $Self->_BumpLastAttachmentID(
            TicketID => $Param{TicketID},
            IssueID  => $Ticket{DynamicField_RedmineID},
            UserID   => $Param{UserID} || 1,
        );
    }

    return ( Success => 1, Status => 'Synced' );
}

# ---------------------------------------------------------------------------
# Inbound sync (Redmine → OTRS)
# ---------------------------------------------------------------------------

sub SyncTicketFromRedmine {
    my ( $Self, %Param ) = @_;

    return ( Success => 0, Error => 'Need TicketID' ) if !$Param{TicketID};

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    return ( Success => 1, Status => 'Disabled' ) if !$ConfigObject->Get('Redmine::Enabled');

    my $UserID       = $Param{UserID} || 1;
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my %Ticket       = $TicketObject->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $UserID,
        Silent        => 1,
    );
    return ( Success => 1, Status => 'Skip' ) if !IsStringWithData( $Ticket{DynamicField_RedmineID} );

    my $IssueID = $Ticket{DynamicField_RedmineID};
    return ( Success => 0, Status => 'Error', Error => 'RedmineID is not numeric' )
        if !IsNumber($IssueID);

    # S8: always fetch issue (status / updated_on / attachments) without journals first
    my $SyncAtt = $ConfigObject->Get('Redmine::SyncAttachments') ? 1 : 0;
    my $Path    = $SyncAtt
        ? "/issues/$IssueID.json?include=attachments"
        : "/issues/$IssueID.json";

    my %Res = $Self->_Request(
        Method => 'GET',
        Path   => $Path,
    );
    return ( Success => 0, Status => 'Error', Error => $Res{Error} ) if !$Res{Success};

    my $Issue      = $Res{Data}->{issue} || {};
    my $StatusName = $Issue->{status}->{name} || '';
    my $UpdatedOn  = $Issue->{updated_on} // '';
    my $StoredOn   = $Ticket{DynamicField_RedmineLastUpdatedOn} // '';
    $StatusName = $Self->_DecodeUTF8($StatusName) if $Self->can('_DecodeUTF8');
    $UpdatedOn  = $Self->_DecodeUTF8($UpdatedOn)  if $Self->can('_DecodeUTF8');

    my $NeedJournals = !length($StoredOn) || ( length($UpdatedOn) && $UpdatedOn gt $StoredOn );

    my @Journals;
    if ($NeedJournals) {
        my %JRes = $Self->_Request(
            Method => 'GET',
            Path   => "/issues/$IssueID.json?include=journals",
        );
        if ( $JRes{Success} ) {
            @Journals = @{ $JRes{Data}->{issue}->{journals} || [] };
            # Prefer freshest status/updated_on from journals response when present
            my $JIssue = $JRes{Data}->{issue} || {};
            $StatusName = $JIssue->{status}->{name} || $StatusName;
            $UpdatedOn  = $JIssue->{updated_on}     // $UpdatedOn;
        }
        else {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Redmine SyncTicketFromRedmine journals GET failed for #$IssueID: "
                    . ( $JRes{Error} || 'unknown' ),
            );
        }
    }

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $Backend       = $ArticleObject->BackendForChannel( ChannelName => 'Internal' );

    my $OldStatus     = $Ticket{DynamicField_RedmineStatus} // '';
    my $StatusChanged = length $StatusName && $OldStatus ne $StatusName ? 1 : 0;
    my ( $MappedState, $WriteNote ) = $StatusChanged
        ? $Self->_StatusSyncActions($StatusName)
        : ( undef, 0 );

    if ($StatusChanged) {
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineStatus',
            Value    => $StatusName,
            UserID   => $UserID,
        );
        if ($MappedState) {
            $TicketObject->TicketStateSet(
                TicketID           => $Param{TicketID},
                State              => $MappedState,
                UserID             => $UserID,
                SendNoNotification => 1,
            );
        }
    }

    # One inbound OTRS note per sync run: status / comments / attachments as blocks.
    my $LastJournal       = 0 + ( $Ticket{DynamicField_RedmineLastJournalID} || 0 );
    my $MaxJournal        = $LastJournal;
    my $StatusNoteEmitted = 0;
    my $TicketNumber      = $Ticket{TicketNumber} // '';

    my @StatusLines;
    my @CommentBlocks;
    my @AttachmentFiles;    # { Content, ContentType, Filename }
    my @AttachmentLines;    # text lines for the «Вложения» block

    JOURNAL:
    for my $Journal (@Journals) {
        my $JID = 0 + ( $Journal->{id} || 0 );
        next JOURNAL if $JID <= $LastJournal;
        $MaxJournal = $JID if $JID > $MaxJournal;

        my $Notes = $Journal->{notes} // '';
        $Notes = $Self->_DecodeUTF8($Notes) if $Self->can('_DecodeUTF8');
        if ( $Notes =~ m{<\s*(?:p|div|br|span)\b}i ) {
            $Notes = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToAscii( String => $Notes );
        }
        $Notes =~ s{\A\s+}{};
        $Notes =~ s{\s+\z}{};

        my $IsOutboundEcho = $Self->_IsOutboundEchoNote(
            Notes        => $Notes,
            TicketNumber => $TicketNumber,
        );

        my $HasStatusDetail = $Self->_JournalHasStatusChange($Journal);
        my $Author          = $Journal->{user}->{name} || $Journal->{user}->{login} || 'Redmine';
        $Author = $Self->_DecodeUTF8($Author) if $Self->can('_DecodeUTF8');

        # Comments → OTRS only when StatusSync for the new status has |note
        # (e.g. «Проверка решения» = open|note). Plain journals without that
        # status transition are ignored (cursor still advances).
        my $IncludeStatus = ( $HasStatusDetail && $WriteNote ) ? 1 : 0;
        my $IncludeNotes
            = ( length $Notes && !$IsOutboundEcho && $WriteNote && $HasStatusDetail )
            ? 1
            : 0;
        next JOURNAL if !$IncludeStatus && !$IncludeNotes;

        if ($IncludeStatus) {
            my $StatusPart = 'Статус Redmine изменён';
            $StatusPart .= " с «$OldStatus»" if length $OldStatus;
            $StatusPart .= " на «$StatusName».";
            if ($MappedState) {
                $StatusPart .= " Состояние тикета OTRS: $MappedState.";
            }
            $StatusPart .= " Автор в Redmine: $Author.";
            push @StatusLines, $StatusPart;
            $StatusNoteEmitted = 1;
        }
        if ($IncludeNotes) {
            push @CommentBlocks, "$Author:\n$Notes";
        }
    }

    # Status-only change (empty journal notes): still emit «Статус» when StatusSync has |note.
    # Journals may omit status_id details — fallback below still covers StatusChanged+|note.
    if ( $StatusChanged && $WriteNote && !$StatusNoteEmitted ) {
        my $StatusPart = 'Статус Redmine изменён';
        $StatusPart .= " с «$OldStatus»" if length $OldStatus;
        $StatusPart .= " на «$StatusName».";
        if ($MappedState) {
            $StatusPart .= " Состояние тикета OTRS: $MappedState.";
        }
        push @StatusLines, $StatusPart;
        $StatusNoteEmitted = 1;
    }

    if ( $MaxJournal > $LastJournal ) {
        $Self->_BumpLastJournalID(
            TicketID     => $Param{TicketID},
            MaxJournalID => $MaxJournal,
            UserID       => $UserID,
        );
    }

    # Attachments from Redmine:
    # - file alone (no status note / comment) → only advance cursor (no OTRS article, no loop)
    # - with status/comment → download and attach to the same consolidated note
    if ($SyncAtt) {
        my $LastAtt  = 0 + ( $Ticket{DynamicField_RedmineLastAttachmentID} || 0 );
        my $MaxBytes = $ConfigObject->Get('Redmine::MaxAttachmentBytes') || 5_000_000;
        my $BaseURL  = $Res{BaseURL} || $ConfigObject->Get('Redmine::BaseURL') || '';
        $BaseURL =~ s{/\z}{};

        my @AttSorted = sort {
            ( 0 + ( $a->{id} || 0 ) ) <=> ( 0 + ( $b->{id} || 0 ) )
        } @{ $Issue->{attachments} || [] };

        my $WantFiles = ( @StatusLines || @CommentBlocks ) ? 1 : 0;

        ATT:
        for my $Att (@AttSorted) {
            my $AID = 0 + ( $Att->{id} || 0 );
            next ATT if $AID <= $LastAtt;

            my $Filename = $Att->{filename} || "redmine-$AID.bin";
            $Filename = $Self->_DecodeUTF8($Filename) if $Self->can('_DecodeUTF8');

            # No status/comment this run — mark seen, do not import (breaks escalate file loop).
            if ( !$WantFiles ) {
                $Self->_SetDF(
                    TicketID => $Param{TicketID},
                    Name     => 'RedmineLastAttachmentID',
                    Value    => "$AID",
                    UserID   => $UserID,
                );
                $LastAtt = $AID;
                next ATT;
            }

            my $KnownSize = 0 + ( $Att->{filesize} // $Att->{file_size} // 0 );

            if ( $KnownSize > 0 && $KnownSize > $MaxBytes ) {
                push @AttachmentLines,
                    "• $Filename — не импортировано (размер $KnownSize байт > лимита $MaxBytes).";
                $Self->_SetDF(
                    TicketID => $Param{TicketID},
                    Name     => 'RedmineLastAttachmentID',
                    Value    => "$AID",
                    UserID   => $UserID,
                );
                $LastAtt = $AID;
                next ATT;
            }

            # Id-only path — filename segment breaks on Cyrillic/spaces.
            my $Rel = $AID ? "/attachments/download/$AID" : '';
            if ( !$Rel ) {
                my $ContentURL = $Att->{content_url} || '';
                $Rel = $Self->_SafeRelativePath( $ContentURL, $BaseURL );
            }

            if ( !$Rel ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "Redmine SyncTicketFromRedmine: unsafe or empty content path "
                        . "for attachment #$AID on issue #$IssueID — skipped",
                );
                $Self->_SetDF(
                    TicketID => $Param{TicketID},
                    Name     => 'RedmineLastAttachmentID',
                    Value    => "$AID",
                    UserID   => $UserID,
                );
                $LastAtt = $AID;
                next ATT;
            }

            my %FileRes = $Self->_Request(
                Method     => 'GET',
                Path       => $Rel,
                ExpectJSON => 0,
            );

            if ( !$FileRes{Success} ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "Redmine SyncTicketFromRedmine: download failed for attachment #$AID: "
                        . ( $FileRes{Error} || 'unknown' ),
                );
                next ATT;
            }

            my $Bin = $FileRes{Content};
            if ( !defined $Bin || !length $Bin ) {
                $Self->_SetDF(
                    TicketID => $Param{TicketID},
                    Name     => 'RedmineLastAttachmentID',
                    Value    => "$AID",
                    UserID   => $UserID,
                );
                $LastAtt = $AID;
                next ATT;
            }

            my $GotLen = length($Bin);
            if ( $GotLen > $MaxBytes ) {
                push @AttachmentLines,
                    "• $Filename — не импортировано (получено $GotLen байт > лимита $MaxBytes).";
                $Self->_SetDF(
                    TicketID => $Param{TicketID},
                    Name     => 'RedmineLastAttachmentID',
                    Value    => "$AID",
                    UserID   => $UserID,
                );
                $LastAtt = $AID;
                next ATT;
            }

            push @AttachmentFiles, {
                Content     => $Bin,
                ContentType => $Att->{content_type} || 'application/octet-stream',
                Filename    => $Filename,
            };

            $Self->_SetDF(
                TicketID => $Param{TicketID},
                Name     => 'RedmineLastAttachmentID',
                Value    => "$AID",
                UserID   => $UserID,
            );
            $LastAtt = $AID;
        }
    }

    if ( @StatusLines || @CommentBlocks || @AttachmentLines || @AttachmentFiles ) {
        my @Sections;
        push @Sections, "— Статус —\n" . join( "\n", @StatusLines ) if @StatusLines;
        push @Sections, "— Комментарии —\n" . join( "\n\n", @CommentBlocks ) if @CommentBlocks;
        if (@AttachmentLines) {
            push @Sections, "— Вложения —\n" . join( "\n", @AttachmentLines );
        }
        elsif (@AttachmentFiles) {
            my $Names = join "\n", map {"• $_->{Filename}"} @AttachmentFiles;
            push @Sections, "— Вложения —\n$Names";
        }

        my $Subject = "Redmine #$IssueID: обновление";
        if ( @StatusLines && !@CommentBlocks && !@AttachmentFiles && !@AttachmentLines ) {
            $Subject = "Redmine #$IssueID: статус «$StatusName»";
        }
        elsif ( !@StatusLines && @CommentBlocks && !@AttachmentFiles && !@AttachmentLines ) {
            $Subject = "Redmine #$IssueID: комментарий";
        }
        elsif ( !@StatusLines && !@CommentBlocks && @AttachmentLines && !@AttachmentFiles ) {
            $Subject = "Redmine #$IssueID: вложения";
        }

        my %Create = (
            TicketID             => $Param{TicketID},
            SenderType           => 'agent',
            IsVisibleForCustomer => 0,
            Subject              => $Subject,
            Body                 => join( "\n\n", @Sections ),
            ContentType          => 'text/plain; charset=utf-8',
            Charset              => 'utf-8',
            MimeType             => 'text/plain',
            HistoryType          => 'AddNote',
            HistoryComment       => '%%RedmineInbound',
            UserID               => $UserID,
        );
        if (@AttachmentFiles) {
            $Create{Attachment} = \@AttachmentFiles;
        }

        # Optional agent notification on StatusSync |note (e.g. «Проверка решения»).
        if ( $ConfigObject->Get('Redmine::NotifyOnStatusNote') ) {
            my @Notify;
            my %Seen;
            for my $UID ( $Ticket{OwnerID}, $Ticket{ResponsibleID} ) {
                next if !IsNumber($UID) || $UID < 2;
                next if $Seen{$UID}++;
                push @Notify, 0 + $UID;
            }
            $Create{ForceNotificationToUserID} = \@Notify if @Notify;
        }

        $Backend->ArticleCreate(%Create);
    }

    # S8: store updated_on cursor
    if ( length $UpdatedOn ) {
        $Self->_SetDF(
            TicketID => $Param{TicketID},
            Name     => 'RedmineLastUpdatedOn',
            Value    => "$UpdatedOn",
            UserID   => $UserID,
        );
    }

    # K8: last successful sync timestamp (ISO-ish / epoch string for sort)
    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineLastSyncAt',
        Value    => '' . time(),
        UserID   => $UserID,
    );

    return ( Success => 1, Status => 'Synced', IssueStatus => $StatusName );
}

sub CronSync {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    return 1 if !$ConfigObject->Get('Redmine::Enabled');
    return 1 if !$ConfigObject->Get('Redmine::InboundSync');

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $CacheObject  = $Kernel::OM->Get('Kernel::System::Cache');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');

    my $Limit  = $ConfigObject->Get('Redmine::SyncBatchLimit') || 50;
    $Limit = 50 if !IsNumber($Limit) || $Limit < 1;
    my $FetchLimit = $Limit * 2;

    # K8: TicketSearch may not sort by DF — fetch larger set, sort by RedmineLastSyncAt ASC
    my @TicketIDs = $TicketObject->TicketSearch(
        Result                 => 'ARRAY',
        UserID                 => 1,
        Limit                  => $FetchLimit,
        DynamicField_RedmineID => {
            Empty => 0,
        },
    );

    my @Candidates;
    for my $TicketID (@TicketIDs) {
        my %Ticket = $TicketObject->TicketGet(
            TicketID      => $TicketID,
            DynamicFields => 1,
            UserID        => 1,
            Silent        => 1,
        );
        push @Candidates, {
            TicketID => $TicketID,
            SyncAt   => $Ticket{DynamicField_RedmineLastSyncAt} // '',
        };
    }

    @Candidates = sort {
        ( $a->{SyncAt} // '' ) cmp ( $b->{SyncAt} // '' )
            || ( $a->{TicketID} <=> $b->{TicketID} )
    } @Candidates;

    if ( @Candidates > $Limit ) {
        $LogObject->Log(
            Priority => 'notice',
            Message  => 'Redmine CronSync: hit SyncBatchLimit='
                . $Limit
                . ' (candidates='
                . scalar(@Candidates)
                . '); remaining tickets deferred to next run',
        );
        @Candidates = @Candidates[ 0 .. ( $Limit - 1 ) ];
    }

    my $SyncedCount  = 0;
    my $LastError    = '';
    my $LastSyncOK   = 1;

    for my $Row (@Candidates) {
        my %Res = $Self->SyncTicketFromRedmine(
            TicketID => $Row->{TicketID},
            UserID   => 1,
        );
        if ( $Res{Success} && ( $Res{Status} // '' ) eq 'Synced' ) {
            $SyncedCount++;
        }
        elsif ( !$Res{Success} ) {
            $LastSyncOK = 0;
            $LastError  = $Res{Error} || 'sync failed';
            $LogObject->Log(
                Priority => 'error',
                Message  => "Redmine CronSync TicketID=$Row->{TicketID}: $LastError",
            );
        }
    }

    my $HealthTTL = 60 * 60 * 24 * 7;
    my $Now       = time();
    $CacheObject->Set(
        Type  => 'RedmineBridgeHealth',
        Key   => 'LastSyncAt',
        Value => $Now,
        TTL   => $HealthTTL,
    );
    $CacheObject->Set(
        Type  => 'RedmineBridgeHealth',
        Key   => 'LastSyncError',
        Value => $LastError,
        TTL   => $HealthTTL,
    );
    $CacheObject->Set(
        Type  => 'RedmineBridgeHealth',
        Key   => 'SyncedCount',
        Value => $SyncedCount,
        TTL   => $HealthTTL,
    );
    $CacheObject->Set(
        Type  => 'RedmineBridgeHealth',
        Key   => 'LastSyncOK',
        Value => $LastSyncOK ? 1 : 0,
        TTL   => $HealthTTL,
    );

    # Optionally warm escalate-form catalog (full Daemon timeout)
    if ( $Self->can('WarmCatalog') ) {
        eval { $Self->WarmCatalog(); 1; };
    }

    return 1;
}

sub CronRetry {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    return 1 if !$ConfigObject->Get('Redmine::Enabled');
    return 1 if !$ConfigObject->Get('Redmine::AutoRetry');

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $JSONObject   = $Kernel::OM->Get('Kernel::System::JSON');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');

    # K1: machine status code `error`, empty RedmineID
    my @TicketIDs = $TicketObject->TicketSearch(
        Result => 'ARRAY',
        UserID => 1,
        Limit  => $ConfigObject->Get('Redmine::RetryBatchLimit') || 20,
        DynamicField_RedmineEscalationStatus => {
            Equals => 'error',
        },
        DynamicField_RedmineID => {
            Empty => 1,
        },
    );

    TICKET:
    for my $TicketID (@TicketIDs) {
        my %Ticket = $TicketObject->TicketGet(
            TicketID      => $TicketID,
            DynamicFields => 1,
            UserID        => 1,
        );
        next TICKET if IsStringWithData( $Ticket{DynamicField_RedmineID} );

        my $RetryCount = 0 + ( $Ticket{DynamicField_RedmineRetryCount} || 0 );
        if ( $RetryCount >= 3 ) {
            $Self->_SetDF(
                TicketID => $TicketID,
                Name     => 'RedmineEscalationStatus',
                Value    => 'error_exhausted',
                UserID   => 1,
            );
            next TICKET;
        }

        my $PayloadRaw = $Ticket{DynamicField_RedmineRetryPayload} // '';
        my $Payload    = {};
        if ( IsStringWithData($PayloadRaw) ) {
            $Payload = $JSONObject->Decode( Data => $PayloadRaw ) || {};
            $Payload = {} if !IsHashRefWithData($Payload);
        }

        my $AssignedToID = $Payload->{AssignedToID};
        my $ProjectID    = $Payload->{ProjectID} // $Ticket{DynamicField_RedmineProjectID}
            // $ConfigObject->Get('Redmine::ProjectID');
        my $TrackerID = $Payload->{TrackerID} // $Ticket{DynamicField_RedmineTrackerID}
            // $ConfigObject->Get('Redmine::TrackerID');
        my $PriorityID = $Payload->{PriorityID} // $ConfigObject->Get('Redmine::PriorityID');
        my $DueDate    = $Payload->{DueDate};
        my $Subject    = $Payload->{Subject};
        my $Description = $Payload->{Description};
        my $MassIncident = $Payload->{MassIncident};

        # Missing assignee: try nothing further — exhaust to avoid spam
        if ( !IsNumber($AssignedToID) || !$AssignedToID ) {
            $Self->_SetDF(
                TicketID => $TicketID,
                Name     => 'RedmineEscalationStatus',
                Value    => 'error_exhausted',
                UserID   => 1,
            );
            my $Msg = 'Повтор эскалации остановлен: в RedmineRetryPayload нет AssignedToID.';
            my $Prev = $Ticket{DynamicField_RedmineLastError} // '';
            if ( $Msg ne $Prev ) {
                $Self->_SetDF(
                    TicketID => $TicketID,
                    Name     => 'RedmineLastError',
                    Value    => substr( $Msg, 0, 3800 ),
                    UserID   => 1,
                );
                $Self->_AddInternalArticle(
                    TicketID       => $TicketID,
                    UserID         => 1,
                    Subject        => 'Redmine: повтор эскалации исчерпан',
                    Body           => $Msg,
                    HistoryComment => '%%RedmineBridge',
                );
            }
            next TICKET;
        }

        my $NewCount = $RetryCount + 1;
        $Self->_SetDF(
            TicketID => $TicketID,
            Name     => 'RedmineRetryCount',
            Value    => "$NewCount",
            UserID   => 1,
        );

        my %Res = $Self->EscalateTicket(
            TicketID           => $TicketID,
            UserID             => 1,
            ProjectID          => $ProjectID,
            TrackerID          => $TrackerID,
            PriorityID         => $PriorityID,
            AssignedToID       => $AssignedToID,
            DueDate            => $DueDate,
            Subject            => $Subject,
            Description        => $Description,
            MassIncident       => $MassIncident,
            IncludeAttachments => $Payload->{IncludeAttachments},
        );

        if ( $Res{Success} ) {
            next TICKET;
        }

        my $Err  = $Res{Error} || 'unknown';
        my $Prev = $Ticket{DynamicField_RedmineLastError} // '';

        # Only article when error text changed (EscalateTicket may also set LastError)
        if ( $Err ne $Prev ) {
            $Self->_AddInternalArticle(
                TicketID       => $TicketID,
                UserID         => 1,
                Subject        => 'Redmine: ошибка повторной эскалации',
                Body           => "Попытка $NewCount/3.\nПричина: $Err",
                HistoryComment => '%%RedmineBridge',
            );
        }

        if ( $NewCount >= 3 ) {
            $Self->_SetDF(
                TicketID => $TicketID,
                Name     => 'RedmineEscalationStatus',
                Value    => 'error_exhausted',
                UserID   => 1,
            );
            $LogObject->Log(
                Priority => 'notice',
                Message  => "Redmine CronRetry TicketID=$TicketID exhausted after $NewCount attempts",
            );
        }
    }
    return 1;
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Parse Redmine::StatusSync value for a status name.
# Examples: "open|note" → state open + note; "open" → state only; "note" → note only.
sub _StatusSyncActions {
    my ( $Self, $StatusName ) = @_;

    return ( undef, 0 ) if !IsStringWithData($StatusName);

    my $Map = $Kernel::OM->Get('Kernel::Config')->Get('Redmine::StatusSync') || {};
    return ( undef, 0 ) if !IsHashRefWithData($Map);

    my $Raw = $Map->{$StatusName};
    return ( undef, 0 ) if !defined $Raw || !length $Raw;

    $Raw =~ s{\A\s+}{};
    $Raw =~ s{\s+\z}{};

    my $WriteNote = 0;
    if ( $Raw =~ s{\|note\z}{}i || $Raw =~ m{\Anote\z}i ) {
        $WriteNote = 1;
        $Raw = '' if $Raw =~ m{\Anote\z}i;
        $Raw =~ s{\s+\z}{};
    }

    my $State = length $Raw ? $Raw : undef;
    return ( $State, $WriteNote );
}

# Outbound OTRS→Redmine stamps (RU + legacy EN) — skip as inbound echo for this ticket.
sub _IsOutboundEchoNote {
    my ( $Self, %Param ) = @_;

    my $Notes = $Param{Notes} // '';
    return 0 if !length $Notes;

    my $TN = $Param{TicketNumber} // '';

    # Bridge journal stamps (RU) — plain / Textile / Markdown link-unlink notes
    return 1 if $Notes =~ m{\AЗаметка\s+OTRS\s+от\b}ms;
    return 1 if $Notes =~ m{\AТикет\s+OTRS\b.+\bпривязан\b}ms;
    return 1 if $Notes =~ m{\A(?:\#{1,6}\s+|h[1-6]\.\s+|\*\*)?(?:Привязка|Отвязка)(?:\s+тикета)?\s+OTRS\b}ms;
    return 1 if $Notes =~ m{[*_]Заметка\s+OTRS\s+\(мост\)[*_]}ms;
    return 1 if $Notes =~ m{[*_]?Служебная\s+запись\s+моста\s+OTRS\s*↔\s*Redmine[*_]?}ms;
    if ( length $TN ) {
        return 1 if $Notes =~ m{\AЗаметка\s+OTRS\s+от\s+.+\s+\(тикет\s+\Q$TN\E\)}ms;
        return 1 if $Notes =~ m{Тикет\s+OTRS\s+\Q$TN\E\s+(?:привязан|отвязан)}ms;
        return 1 if $Notes =~ m{\[(?:\Q$TN\E)\]\([^)]+\)}ms
            && $Notes =~ m{(?:Привязка|Отвязка)\s+OTRS}ms;
    }

    # Legacy English stamps (already written to Redmine before 1.0.7)
    return 1 if $Notes =~ m{\AOTRS\s+note\s+by\b}ms;
    return 1 if $Notes =~ m{\ALinked\s+OTRS\s+ticket\b}ms;
    if ( length $TN ) {
        return 1
            if $Notes =~ m{\AOTRS\s+note\s+by\s+.+\s+\(ticket\s+\Q$TN\E\)}ms;
        return 1 if $Notes =~ m{Linked\s+OTRS\s+ticket\s+\Q$TN\E\b}ms;
    }

    return 0;
}

# True if this journal entry includes a status_id attribute change.
sub _JournalHasStatusChange {
    my ( $Self, $Journal ) = @_;

    return 0 if !IsHashRefWithData($Journal);
    for my $Detail ( @{ $Journal->{details} || [] } ) {
        next if !IsHashRefWithData($Detail);
        return 1
            if ( $Detail->{property} // '' ) eq 'attr'
            && ( $Detail->{name} // '' ) eq 'status_id';
    }
    return 0;
}

sub _ArticleAlreadySyncedOutbound {
    my ( $Self, %Param ) = @_;
    return 0 if !$Param{TicketID} || !$Param{ArticleID};

    my $Marker  = "%%RedmineOutbound::$Param{ArticleID}";
    my $ArtID   = 0 + $Param{ArticleID};
    my @History = $Kernel::OM->Get('Kernel::System::Ticket')->HistoryGet(
        TicketID => $Param{TicketID},
        UserID   => 1,
    );
    for my $Row (@History) {
        my $Name = $Row->{Name} // '';
        return 1 if $Name eq $Marker;

        # K6: bridge-authored inbound / escalate notes — skip by history, not subject
        if ( ( 0 + ( $Row->{ArticleID} || 0 ) ) == $ArtID ) {
            return 1 if $Name =~ m{%%Redmine(?:Inbound|Bridge|Outbound)};
        }
    }
    return 0;
}

sub _MarkArticleSyncedOutbound {
    my ( $Self, %Param ) = @_;
    return if !$Param{TicketID} || !$Param{ArticleID};

    $Kernel::OM->Get('Kernel::System::Ticket')->HistoryAdd(
        Name         => "%%RedmineOutbound::$Param{ArticleID}",
        HistoryType  => 'Misc',
        TicketID     => $Param{TicketID},
        CreateUserID => $Param{UserID} || 1,
    );
    return 1;
}

# Prefer MaxJournalID (no second journals GET). Fallback GET when only IssueID given.
sub _BumpLastJournalID {
    my ( $Self, %Param ) = @_;
    return if !$Param{TicketID};

    my $UserID = $Param{UserID} || 1;
    my $Max    = defined $Param{MaxJournalID} ? ( 0 + $Param{MaxJournalID} ) : 0;

    if ( !$Max ) {
        return if !$Param{IssueID};
        my %Res = $Self->_Request(
            Method => 'GET',
            Path   => "/issues/$Param{IssueID}.json?include=journals",
        );
        return if !$Res{Success};

        for my $Journal ( @{ $Res{Data}->{issue}->{journals} || [] } ) {
            my $JID = 0 + ( $Journal->{id} || 0 );
            $Max = $JID if $JID > $Max;
        }
        return if !$Max;
    }

    my %Ticket = $Kernel::OM->Get('Kernel::System::Ticket')->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $UserID,
        Silent        => 1,
    );
    my $Last = 0 + ( $Ticket{DynamicField_RedmineLastJournalID} || 0 );
    return if $Max <= $Last;

    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineLastJournalID',
        Value    => "$Max",
        UserID   => $UserID,
    );
    return 1;
}

# After OTRS→Redmine uploads (escalate/outbound), seed cursor so inbound does not re-import.
sub _BumpLastAttachmentID {
    my ( $Self, %Param ) = @_;
    return if !$Param{TicketID};

    my $UserID = $Param{UserID} || 1;
    my $Max    = defined $Param{MaxAttachmentID} ? ( 0 + $Param{MaxAttachmentID} ) : 0;

    if ( !$Max ) {
        return if !$Param{IssueID};
        my %Res = $Self->_Request(
            Method => 'GET',
            Path   => "/issues/$Param{IssueID}.json?include=attachments",
        );
        return if !$Res{Success};

        for my $Att ( @{ $Res{Data}->{issue}->{attachments} || [] } ) {
            my $AID = 0 + ( $Att->{id} || 0 );
            $Max = $AID if $AID > $Max;
        }
        return if !$Max;
    }

    my %Ticket = $Kernel::OM->Get('Kernel::System::Ticket')->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 1,
        UserID        => $UserID,
        Silent        => 1,
    );
    my $Last = 0 + ( $Ticket{DynamicField_RedmineLastAttachmentID} || 0 );
    return if $Max <= $Last;

    $Self->_SetDF(
        TicketID => $Param{TicketID},
        Name     => 'RedmineLastAttachmentID',
        Value    => "$Max",
        UserID   => $UserID,
    );
    return 1;
}

sub _BuildDescription {
    my ( $Self, %Ticket ) = @_;

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my @Articles      = $ArticleObject->ArticleList( TicketID => $Ticket{TicketID} );

    # Prefer the first customer message (problem statement), not the newest article
    # (often an auto-ack: «Ваше обращение зарегистрировано…»).
    my $CustomerBody = '';
    my $FallbackBody = '';

    ARTICLE:
    for my $Meta (@Articles) {
        my $Backend = $ArticleObject->BackendForArticle( %{$Meta} );
        my %Article = $Backend->ArticleGet(
            TicketID  => $Ticket{TicketID},
            ArticleID => $Meta->{ArticleID},
        );
        next ARTICLE if !%Article;

        my $Plain = $Article{Body} // '';
        if ( ( $Article{ContentType} // '' ) =~ m{html}i ) {
            $Plain = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToAscii( String => $Plain );
        }
        $Plain =~ s{\A\s+}{};
        $Plain =~ s{\s+\z}{};
        next ARTICLE if !length $Plain;
        next ARTICLE if $Self->_IsAutoReplyArticle(%Article);

        my $Sender = lc( $Article{SenderType} // '' );
        if ( $Sender eq 'customer' ) {
            $CustomerBody = $Plain;
            last ARTICLE;
        }
        if ( !length $FallbackBody ) {
            $FallbackBody = $Plain;
        }
    }

    my $ZoomURL = '';
    if ( $Self->can('TicketZoomURL') ) {
        $ZoomURL = $Self->TicketZoomURL( TicketID => $Ticket{TicketID} ) || '';
    }
    elsif ( $Self->can('_TicketZoomURL') ) {
        $ZoomURL = $Self->_TicketZoomURL( TicketID => $Ticket{TicketID} ) || '';
    }

    my $Desc = "Тикет OTRS: $Ticket{TicketNumber}\n";
    $Desc .= "Ссылка OTRS: $ZoomURL\n" if length $ZoomURL;
    $Desc .= "Очередь: $Ticket{Queue}\n";
    $Desc .= "Клиент: " . ( $Ticket{CustomerUserID} || '-' ) . "\n";
    $Desc .= "Эскалировал: " . ( $Ticket{AgentLabel} || '-' ) . "\n";
    $Desc .= "\n---\n\n";
    $Desc .= ( length $CustomerBody ? $CustomerBody : $FallbackBody ) || '(нет текста статьи)';
    return $Desc;
}

# Auto-ack / autoresponse mail — not useful as Redmine issue description.
sub _IsAutoReplyArticle {
    my ( $Self, %Article ) = @_;

    my $Sender = lc( $Article{SenderType} // '' );
    return 1 if $Sender eq 'system';

    my $Subject = $Article{Subject} // '';
    return 1
        if $Subject =~ m{(?i)автоответ|auto[\s\-]?reply|out\s*of\s*office|создание\s+заявки};

    my $Body = $Article{Body} // '';
    if ( ( $Article{ContentType} // '' ) =~ m{html}i ) {
        $Body = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToAscii( String => $Body );
    }
    return 1
        if $Body =~ m{(?i)ваше\s+обращение\s+зарегистрировано|обращение\s+зарегистрировано\s+под\s+номером};
    return 1
        if $Body =~ m{(?i)your\s+(?:request|ticket|inquiry)\s+has\s+been\s+(?:received|registered)};

    return 0;
}

1;
