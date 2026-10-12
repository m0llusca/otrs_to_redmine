# Copyright (C) 2026 OTRSRedmineBridge. GPL version 3 or later.
package Kernel::System::Redmine::SyncCoordinator;
use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use JSON::PP ();

our @ObjectDependencies = (
    'Kernel::Config', 'Kernel::System::Cache', 'Kernel::System::DB',
    'Kernel::System::DynamicField', 'Kernel::System::Redmine::SyncStore',
    'Kernel::System::Daemon::SchedulerDB', 'Kernel::System::Log',
);

sub _SyncNow { return time(); }
sub _SyncEnabled {
    my $Config = $Kernel::OM->Get('Kernel::Config');
    return $Config->Get('Redmine::Enabled') && $Config->Get('Redmine::InboundSync');
}
sub _SyncInteger {
    my ($Value, $Default, $Min, $Max) = @_;
    $Value = $Default if !defined $Value || $Value !~ /\A\d+\z/;
    $Value = $Min if $Value < $Min;
    $Value = $Max if defined $Max && $Value > $Max;
    return 0 + $Value;
}
sub _SyncHealth {
    my ($Self, %Param) = @_;
    my $Cache = $Kernel::OM->Get('Kernel::System::Cache');
    my $Kind = $Param{Kind} || 'Poll';
    my $Error = $Param{Error} || '';
    if ($Kind eq 'Worker' && !$Error) {
        # A successful slice must not hide another issue's durable delivery error.
        my $Read = eval {
            my $Source = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore')->SourceKey();
            my $DB = $Kernel::OM->Get('Kernel::System::DB');
            die "Cannot read Redmine delivery health\n" if !$DB->Prepare(
                SQL => "SELECT last_error FROM redmine_sync_issue WHERE source_key = ? AND last_error IS NOT NULL AND (retry_count > 0 OR first_failed_ticket_id > 0)",
                Bind => [\$Source], Limit => 1);
            ($Error) = $DB->FetchrowArray();
            $Error ||= '';
            1;
        };
        $Error = 'Cannot read Redmine delivery health' if !$Read;
    }
    $Error = $Self->_ScrubCredentials($Error) if $Self->can('_ScrubCredentials');
    $Error = substr($Error, 0, 500);
    my %Values = (LastSyncAt => $Self->_SyncNow(), $Kind . 'Error' => $Error);
    $Values{SyncedCount} = $Param{Count} if defined $Param{Count};
    for my $Key (keys %Values) {
        $Cache->Set(Type => 'RedmineBridgeHealth', Key => $Key, Value => $Values{$Key},
            TTL => 604800, CacheInMemory => 0, CacheInBackend => 1);
    }
    my $LastError = $Error;
    for my $Other (qw(Poll Worker Dispatch)) {
        next if $Other eq $Kind;
        $LastError ||= $Cache->Get(Type => 'RedmineBridgeHealth', Key => $Other . 'Error',
            CacheInMemory => 0, CacheInBackend => 1) || '';
    }
    $Cache->Set(Type => 'RedmineBridgeHealth', Key => 'LastSyncError', Value => $LastError,
        TTL => 604800, CacheInMemory => 0, CacheInBackend => 1);
    $Cache->Set(Type => 'RedmineBridgeHealth', Key => 'LastSyncOK', Value => $LastError ? 0 : 1,
        TTL => 604800, CacheInMemory => 0, CacheInBackend => 1);
    return 1;
}

