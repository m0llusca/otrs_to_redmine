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
use File::Temp ();
use Digest::SHA qw(sha256_hex);
use Scalar::Util qw(refaddr);

# Methods are mixed into Kernel::System::Redmine via use parent.
# $Self is the Redmine object. Use Kernel::OM normally.
# NO sub new — facade owns construction.

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
    'Kernel::System::DB',
    'Kernel::System::DynamicField',
    'Kernel::System::HTMLUtils',
    'Kernel::System::JSON',
    'Kernel::System::Log',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
);

# ---------------------------------------------------------------------------
# Inbound sync (Redmine → OTRS)
# ---------------------------------------------------------------------------

sub SyncTicketFromRedmine {
    my ( $Self, %Param ) = @_;
    return ( Success => 0, Error => 'Need TicketID' ) if !$Param{TicketID};
    return ( Success => 1, Status => 'Disabled' )
        if !$Kernel::OM->Get('Kernel::Config')->Get('Redmine::Enabled');
    return $Self->_WithTicketSyncLease( TicketID => $Param{TicketID}, Work => $Param{Work}, Callback => sub {
        my ( $Key, $Token ) = @_;
        return $Self->_SyncTicketFromRedmineLocked( %Param, LeaseKey => $Key, LeaseToken => $Token );
    } );
}

sub _WithTicketSyncLease {
    my ( $Self, %Param ) = @_;
    my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
    my $Key = 'Ticket::' . $Param{TicketID};
    my $Token = eval { $Store->LockAcquire( Key => $Key ) };
    if ($@) {
        $Kernel::OM->Get('Kernel::System::Log')->Log( Priority => 'error',
            Message => 'Redmine sync lock: ' . $Self->_ScrubCredentials($@) );
        return ( Success => 0, Status => 'Error', Error => 'Не удалось получить блокировку синхронизации OTRS.' );
    }
    return ( Success => 0, Status => 'Busy', RetryAfterSeconds => 2,
        Error => 'Синхронизация этого тикета уже выполняется.' ) if !$Token;
    $Self->_InvalidateSyncTicket( TicketID => $Param{TicketID} );
    local $Self->{_TicketSyncLease} = { Key => $Key, Token => $Token, RenewedAt => time(), Work => $Param{Work} };
    my %Result = eval { $Param{Callback}->( $Key, $Token ) };
    my $Error = $@;
    eval { $Store->LockRelease( Key => $Key, Token => $Token ) };
    if ($Error) {
        $Kernel::OM->Get('Kernel::System::Log')->Log( Priority => 'error',
            Message => 'Redmine sync: ' . $Self->_ScrubCredentials($Error) );
        return ( Success => 0, Status => 'Error', Error => 'Не удалось завершить синхронизацию OTRS; повтор сохранён.' );
    }
    return %Result;
}

# Keep long multi-file operations alive, but never resurrect expired ownership.
sub _CheckTicketSyncLease {
    my ($Self) = @_;
    my $Lease = $Self->{_TicketSyncLease} or return 1;
    my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
    my $Now = time();
    if ($Now - $Lease->{RenewedAt} >= 30) {
        $Store->RenewLock(%$Lease, Now => $Now) or die 'Ticket synchronization lease lost';
        $Store->RenewIssueLease(%{$Lease->{Work}}, Now => $Now)
            or die 'Issue synchronization lease lost' if $Lease->{Work};
        $Lease->{RenewedAt} = $Now;
    }
    else {
        $Store->LockValid(%$Lease, Now => $Now) or die 'Ticket synchronization lease lost';
    }
    return 1;
}

sub _InvalidateSyncTicket {
    my ( $Self, %Param ) = @_;
    $Kernel::OM->Get('Kernel::System::Cache')->Delete(
        Type => 'DynamicFieldValue', Key => 'ValueGet::ObjectID::' . $Param{TicketID} );
    $Kernel::OM->Get('Kernel::System::Ticket')->_TicketCacheClear( TicketID => $Param{TicketID} );
    return 1;
}

sub _CommitInbound {
    my ( $Self, %Param ) = @_;
    $Self->_CheckTicketSyncLease();
    my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
    my $DBH = $Store->BeginTransaction( LockKey => $Param{LeaseKey}, Token => $Param{LeaseToken} );
    return ( Success => 0, Error => 'Блокировка синхронизации истекла; повтор сохранён.' ) if !$DBH;
    my %EventSizes = map { defined $_ ? ( refaddr($_) => scalar @{ $_->{EventHandlerPipe} || [] } ) : () }
        @{ $Kernel::OM->{EventHandlers} || [] };
    my $Skipped;
    my $OK = eval {
        # Revalidate the live link after network IO and fence the issue generation.
        my $Field = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet( Name => 'RedmineID' );
        my $STH = $DBH->prepare('SELECT value_text FROM dynamic_field_value WHERE field_id = ? AND object_id = ?');
        $STH->execute( $Field->{ID}, $Param{TicketID} ) or die 'Cannot validate current Redmine link';
        my ($ID) = $STH->fetchrow_array(); $STH->finish();
        if ( !defined $ID || "$ID" ne "$Param{IssueID}" ) { $Skipped = 1; }
        else {
            if ( my $Work = $Param{Work} ) {
                my $SQL = 'SELECT issue_key FROM redmine_sync_issue WHERE issue_key = ? AND lease_token = ? AND round_generation = ? AND lease_until > ?';
                $SQL .= ' FOR UPDATE' if lc($DBH->{Driver}{Name}) ne 'sqlite';
                my $Guard = $DBH->prepare($SQL);
                $Guard->execute( $Work->{IssueKey}, $Work->{Token}, $Work->{RoundGeneration}, time() )
                    or die 'Cannot fence delivery generation';
                my @Owner = $Guard->fetchrow_array(); $Guard->finish();
                die 'Delivery round ownership changed' if !@Owner;
            }
            $Param{Commit}->();
            if ( my $Work = $Param{Work} ) {
                $Store->Progress( %$Work, AfterTicketID => $Param{TicketID} )
                    or die 'Delivery progress changed';
            }
        }
        $DBH->commit() or die 'Cannot commit inbound update';
        1;
    };
    my $Error = $@;
    if (!$OK) {
        eval { $DBH->rollback() if !$DBH->{AutoCommit} };
        # OTRS has deferred transaction listeners outside DBI. Cancel only events
        # from this failed transaction, retaining earlier independent state events.
        for my $Handler ( @{ $Kernel::OM->{EventHandlers} || [] } ) {
            next if !$Handler || !$Handler->{EventHandlerPipe};
            my $Length = $EventSizes{ refaddr($Handler) } || 0;
            splice @{ $Handler->{EventHandlerPipe} }, $Length
                if @{ $Handler->{EventHandlerPipe} } > $Length;
        }
        $Kernel::OM->Get('Kernel::System::Log')->Log( Priority => 'error',
            Message => 'Redmine inbound transaction: ' . $Self->_ScrubCredentials($Error) );
    }
    $Self->_InvalidateSyncTicket( TicketID => $Param{TicketID} );
    return ( Success => 0, Error => 'Не удалось записать обновление OTRS; повтор сохранён.' ) if !$OK;
    return ( Success => 1, Status => $Skipped ? 'Skip' : 'Synced',
        ProgressCommitted => $Param{Work} && !$Skipped ? 1 : 0 );
}