# Only linked IDs and a streaming digest survive this projection; no TicketGet.
sub _SyncProjection {
    my ($Self) = @_;
    my $Field = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(Name => 'RedmineID');
    die "RedmineID dynamic field unavailable\n" if !$Field || !$Field->{ID};
    my $FieldID = $Field->{ID};
    my $Config = $Kernel::OM->Get('Kernel::Config');
    my $Fingerprint = JSON::PP->new->canonical->encode({
        StatusSync => $Config->Get('Redmine::StatusSync') || {},
        SyncAttachments => $Config->Get('Redmine::SyncAttachments') ? 1 : 0,
        NotifyOnStatusNote => $Config->Get('Redmine::NotifyOnStatusNote') ? 1 : 0,
    });
    my $Archive = $Config->Get('Ticket::ArchiveSystem') ? 'AND t.archive_flag = 0 ' : '';
    my $DB = $Kernel::OM->Get('Kernel::System::DB');
    my ($After, %Issues) = (0);
    while (1) {
        die "Cannot read Redmine link projection\n" if !$DB->Prepare(
            SQL => 'SELECT t.id, v.value_text FROM ticket t INNER JOIN dynamic_field_value v '
                . 'ON v.object_id = t.id WHERE v.field_id = ? AND t.id > ? '
                . "AND v.value_text IS NOT NULL " . $Archive . 'ORDER BY t.id',
            Bind => [\$FieldID, \$After], Limit => 500);
        my $Count = 0;
        while (my @Row = $DB->FetchrowArray()) {
            $Count++;
            $After = $Row[0];
            next if $Row[1] !~ /\A[1-9]\d*\z/;
            my $Issue = $Issues{$Row[1]} ||= {
                Count => 0, Digest => Digest::SHA->new(256)->add(encode_utf8($Fingerprint), "\0") };
            $Issue->{Count}++;
            $Issue->{Digest}->add($Row[0], "\0");
        }
        last if $Count < 500;
    }
    for my $Issue (values %Issues) {
        $Issue->{LinksHash} = delete($Issue->{Digest})->hexdigest();
    }
    return \%Issues;
}

sub _SyncIssueTargets {
    my ($Self, %Param) = @_;
    my $Field = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(Name => 'RedmineID');
    die "RedmineID dynamic field unavailable\n" if !$Field || !$Field->{ID};
    my ($FieldID, $IssueID, $After) = ($Field->{ID}, "$Param{IssueID}", $Param{AfterID} || 0);
    my $Archive = $Kernel::OM->Get('Kernel::Config')->Get('Ticket::ArchiveSystem')
        ? 'AND t.archive_flag = 0 ' : '';
    my $DB = $Kernel::OM->Get('Kernel::System::DB');
    die "Cannot read Redmine delivery targets\n" if !$DB->Prepare(
        SQL => 'SELECT t.id FROM ticket t INNER JOIN dynamic_field_value v ON v.object_id = t.id '
            . 'WHERE v.field_id = ? AND v.value_text = ? AND t.id > ? ' . $Archive . 'ORDER BY t.id',
        Bind => [\$FieldID, \$IssueID, \$After], Limit => $Param{Limit});
    my @IDs;
    while (my @Row = $DB->FetchrowArray()) { push @IDs, $Row[0]; }
    return @IDs;
}

sub _SyncDetailsSignature {
    my ($Self, $Issue) = @_;
    my ($Journal, $Attachment) = (0, 0);
    for my $Item (@{$Issue->{journals} || []}) {
        $Journal = $Item->{id} if ($Item->{id} || 0) > $Journal;
    }
    for my $Item (@{$Issue->{attachments} || []}) {
        $Attachment = $Item->{id} if ($Item->{id} || 0) > $Attachment;
    }
    return sha256_hex(encode_utf8(join "\0", $Issue->{updated_on} || '',
        $Issue->{status}->{name} || '', $Journal, $Attachment));
}
sub _SyncValidIssue {
    my ($Issue, $ID) = @_;
    return ref($Issue) eq 'HASH' && defined($Issue->{id}) && $Issue->{id} =~ /\A[1-9]\d*\z/
        && $Issue->{id} == $ID && ref($Issue->{status}) eq 'HASH'
        && defined $Issue->{status}->{name} && defined $Issue->{updated_on};
}
sub _SyncDetails {
    my ($Self, %Param) = @_;
    my $Include = $Kernel::OM->Get('Kernel::Config')->Get('Redmine::SyncAttachments')
        ? 'journals,attachments' : 'journals';
    return $Self->_Request(Method => 'GET', Path => "/issues/$Param{IssueID}.json?include=$Include",
        defined $Param{Timeout} ? (Timeout => $Param{Timeout}) : ());
}

sub PollSync {
    my ($Self) = @_;
    return 1 if !_SyncEnabled();
    my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
    my $Source = $Store->SourceKey();
    my $LockKey = "poll:$Source";
    my $Token;
    my $OK = eval {
        $Token = $Store->LockAcquire(Key => $LockKey, LeaseSeconds => 60, Now => $Self->_SyncNow());
        if ($Token) {
            my $Projection = $Self->_SyncProjection();
            my @IDs = sort {$a <=> $b} keys %$Projection;
            my $ProjectionDigest = Digest::SHA->new(256);
            $ProjectionDigest->add($_, "\0", $Projection->{$_}->{LinksHash}, "\0") for @IDs;
            my $ProjectionHash = $ProjectionDigest->hexdigest();
            my $Cache = $Kernel::OM->Get('Kernel::System::Cache');
            my $ProjectionKey = "LinkedProjection::$Source";
            my $PreviousHash = $Cache->Get(Type => 'RedmineBridgeHealth', Key => $ProjectionKey,
                CacheInMemory => 0, CacheInBackend => 1);
            if (!defined $PreviousHash || $PreviousHash ne $ProjectionHash) {
                die "Redmine detector lease lost\n" if !$Store->LockValid(Key => $LockKey,
                    Token => $Token, Now => $Self->_SyncNow());
                $Store->RetireMissing(SourceKey => $Source, IssueIDs => \@IDs);
                $Cache->Set(Type => 'RedmineBridgeHealth', Key => $ProjectionKey,
                    Value => $ProjectionHash, TTL => 604800, CacheInMemory => 0, CacheInBackend => 1);
                # With no linked workers left, only retirement can clear the
                # aggregate error. Read durable errors before reporting health.
                $Self->_SyncHealth(Kind => 'Worker', Error => '');
            }
            my $Rows = $Store->ListIssues(SourceKey => $Source, IssueIDs => \@IDs);
            my %Existing = map {$_->{issue_id} => $_} @$Rows;
            my %Seen;
            my $Timeout = _SyncInteger($Kernel::OM->Get('Kernel::Config')->Get('Redmine::UITimeout'), 5, 1, 60);
            # HTTP keepalive exists only for detector requests in this block.
            local $Self->{_RequestScope} = {};
            while (@IDs) {
                my @Batch = splice @IDs, 0, 100;
                my %Wanted = map {$_ => 1} @Batch;
                my $Offset = 0;
                while (1) {
                    die "Redmine detector lease lost\n" if !$Store->RenewLock(Key => $LockKey,
                        Token => $Token, LeaseSeconds => 60, Now => $Self->_SyncNow());
                    my %Res = $Self->_Request(Method => 'GET', Timeout => $Timeout,
                        Path => '/issues.json?issue_id=' . join(',', @Batch) . "&status_id=*&limit=100&offset=$Offset");
                    die(($Res{Error} || 'Redmine list unavailable') . "\n") if !$Res{Success};
                    my $Data = $Res{Data};
                    die "Invalid Redmine issue list\n" if ref($Data) ne 'HASH' || ref($Data->{issues}) ne 'ARRAY';
                    for my $Issue (@{$Data->{issues}}) {
                        my $ID = ref($Issue) eq 'HASH' ? $Issue->{id} : undef;
                        die "Unexpected Redmine issue in list\n" if !defined($ID) || !$Wanted{$ID}
                            || !_SyncValidIssue($Issue, $ID);
                        $Seen{$ID} = {UpdatedOn => $Issue->{updated_on}, Status => $Issue->{status}->{name}};
                    }
                    my $PageLimit = _SyncInteger($Data->{limit}, 100, 1, 100);
                    my $PageOffset = _SyncInteger($Data->{offset}, $Offset, 0, undef);
                    die "Invalid Redmine pagination offset\n" if $PageOffset != $Offset;
                    my $Count = @{$Data->{issues}};
                    $Offset += $PageLimit;
                    last if !$Count || $Count < $PageLimit
                        || (defined($Data->{total_count}) && $Data->{total_count} =~ /\A\d+\z/ && $Offset >= $Data->{total_count});
                    die "Redmine issue list exceeds requested batch\n" if $Offset >= @Batch;
                }
            }
            die "Redmine detector lease lost\n" if !$Store->LockValid(Key => $LockKey,
                Token => $Token, Now => $Self->_SyncNow());
            my $LeaseCheckedAt = $Self->_SyncNow();
            for my $ID (sort {$a <=> $b} keys %$Projection) {
                if ($Self->_SyncNow() - $LeaseCheckedAt >= 30) {
                    die "Redmine detector lease lost\n" if !$Store->RenewLock(Key => $LockKey,
                        Token => $Token, LeaseSeconds => 60, Now => $Self->_SyncNow());
                    $LeaseCheckedAt = $Self->_SyncNow();
                }
                my $Old = $Existing{$ID};
                if ($Seen{$ID}) {
                    my %Tuple = (%{$Seen{$ID}}, LinksHash => $Projection->{$ID}->{LinksHash});
                    my $Changed = !$Old || $Old->{updated_on} ne $Tuple{UpdatedOn}
                        || $Old->{issue_status} ne $Tuple{Status} || $Old->{links_hash} ne $Tuple{LinksHash};
                    if ($Changed) {
                        $Existing{$ID} = $Store->Observe(SourceKey => $Source, IssueID => $ID,
                            Existing => $Old, %Tuple, Now => $Self->_SyncNow());
                    }
                    elsif ($Old->{delivery_signature} eq sha256_hex("missing:$ID")) {
                        # An unchanged public tuple can regain access after an omission.
                        $Existing{$ID} = $Store->ObserveSignature(IssueKey => $Old->{key},
                            Signature => sha256_hex("restored:$ID"), Now => $Self->_SyncNow());
                    }
                }
                elsif (!$Old) {
                    $Existing{$ID} = $Store->Observe(SourceKey => $Source, IssueID => $ID,
                        UpdatedOn => '', Status => '', LinksHash => $Projection->{$ID}->{LinksHash}, Now => $Self->_SyncNow());
                }
                elsif ($Old->{done_generation} >= $Old->{generation}) {
                    $Existing{$ID} = $Store->ObserveSignature(IssueKey => $Old->{key},
                        Signature => sha256_hex("missing:$ID"), Now => $Self->_SyncNow());
                }
            }
            my $Probes = 0;
            for my $ID (sort {($Existing{$a}->{probe_at} || 0) <=> ($Existing{$b}->{probe_at} || 0) || $a <=> $b} keys %$Projection) {
                last if $Probes >= 2;
                my $Row = $Existing{$ID};
                next if !$Seen{$ID} || !$Row || !$Row->{delivery_signature}
                    || $Row->{delivery_signature} eq sha256_hex("restored:$ID");
                my $Now = $Self->_SyncNow();
                my $Recent = $Row->{observed_at} >= $Now - 15;
                next if $Row->{probe_at} > $Now - ($Recent ? 5 : 900);
                $Probes++;
                die "Redmine detector lease lost\n" if !$Store->RenewLock(Key => $LockKey,
                    Token => $Token, LeaseSeconds => 60, Now => $Now);
                my %Res = $Self->_SyncDetails(IssueID => $ID, Timeout => $Timeout);
                die(($Res{Error} || 'Redmine detail probe unavailable') . "\n") if !$Res{Success};
                my $Issue = ref($Res{Data}) eq 'HASH' ? $Res{Data}->{issue} : undef;
                die "Invalid Redmine detail probe\n" if !_SyncValidIssue($Issue, $ID);
                die "Redmine detector lease lost\n" if !$Store->LockValid(Key => $LockKey,
                    Token => $Token, Now => $Self->_SyncNow());
                my $Signature = $Self->_SyncDetailsSignature($Issue);
                $Store->ObserveSignature(IssueKey => $Row->{key}, Signature => $Signature, Now => $Now)
                    if $Signature ne $Row->{delivery_signature};
                $Store->MarkProbe(IssueKey => $Row->{key}, Now => $Now);
            }
        }
        1;
    };
    my $Error = $@;
    if ($Token) {
        my $Released = eval {$Store->LockRelease(Key => $LockKey, Token => $Token); 1};
        if (!$Released) {$Error ||= $@; $OK = 0;}
    }
    $Self->_SyncHealth(Kind => 'Poll', Error => $OK ? '' : ($Error || 'Redmine poll failed'));
    return $OK ? 1 : undef;
}