sub _SyncTicketFromRedmineLocked {
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
    return ( Success => 1, Status => 'Skip' ) if defined $Param{ExpectedIssueID}
        && "$IssueID" ne "$Param{ExpectedIssueID}";
    return ( Success => 0, Status => 'Error', Error => 'RedmineID is not numeric' )
        if !IsNumber($IssueID);

    # Scope is one issue group in CronSync, or one manual invocation.
    my $IssueCache = $Param{IssueCache} || {};
    $IssueCache = {} if defined $IssueCache->{IssueID} && $IssueCache->{IssueID} ne $IssueID;
    $IssueCache->{IssueID} = $IssueID;
    my $SyncAtt = $ConfigObject->Get('Redmine::SyncAttachments') ? 1 : 0;
    if ( !exists $IssueCache->{Snapshot} ) {
        $IssueCache->{Snapshot} = { $Self->_Request(
            Method => 'GET', Path => "/issues/$IssueID.json",
        ) };
    }
    my %Res = %{ $IssueCache->{Snapshot} };
    return ( Success => 0, Status => 'Error', Error => $Res{Error} ) if !$Res{Success};
    my $Issue = $Res{Data}->{issue};
    return ( Success => 0, Status => 'Error', Error => 'Redmine response missing issue' )
        if !IsHashRefWithData($Issue);
    my $StatusName = $Self->_DecodeUTF8( $Issue->{status}->{name} || '' );
    my $UpdatedOn = $Issue->{updated_on} // '';
    my $StoredOn = $Ticket{DynamicField_RedmineLastUpdatedOn} // '';
    my $AttachmentOn = $Ticket{DynamicField_RedmineLastAttachmentSyncOn} // '';
    my $AppliedState = $Ticket{State} // '';
    my $ApplyMappedState = sub {
        my ($State) = @_;
        return if !$State || $State eq $AppliedState;
        $Self->_CheckTicketSyncLease();
        $TicketObject->TicketStateSet( TicketID => $Param{TicketID}, State => $State,
            UserID => $UserID, SendNoNotification => 1 ) or die 'Cannot apply mapped OTRS state';
        $AppliedState = $State;
    };
    my $ApplyState = sub {
        my ($Name) = @_;
        return if !length $Name || $Name eq ( $Ticket{DynamicField_RedmineStatus} // '' );
        my ($State) = $Self->_StatusSyncActions($Name);
        $ApplyMappedState->($State);
    };
    my $NeedDetails = $Param{ForceDetails} || !length($StoredOn)
        || ( length($UpdatedOn) && $UpdatedOn gt $StoredOn )
        || $StatusName ne ( $Ticket{DynamicField_RedmineStatus} // '' )
        || ( $SyncAtt && ( !length($AttachmentOn) || $UpdatedOn gt $AttachmentOn ) );
    my @Journals;
    if ($NeedDetails) {
        if ( !exists $IssueCache->{Details} ) {
            my $Include = $SyncAtt ? 'journals,attachments' : 'journals';
            $IssueCache->{Details} = { $Self->_Request(
                Method => 'GET', Path => "/issues/$IssueID.json?include=$Include",
            ) };
        }
        my $Details = $IssueCache->{Details};
        if ( !$Details->{Success} ) {
            $ApplyState->($StatusName);
            return ( Success => 0, Status => 'Error', Error => $Details->{Error} || 'Issue details unavailable' );
        }
        $Issue = $Details->{Data}->{issue};
        if ( !IsHashRefWithData($Issue) ) {
            $ApplyState->($StatusName);
            return ( Success => 0, Status => 'Error', Error => 'Redmine response missing issue details' );
        }
        @Journals = @{ $Issue->{journals} || [] };
        $StatusName = $Self->_DecodeUTF8( $Issue->{status}->{name} || $StatusName );
        $UpdatedOn = $Issue->{updated_on} // $UpdatedOn;
    }
    else {
        $Self->_RecordSyncCheck( TicketID => $Param{TicketID} );
        return ( Success => 1, Status => 'Synced', IssueStatus => $StatusName );
    }

    # A grouped worker snapshot can predate a completed manual sync. Do not
    # downgrade status or emit a second fallback note for an older snapshot.
    my $SeenJournal = 0;
    for my $Journal (@Journals) {
        $SeenJournal = $Journal->{id} if ($Journal->{id} || 0) > $SeenJournal;
    }
    my $StoredJournal = 0 + ($Ticket{DynamicField_RedmineLastJournalID} || 0);
    if ($Param{Work} && !$Param{RefreshedSnapshot} && $UpdatedOn eq $StoredOn
        && $SeenJournal < $StoredJournal && $StatusName ne ($Ticket{DynamicField_RedmineStatus} // '')) {
        # Empty/private history cannot prove age. Fetch once under this ticket's
        # lease, then share the fresh snapshot with the remaining sibling tickets.
        my $Include = $SyncAtt ? 'journals,attachments' : 'journals';
        my %Fresh = $Self->_Request(Method => 'GET', Path => "/issues/$IssueID.json?include=$Include");
        return (Success => 0, Status => 'Error', Error => $Fresh{Error} || 'Issue details unavailable',
            RetryAfterSeconds => $Fresh{RetryAfterSeconds} || 0) if !$Fresh{Success};
        delete @Fresh{qw(Content ContentFile)};
        $IssueCache->{Snapshot} = $IssueCache->{Details} = \%Fresh;
        delete @{$IssueCache}{qw(JournalCandidates JournalMax NormalizedJournals)};
        return $Self->_SyncTicketFromRedmineLocked(%Param, IssueCache => $IssueCache, RefreshedSnapshot => 1);
    }
    if ((length($StoredOn) && length($UpdatedOn) && $UpdatedOn lt $StoredOn && $SeenJournal <= $StoredJournal)
        || ($UpdatedOn eq $StoredOn && $SeenJournal > 0 && $SeenJournal < $StoredJournal)) {
        return (Success => 1, Status => 'Skip', IssueStatus => $Ticket{DynamicField_RedmineStatus});
    }

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $Backend       = $ArticleObject->BackendForChannel( ChannelName => 'Internal' );

    my $OldStatus     = $Ticket{DynamicField_RedmineStatus} // '';
    my $StatusChanged = length $StatusName && $OldStatus ne $StatusName ? 1 : 0;
    my ( $MappedState, $WriteNote ) = $StatusChanged
        ? $Self->_StatusSyncActions($StatusName)
        : ( undef, 0 );

    # One inbound OTRS note per sync run: status / comments / attachments as blocks.
    my $LastJournal       = 0 + ( $Ticket{DynamicField_RedmineLastJournalID} || 0 );
    my $MaxJournal        = $LastJournal;
    my $StatusNoteEmitted = 0;
    my $TicketNumber      = $Ticket{TicketNumber} // '';

    my @StatusLines;
    my @CommentBlocks;
    my @AttachmentFiles;    # { Content, ContentType, Filename }
    my @AttachmentLines;    # text lines for the «Вложения» block

    if ( !exists $IssueCache->{JournalCandidates} ) {
        my $Max = 0;
        my @Candidates;
        for my $Journal ( sort { ($a->{id}||0) <=> ($b->{id}||0) } @Journals ) {
            my $ID = 0 + ( $Journal->{id} || 0 );
            $Max = $ID if $ID > $Max;
            push @Candidates, $Journal if $Self->_JournalHasStatusChange($Journal);
        }
        $IssueCache->{JournalMax} = $Max;
        $IssueCache->{JournalCandidates} = \@Candidates;
    }
    $MaxJournal = $IssueCache->{JournalMax} if $IssueCache->{JournalMax} > $MaxJournal;
    my $NewStatusJournal = 0;
    JOURNAL:
    for my $Journal ( @{ $IssueCache->{JournalCandidates} } ) {
        my $JID = 0 + ( $Journal->{id} || 0 );
        next JOURNAL if $JID <= $LastJournal;
        $NewStatusJournal = 1;
        my ($Detail) = grep { ($_->{property}//'') eq 'attr' && ($_->{name}//'') eq 'status_id' }
            @{ $Journal->{details} || [] };
        my $Target = $StatusName;
        my $Origin = $OldStatus;
        if ( defined $Detail->{new_value} && length $Detail->{new_value} ) {
            my %Names = $Self->_IssueStatusNames( IssueCache => $IssueCache, RequiredID => $Detail->{new_value} );
            if (!$Names{Success}) {
                $ApplyState->($StatusName);
                return ( Success => 0, Status => 'Error', Error => $Names{Error} );
            }
            $Target = defined $Issue->{status}->{id} && "$Detail->{new_value}" eq "$Issue->{status}->{id}"
                ? $StatusName : $Names{Names}->{ $Detail->{new_value} };
            return ( Success => 0, Status => 'Error', Error => 'Не найден статус Redmine из журнала.' )
                if !defined $Target;
            $Origin = $Names{Names}->{ $Detail->{old_value} } // $OldStatus;
        }
        my ( $JournalState, $JournalNote ) = $Self->_StatusSyncActions($Target);
        next JOURNAL if !$JournalNote;
        my $Normalized = $IssueCache->{NormalizedJournals}->{$JID};
        if (!$Normalized) {
            my $Notes = $Self->_DecodeUTF8( $Journal->{notes} // '' );
            if ( $Notes =~ m{<\s*(?:p|div|br|span)\b}i ) {
                $Notes = $Kernel::OM->Get('Kernel::System::HTMLUtils')->ToAscii( String => $Notes );
            }
            $Notes =~ s{\A\s+}{}; $Notes =~ s{\s+\z}{};
            my $Author = $Self->_DecodeUTF8( $Journal->{user}->{name} || $Journal->{user}->{login} || 'Redmine' );
            $Normalized = $IssueCache->{NormalizedJournals}->{$JID} = { Notes => $Notes, Author => $Author };
        }
        my $StatusPart = 'Статус Redmine изменён';
        $StatusPart .= " с «$Origin»" if length $Origin;
        $StatusPart .= " на «$Target».";
        $StatusPart .= " Состояние тикета OTRS: $JournalState." if $JournalState && $Target eq $StatusName;
        $StatusPart .= " Автор в Redmine: $Normalized->{Author}.";
        push @StatusLines, $StatusPart;
        $StatusNoteEmitted = 1;
        if ( length $Normalized->{Notes} && !$Self->_IsOutboundEchoNote(
            Notes => $Normalized->{Notes}, TicketNumber => $TicketNumber,
        ) ) {
            push @CommentBlocks, "$Normalized->{Author}:\n$Normalized->{Notes}";
        }
    }
    # Replay all eligible notes, but apply only the current mapped state once.
    # An ordinary comment must not change an agent override or replay old states.
    if ($StatusChanged || $NewStatusJournal) {
        my ($FinalMappedState) = $Self->_StatusSyncActions($StatusName);
        $ApplyMappedState->($FinalMappedState);
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

    # Attachments from Redmine:
    # - file alone (no status note / comment) → only advance cursor (no OTRS article, no loop)
    # - with status/comment → download and attach to the same consolidated note
    my $LastAtt = 0 + ( $Ticket{DynamicField_RedmineLastAttachmentID} || 0 );
    my $OldLastAtt = $LastAtt;
    if ($SyncAtt) {
        my ( $MaxBytes, $MaxTotal, $MaxCount ) = $Self->_AttachmentLimits();
        my $TotalBytes = 0;
        my $DownloadAttempts = 0;
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
                $LastAtt = $AID;
                next ATT;
            }

            my $KnownSize = 0 + ( $Att->{filesize} // $Att->{file_size} // 0 );

            if ( $KnownSize > 0 && $KnownSize > $MaxBytes ) {
                push @AttachmentLines,
                    "• $Filename — не импортировано (размер $KnownSize байт > лимита $MaxBytes).";
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
                $LastAtt = $AID;
                next ATT;
            }

            if ( @AttachmentFiles >= $MaxCount || $DownloadAttempts >= $MaxCount
                || $TotalBytes >= $MaxTotal || $TotalBytes + $KnownSize > $MaxTotal ) {
                push @AttachmentLines, "• $Filename — не импортировано (общий лимит вложений).";
                $LastAtt = $AID;
                next ATT;
            }
            # Shared disk spool: no binary payloads retained between sibling tickets.
            my $File = $IssueCache->{Files}->{$AID};
            if (!$File) {
                if ( my $Failure = $IssueCache->{FileErrors}->{$AID} ) {
                    return ( Success => 0, Status => 'Error', %$Failure );
                }
                $DownloadAttempts++;
                my $Remaining = $MaxTotal - $TotalBytes;
                my $DownloadLimit = $MaxBytes < $Remaining ? $MaxBytes : $Remaining;
                my $Temp = File::Temp->new( UNLINK => 1 );
                binmode $Temp;
                $Self->_CheckTicketSyncLease();
                my %FileRes = $Self->_Request(
                    Method => 'GET', Path => $Rel, ExpectJSON => 0,
                    ContentFile => $Temp, MaxResponseBytes => $DownloadLimit,
                );
                $Self->_CheckTicketSyncLease();
                if ( !$FileRes{Success} ) {
                    if ( $FileRes{TooLarge} ) {
                        push @AttachmentLines, "• $Filename — не импортировано (превышен лимит размера).";
                        $LastAtt = $AID;
                        next ATT;
                    }
                    my $Failure = { Error => $FileRes{Error} || 'Attachment download failed',
                        RetryAfterSeconds => $FileRes{RetryAfterSeconds} || 0 };
                    $IssueCache->{FileErrors}->{$AID} = $Failure;
                    return ( Success => 0, Status => 'Error', %$Failure );
                }
                my $Size = $FileRes{ContentLength};
                # At most MaxCount open spool handles in the group.
                if ( scalar keys %{ $IssueCache->{Files} || {} } >= $MaxCount ) {
                    my ($Evict) = sort { $a <=> $b } keys %{ $IssueCache->{Files} };
                    delete $IssueCache->{Files}->{$Evict};
                }
                $File = $IssueCache->{Files}->{$AID} = { Handle => $Temp, Size => $Size };
            }
            if ( $TotalBytes + $File->{Size} > $MaxTotal ) {
                push @AttachmentLines, "• $Filename — не импортировано (общий лимит вложений).";
                $LastAtt = $AID;
                next ATT;
            }
            seek( $File->{Handle}, 0, 0 ) or return ( Success => 0, Error => 'Cannot rewind attachment' );
            my $Bin = '';
            my $Read = read( $File->{Handle}, $Bin, $MaxTotal - $TotalBytes + 1 );
            return ( Success => 0, Error => 'Cannot read attachment spool' ) if !defined $Read;
            if ( $TotalBytes + $Read > $MaxTotal ) {
                push @AttachmentLines, "• $Filename — не импортировано (общий лимит вложений).";
                $LastAtt = $AID;
                next ATT;
            }
            if ( !length $Bin ) { $LastAtt = $AID; next ATT; }
            $TotalBytes += length $Bin;

            push @AttachmentFiles, {
                Content     => $Bin,
                ContentType => $Att->{content_type} || 'application/octet-stream',
                Filename    => $Filename,
            };

            $LastAtt = $AID;
        }
    }

    my $Note;
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

        $Note = \%Create;
    }

    my %Committed = $Self->_CommitInbound( TicketID => $Param{TicketID}, IssueID => $IssueID,
        LeaseKey => $Param{LeaseKey}, LeaseToken => $Param{LeaseToken}, Work => $Param{Work}, Commit => sub {
        if ($Note) {
            my %Create = %$Note;
            my $Files = delete $Create{Attachment};
            my $ArticleID = $Backend && $Backend->ArticleCreate(%Create);
            die 'Cannot create inbound OTRS note' if !$ArticleID;
            # ArticleCreate ignores storage return values in OTRS 6. Check the
            # public write API explicitly before committing note and checkpoints.
            for my $File ( @{ $Files || [] } ) {
                $Backend->ArticleWriteAttachment( %$File, ArticleID => $ArticleID, UserID => $UserID )
                    or die 'Cannot store inbound attachment';
            }
        }
        my $Set = sub {
            my ( $Name, $Value ) = @_;
            $Self->_SetDF( TicketID => $Param{TicketID}, Name => $Name, Value => $Value, UserID => $UserID )
                or die "Cannot checkpoint $Name";
        };
        $Set->('RedmineStatus', $StatusName) if $StatusChanged;
        for my $Item (
            [ 'RedmineLastJournalID', $MaxJournal ],
            [ 'RedmineLastAttachmentID', $LastAtt ],
        ) {
            my $Current = 0 + ($Self->_GetDF(TicketID=>$Param{TicketID},Name=>$Item->[0])||0);
            $Set->($Item->[0], "$Item->[1]") if $Item->[1] > $Current;
        }
        for my $Name ( 'RedmineLastUpdatedOn', ( $SyncAtt ? 'RedmineLastAttachmentSyncOn' : () ) ) {
            my $Current = $Self->_GetDF(TicketID=>$Param{TicketID},Name=>$Name) // '';
            $Set->($Name, $UpdatedOn) if length $UpdatedOn && $UpdatedOn gt $Current;
        }
    } );
    return %Committed if !$Committed{Success} || ($Committed{Status}//'') eq 'Skip';
    $Self->_RecordSyncCheck( TicketID => $Param{TicketID} );

    return ( Success => 1, Status => 'Synced', IssueStatus => $StatusName,
        ProgressCommitted => $Committed{ProgressCommitted} );
}

sub _RecordSyncCheck {
    my ( $Self, %Param ) = @_;
    $Kernel::OM->Get('Kernel::System::Cache')->Set(
        Type => 'RedmineBridgeHealth', Key => 'TicketCheck::' . $Param{TicketID},
        Value => { At => time() }, TTL => 60 * 60 * 24 * 7,
    );
    return 1;
}

sub _IssueStatusNames {
    my ( $Self, %Param ) = @_;
    my $Group = $Param{IssueCache};
    return %{ $Group->{StatusNames} } if $Group->{StatusNames}
        && (!$Group->{StatusNames}->{Success} || !defined $Param{RequiredID}
            || exists $Group->{StatusNames}->{Names}->{$Param{RequiredID}});
    my $Config = $Kernel::OM->Get('Kernel::Config');
    my $Key = sha256_hex( ($Config->Get('Redmine::BaseURL')//'') . "\0" . ($Config->Get('Redmine::APIKey')//'') );
    my $Cache = $Kernel::OM->Get('Kernel::System::Cache');
    my $Names = $Cache->Get( Type => 'RedmineBridgeCatalog', Key => 'StatusNames::' . $Key );
    if (!$Names || (defined $Param{RequiredID} && !exists $Names->{$Param{RequiredID}})) {
        my %Reply = $Self->_Request( Method => 'GET', Path => '/issue_statuses.json' );
        if ( !$Reply{Success} ) {
            $Group->{StatusNames} = { Success => 0, Error => $Reply{Error} || 'Не удалось получить статусы Redmine.' };
            return %{ $Group->{StatusNames} };
        }
        $Names = { map { $_->{id} => $Self->_DecodeUTF8($_->{name}) }
            @{ $Reply{Data}->{issue_statuses} || [] } };
        return ( Success => 0, Error => 'Redmine вернул пустой список статусов.' ) if !%$Names;
        $Cache->Set( Type => 'RedmineBridgeCatalog', Key => 'StatusNames::' . $Key,
            Value => $Names, TTL => 900 );
    }
    $Group->{StatusNames} = { Success => 1, Names => $Names };
    return %{ $Group->{StatusNames} };
}

# Admin "Run sync now": detect all linked issues, then perform one bounded
# delivery batch immediately. The daemon dispatches remaining durable work.
sub CronSync {
    my ($Self) = @_;
    return 1 if !$Self->_SyncEnabled();
    return if !$Self->PollSync();
    my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
    my $Source = $Store->SourceKey();
    my $Rows = $Store->ReadyIssues(SourceKey=>$Source,Limit=>1);
    if (@$Rows) {
        my $Result = $Self->ProcessSyncBatch(SourceKey=>$Source,SeedIssueKey=>$Rows->[0]{key});
        return if !$Result->{Success};
    }
    return $Self->DispatchSync();
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

    my $Last = 0 + ( $Self->_GetDF( TicketID => $Param{TicketID},
        Name => 'RedmineLastJournalID' ) || 0 );
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

    my $Last = 0 + ( $Self->_GetDF( TicketID => $Param{TicketID},
        Name => 'RedmineLastAttachmentID' ) || 0 );
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