# Do not spend scheduler/DB work on every pending issue while the shared
# HTTP source is rate limited. The request layer owns this cache record.
sub _SyncSourceCoolingDown {
    my ($Self) = @_;
    my $Config = $Kernel::OM->Get('Kernel::Config');
    my $URL = $Config->Get('Redmine::BaseURL') || '';
    $URL =~ s{/\z}{};
    my $Key = $Self->_HTTPCooldownKey(BaseURL => $URL, APIKey => $Config->Get('Redmine::APIKey') || '');
    my $State = $Kernel::OM->Get('Kernel::System::Cache')->Get(Type => 'RedmineBridgeHTTP',
        Key => $Key, CacheInMemory => 0, CacheInBackend => 1);
    return ref($State) eq 'HASH' && ($State->{OpenUntil} || 0) > time();
}

sub DispatchSync {
    my ($Self) = @_;
    return 1 if !_SyncEnabled() || $Self->_SyncSourceCoolingDown();
    my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
    my $Source = $Store->SourceKey();
    my $Prefix = 'RedmineBridgeSync::' . substr($Source, 0, 16) . '::';
    my $Lock = "dispatch:$Source";
    my $Token;
    my $OK = eval {
        $Token = $Store->LockAcquire(Key => $Lock, LeaseSeconds => 60, Now => $Self->_SyncNow());
        if ($Token) {
            my $Workers = _SyncInteger($Kernel::OM->Get('Kernel::Config')->Get('Redmine::SyncWorkers'), 1, 1, 4);
            my $DB = $Kernel::OM->Get('Kernel::System::DB');
            my $Type = 'AsynchronousExecutor';
            my $Pattern = "$Prefix%";
            die "Cannot read Redmine scheduler capacity\n" if !$DB->Prepare(
                SQL => 'SELECT COUNT(*) FROM scheduler_task WHERE task_type = ? AND name LIKE ?',
                Bind => [\$Type, \$Pattern]);
            my ($Active) = $DB->FetchrowArray();
            die "Invalid Redmine scheduler capacity\n" if !defined $Active;
            my $Available = $Workers - $Active;
            if ($Available > 0) {
                my $Ready = $Store->ReadyIssues(SourceKey => $Source, Limit => $Available, Now => $Self->_SyncNow());
                for my $Row (@$Ready) {
                    next if !$Store->MarkQueued(IssueKey => $Row->{key}, Now => $Self->_SyncNow());
                    my $Task = $Kernel::OM->Get('Kernel::System::Daemon::SchedulerDB')->TaskAdd(
                        Type => $Type, Name => $Prefix . $Row->{key},
                        Data => {Object => 'Kernel::System::Redmine', Function => 'ProcessSyncBatch',
                            Params => {SourceKey => $Source, SeedIssueKey => $Row->{key}}});
                    die "Cannot queue Redmine delivery\n" if !$Task || $Task < 0;
                }
            }
        }
        1;
    };
    my $Error = $@;
    if ($Token) {
        my $Released = eval {$Store->LockRelease(Key => $Lock, Token => $Token); 1};
        if (!$Released) {$Error ||= $@; $OK = 0;}
    }
    $Self->_SyncHealth(Kind => 'Dispatch', Error => $OK ? '' : ($Error || 'Redmine dispatch failed'));
    return $OK ? 1 : undef;
}

# Reuse one initialized OTRS core for many distinct issues, bounded by total
# delivered tickets and wall time rather than one cold process per issue.
sub ProcessSyncBatch {
    my ($Self, %Param) = @_;
    return {Success => 1, Processed => 0, Succeeded => 0, Complete => 1} if !_SyncEnabled();
    my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
    return {Success => 1, Processed => 0, Succeeded => 0, Complete => 1}
        if !defined $Param{SourceKey} || $Param{SourceKey} ne $Store->SourceKey();
    my $Limit = _SyncInteger($Kernel::OM->Get('Kernel::Config')->Get('Redmine::SyncBatchLimit'), 50, 1, 10000);
    my $Deadline = $Self->_SyncNow() + 10;
    my ($Processed, $Succeeded, $Success, $Attempts, $BatchError) = (0, 0, 1, 0, '');
    my @Pending = $Param{SeedIssueKey} ? ($Param{SeedIssueKey}) : ();
    my %Visited;
    my $OK = eval {
        while ($Processed < $Limit && $Attempts < $Limit && $Self->_SyncNow() < $Deadline) {
            if (!@Pending) {
                my $Rows = $Store->ReadyIssues(SourceKey => $Param{SourceKey},
                    Limit => $Limit - $Processed, Now => $Self->_SyncNow());
                @Pending = map {$_->{key}} grep {!$Visited{$_->{key}}} @$Rows;
                last if !@Pending;
            }
            my $Key = shift @Pending;
            next if $Visited{$Key}++;
            $Attempts++;
            my $Result = $Self->ProcessSyncIssue(IssueKey => $Key,
                TicketLimit => $Limit - $Processed, Deadline => $Deadline, DeferHealth => 1);
            $Processed += $Result->{Processed} || 0;
            $Succeeded += $Result->{Succeeded} || 0;
            if (!$Result->{Success}) {
                $Success = 0;
                $BatchError ||= $Result->{Error} || '';
            }
            last if !$Result->{Success} && $Self->_SyncSourceCoolingDown();
        }
        1;
    };
    if (!$OK) {
        $Success = 0;
        $BatchError ||= $@ || 'Redmine worker batch failed';
        $Self->_SyncHealth(Kind => 'Worker', Error => $BatchError, Count => $Succeeded);
    }
    elsif ($Attempts) {
        $Self->_SyncHealth(Kind => 'Worker', Error => $BatchError, Count => $Succeeded);
    }
    return {Success => $Success, Processed => $Processed, Succeeded => $Succeeded, Error => $BatchError, Complete => $Processed < $Limit ? 1 : 0};
}

sub ProcessSyncIssue {
    my ($Self, %Param) = @_;
    return {Success => 1, Processed => 0, Succeeded => 0, Complete => 1} if !_SyncEnabled();
    my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
    my ($Row, %Work, $RetryAfter, $Count, $Succeeded, $Complete, $TicketError);
    $Succeeded = 0;
    $TicketError = '';
    $Complete = 0;
    $Count = 0;
    my $OK = eval {
        my $Current = $Store->GetIssue(IssueKey => $Param{IssueKey});
        if ($Current && $Current->{source_key} eq $Store->SourceKey()) {
            $Row = $Store->Claim(IssueKey => $Param{IssueKey}, LeaseSeconds => 120, Now => $Self->_SyncNow());
        }
        if ($Row) {
            %Work = (IssueKey => $Row->{key}, Token => $Row->{lease_token}, RoundGeneration => $Row->{round_generation});
            my %Res = $Self->_SyncDetails(IssueID => $Row->{issue_id});
            $RetryAfter = $Res{RetryAfterSeconds};
            die(($Res{Error} || 'Redmine issue details unavailable') . "\n") if !$Res{Success};
            my $Issue = ref($Res{Data}) eq 'HASH' ? $Res{Data}->{issue} : undef;
            die "Invalid Redmine delivery details\n" if !_SyncValidIssue($Issue, $Row->{issue_id})
                || ref($Issue->{journals}) ne 'ARRAY'
                || ($Kernel::OM->Get('Kernel::Config')->Get('Redmine::SyncAttachments') && ref($Issue->{attachments}) ne 'ARRAY');
            $Store->MarkProbe(IssueKey => $Row->{key}, Now => $Self->_SyncNow());
            if ($Store->CaptureSignature(%Work, Signature => $Self->_SyncDetailsSignature($Issue), Now => $Self->_SyncNow())) {
                my $Limit = _SyncInteger($Kernel::OM->Get('Kernel::Config')->Get('Redmine::SyncBatchLimit'), 50, 1, 10000);
                if (defined $Param{TicketLimit}) {
                    my $Requested = _SyncInteger($Param{TicketLimit}, $Limit, 1, $Limit);
                    $Limit = $Requested if $Requested < $Limit;
                }
                my @IDs = $Self->_SyncIssueTargets(IssueID => $Row->{issue_id}, AfterID => $Row->{after_ticket_id}, Limit => $Limit);
                delete @Res{qw(Content ContentFile)};
                my %Cache = (IssueID => $Row->{issue_id}, Snapshot => \%Res, Details => \%Res);
                my $After = $Row->{after_ticket_id};
                my $DeadlineAt = defined $Param{Deadline} ? $Param{Deadline} : $Self->_SyncNow() + 10;
                my $Deadline = 0;
                for my $ID (@IDs) {
                    die "Redmine delivery lease lost\n" if !$Store->RenewIssueLease(%Work, LeaseSeconds => 120, Now => $Self->_SyncNow());
                    $Count++; # Attempts, including failures, consume the bounded worker budget.
                    my %Result = eval {$Self->SyncTicketFromRedmine(TicketID => $ID, UserID => 1,
                        IssueCache => \%Cache, ForceDetails => 1, ExpectedIssueID => $Row->{issue_id}, Work => \%Work)};
                    my $TicketException = $@;
                    $RetryAfter = $Result{RetryAfterSeconds};
                    if ($TicketException || !$Result{Success}) {
                        my $Failure = $TicketException || $Result{Error} || 'Redmine ticket delivery failed';
                        $TicketError ||= $Failure;
                        die "Redmine ticket failure checkpoint rejected\n" if !$Store->RecordTicketFailure(%Work,
                            TicketID => $ID, Error => $Failure,
                            defined($RetryAfter) && $RetryAfter > 0 ? (RetryAfterSeconds => $RetryAfter) : (),
                            Now => $Self->_SyncNow());
                    }
                    else {
                        die "Redmine delivery progress rejected\n" if !$Result{ProgressCommitted}
                            && !$Store->Progress(%Work, AfterTicketID => $ID, Now => $Self->_SyncNow());
                        $Succeeded++;
                    }
                    $After = $ID;
                    if ($Self->_SyncNow() >= $DeadlineAt) {$Deadline = 1; last;}
                    last if $TicketError && $Self->_SyncSourceCoolingDown();
                }
                $Complete = @IDs < $Limit && !$Deadline && $Count == @IDs ? 1 : 0;
                if (@IDs == $Limit && !$Deadline && $Count == @IDs) {
                    # A one-ID lookahead avoids an empty cold process at exact
                    # batch boundaries, including fifty single-ticket issues.
                    my @More = $Self->_SyncIssueTargets(IssueID => $Row->{issue_id}, AfterID => $After, Limit => 1);
                    $Complete = 1 if !@More;
                }
                die "Redmine delivery release rejected\n" if !$Store->Release(%Work, AfterTicketID => $After,
                    Done => $Complete, Now => $Self->_SyncNow());
            }
            else {
                # A retired/replaced round cannot retain this old token.
                # Store fences the current round's cursor during release.
                $Store->Release(%Work, AfterTicketID => $Row->{after_ticket_id}, Now => $Self->_SyncNow());
            }
        }
        1;
    };
    my $Error = $@;
    my $HealthError = $OK ? $TicketError : ($Error || 'Redmine delivery failed');
    if (!$OK && $Row) {
        my $Failed = eval {$Store->Fail(%Work, Error => $HealthError,
            defined($RetryAfter) && $RetryAfter > 0 ? (RetryAfterSeconds => $RetryAfter) : (), Now => $Self->_SyncNow());};
        if (!$Failed && !$@) {
            my $Latest = eval {$Store->GetIssue(IssueKey => $Row->{key})};
            # Unlink retirement intentionally revoked this worker. Its stale
            # local error must not reintroduce a cleared aggregate failure.
            $HealthError = '' if $Latest && $Latest->{done_generation} >= $Latest->{generation}
                && !length($Latest->{links_hash}) && !length($Latest->{last_error});
        }
    }
    $Self->_SyncHealth(Kind => 'Worker', Error => $HealthError, Count => $Succeeded)
        if !$Param{DeferHealth} && ($Row || !$OK);
    return {Success => $OK && !$TicketError ? 1 : 0, Processed => $Count, Succeeded => $Succeeded, Complete => $Complete, Error => $HealthError};
}
1;
