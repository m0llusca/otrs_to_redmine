# --
# Copyright (C) 2026 OTRSRedmineBridge
# GPL version 3 or later. See COPYING.
# --
package Kernel::System::Redmine::SyncStore;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);

our @ObjectDependencies = ('Kernel::Config', 'Kernel::System::DB');

my @IssueColumns = qw(issue_key source_key issue_id updated_on issue_status links_hash
    generation round_generation done_generation after_ticket_id first_failed_ticket_id lease_token lease_until retry_at served_at queued_at
    delivery_signature observed_at probe_at last_error retry_count);
my $IssueColumns = join ', ', @IssueColumns;
my @LockColumns = qw(lease_token lease_until);
my @ReadyColumns = qw(issue_key issue_id generation);

sub new {
    my ($Type, %Param) = @_;
    return bless { DBObject => $Param{DBObject} }, $Type;
}

sub _DBObject {
    my ($Self) = @_;
    return $Self->{DBObject} || $Kernel::OM->Get('Kernel::System::DB');
}

sub _DB { return $_[0]->_DBObject()->Connect(); }

sub _Now { return defined $_[0]{Now} ? $_[0]{Now} : time(); }
sub _Token { return sha256_hex(join ':', $$, time(), rand(), rand(), {}); }
sub _Key { return sha256_hex(encode_utf8(join "\0", @_)); }

sub SourceKey {
    my ($Self, %Param) = @_;
    my $Config = (!defined $Param{BaseURL} || !defined $Param{APIKey})
        ? $Kernel::OM->Get('Kernel::Config') : undef;
    return _Key(defined $Param{BaseURL} ? $Param{BaseURL} : ($Config->Get('Redmine::BaseURL') || ''),
        defined $Param{APIKey} ? $Param{APIKey} : ($Config->Get('Redmine::APIKey') || ''));
}

# Do() discards affected-row counts, which CAS needs. Reuse its exact core
# backend preprocessing before executing on the public Connect() handle.
sub _Do {
    my ($Self, $SQL, @Bind) = @_;
    my $DBObject = $Self->_DBObject();
    my $Backend = $DBObject->{Backend};
    $Backend->PreProcessSQL(\$SQL) if $Backend->{'DB::PreProcessSQL'};
    $Backend->PreProcessBindData(\@Bind) if @Bind && $Backend->{'DB::PreProcessBindData'};
    my $Result = $DBObject->Connect()->do($SQL, undef, @Bind);
    die 'Redmine sync database write failed' if !defined $Result;
    return 0 + $Result;
}

sub _Rows {
    my ($Self, $SQL, $Columns, $Limit, @Bind) = @_;
    my $DBObject = $Self->_DBObject();
    # Lease and generation decisions must always read the transaction's master.
    no warnings 'once';
    local $Kernel::System::DB::UseSlaveDB = 0;
    $DBObject->Prepare(SQL => $SQL, Bind => [map { \$_ } @Bind],
        defined $Limit ? (Limit => $Limit) : ())
        or die 'Redmine sync database read failed';
    my @Rows;
    while (my @Values = $DBObject->FetchrowArray()) {
        my %Row;
        @Row{@$Columns} = @Values;
        $Row{key} = $Row{issue_key} if exists $Row{issue_key};
        for my $Name (qw(updated_on issue_status links_hash lease_token delivery_signature last_error)) {
            $Row{$Name} = '' if exists $Row{$Name} && !defined $Row{$Name};
        }
        push @Rows, \%Row;
    }
    return \@Rows;
}

sub GetIssue {
    my ($Self, %Param) = @_;
    my $Rows = $Param{IssueKey}
        ? $Self->_Rows("SELECT $IssueColumns FROM redmine_sync_issue WHERE issue_key = ?", \@IssueColumns, undef, $Param{IssueKey})
        : $Self->_Rows("SELECT $IssueColumns FROM redmine_sync_issue WHERE source_key = ? AND issue_id = ?",
            \@IssueColumns, undef, $Param{SourceKey}, $Param{IssueID});
    return $Rows->[0];
}

# Oracle permits at most 1000 expressions in an IN list.
sub _IDPredicate {
    my ($IDs, $Exclude) = @_;
    die 'Need numeric issue IDs' if ref $IDs ne 'ARRAY' || grep { !defined $_ || !/\A[1-9][0-9]*\z/ } @$IDs;
    return $Exclude ? '1 = 1' : '1 = 0' if !@$IDs;
    my @Groups;
    for (my $Offset = 0; $Offset < @$IDs; $Offset += 1000) {
        my $Count = @$IDs - $Offset > 1000 ? 1000 : @$IDs - $Offset;
        push @Groups, 'issue_id ' . ($Exclude ? 'NOT IN' : 'IN')
            . ' (' . join(', ', @$IDs[$Offset .. $Offset + $Count - 1]) . ')';
    }
    return '(' . join($Exclude ? ' AND ' : ' OR ', @Groups) . ')';
}

sub ListIssues {
    my ($Self, %Param) = @_;
    my $SQL = "SELECT $IssueColumns FROM redmine_sync_issue WHERE source_key = ?";
    my @Bind = ($Param{SourceKey});
    if (defined $Param{IssueIDs}) {
        return [] if !@{$Param{IssueIDs}};
        $SQL .= ' AND ' . _IDPredicate($Param{IssueIDs}, 0);
    }
    return $Self->_Rows($SQL . ' ORDER BY issue_id', \@IssueColumns, undef, @Bind);
}

sub RetireMissing {
    my ($Self, %Param) = @_;
    my $Predicate = _IDPredicate($Param{IssueIDs}, 1);
    return $Self->_Do('UPDATE redmine_sync_issue SET done_generation = generation, round_generation = generation, links_hash = NULL, delivery_signature = NULL, after_ticket_id = 0, first_failed_ticket_id = 0, lease_token = NULL, lease_until = 0, queued_at = 0, retry_at = 0, last_error = NULL, retry_count = 0 WHERE source_key = ? AND '
        . $Predicate . ' AND (generation > done_generation OR links_hash IS NOT NULL OR last_error IS NOT NULL OR lease_until <> 0 OR queued_at <> 0 OR retry_at <> 0)',
        $Param{SourceKey});
}

# Keep an in-flight round moving through every target even while new versions
# arrive. CASE assignments precede generation++ for MySQL's left-to-right SET.
sub Observe {
    my ($Self, %Param) = @_;
    my $Key = _Key($Param{SourceKey}, $Param{IssueID});
    my $Row = $Param{Existing} || $Self->GetIssue(IssueKey => $Key);
    my @Tuple = map { defined $Param{$_} ? $Param{$_} : '' } qw(UpdatedOn Status LinksHash);
    for (1..8) {
        if (!$Row) {
            my $Inserted = eval {
                $Self->_Do('INSERT INTO redmine_sync_issue (issue_key, source_key, issue_id, updated_on, issue_status, links_hash, generation, round_generation, done_generation, after_ticket_id, lease_until, retry_at, queued_at, observed_at, probe_at, retry_count) VALUES (?, ?, ?, ?, ?, ?, 1, 1, 0, 0, 0, 0, 0, ?, 0, 0)',
                    $Key, $Param{SourceKey}, $Param{IssueID}, @Tuple, _Now(\%Param));
                1;
            };
            my $Error = $@;
            $Row = $Self->GetIssue(IssueKey => $Key);
            die $Error if !$Inserted && !$Row;
            return $Row if $Inserted;
        }
        return $Row if $Row->{updated_on} eq $Tuple[0] && $Row->{issue_status} eq $Tuple[1]
            && $Row->{links_hash} eq $Tuple[2];
        my $Changed = $Self->_Do('UPDATE redmine_sync_issue SET updated_on = ?, issue_status = ?, links_hash = ?, after_ticket_id = CASE WHEN generation > done_generation THEN after_ticket_id ELSE 0 END, round_generation = CASE WHEN generation > done_generation THEN round_generation ELSE generation + 1 END, generation = generation + 1, delivery_signature = NULL, retry_at = 0, queued_at = 0, observed_at = ? WHERE issue_key = ? AND generation = ?',
            @Tuple, _Now(\%Param), $Key, $Row->{generation});
        $Row = $Self->GetIssue(IssueKey => $Key);
        return $Row if $Changed;
    }
    die 'Redmine sync observation contention';
}

sub Claim {
    my ($Self, %Param) = @_;
    my $Now = _Now(\%Param);
    my $Token = _Token();
    my $Seconds = $Param{LeaseSeconds} || 120;
    return if !$Self->_Do('UPDATE redmine_sync_issue SET lease_token = ?, lease_until = ?, served_at = ?, queued_at = 0, first_failed_ticket_id = CASE WHEN first_failed_ticket_id > 0 AND after_ticket_id = first_failed_ticket_id - 1 THEN 0 ELSE first_failed_ticket_id END WHERE issue_key = ? AND generation > done_generation AND (retry_at <= ? OR (first_failed_ticket_id > 0 AND after_ticket_id >= first_failed_ticket_id)) AND lease_until <= ?',
        $Token, $Now + $Seconds, $Now, $Param{IssueKey}, $Now, $Now);
    my $Row = $Self->GetIssue(IssueKey => $Param{IssueKey});
    return $Row && $Row->{lease_token} eq $Token ? $Row : undef;
}

# An obsolete round may release only its own lease, without changing the new
# round cursor, retry or completion state. Latest versions do not revoke a round.
sub _ReleaseStale {
    my ($Self, %Param) = @_;
    $Self->_Do('UPDATE redmine_sync_issue SET lease_token = NULL, lease_until = 0 WHERE issue_key = ? AND lease_token = ? AND round_generation <> ?',
        $Param{IssueKey}, $Param{Token}, $Param{RoundGeneration});
    return;
}

sub Progress {
    my ($Self, %Param) = @_;
    return $Self->Release(%Param) if $Param{Done};
    my $Changed = $Self->_Do('UPDATE redmine_sync_issue SET after_ticket_id = ? WHERE issue_key = ? AND lease_token = ? AND round_generation = ? AND lease_until > ? AND after_ticket_id <= ?',
        $Param{AfterTicketID} || 0, $Param{IssueKey}, $Param{Token}, $Param{RoundGeneration}, _Now(\%Param), $Param{AfterTicketID} || 0);
    return 1 if $Changed;
    return $Self->_ReleaseStale(%Param);
}

# A completed old round only acknowledges its starting generation. Resetting
# the cursor starts the mandatory round that catches the front up to the latest.
sub Release {
    my ($Self, %Param) = @_;
    my ($SQL, @Bind);
    if ($Param{Done}) {
        # Keep every CASE that reads retry_count before incrementing it: MySQL
        # evaluates SET left to right. No extra SELECT is needed per issue.
        my $Delay = 'CASE retry_count WHEN 0 THEN 2 WHEN 1 THEN 4 WHEN 2 THEN 8 WHEN 3 THEN 16 WHEN 4 THEN 32 WHEN 5 THEN 64 WHEN 6 THEN 128 ELSE 256 END';
        $SQL = 'UPDATE redmine_sync_issue SET '
            . 'done_generation = CASE WHEN first_failed_ticket_id > 0 THEN done_generation ELSE round_generation END, '
            . 'round_generation = CASE WHEN first_failed_ticket_id > 0 THEN round_generation ELSE generation END, '
            . 'after_ticket_id = CASE WHEN first_failed_ticket_id > 0 THEN first_failed_ticket_id - 1 ELSE 0 END, '
            . 'retry_at = CASE WHEN first_failed_ticket_id > 0 THEN CASE WHEN retry_at > (? + '
            . $Delay . ') THEN retry_at ELSE (? + ' . $Delay . ') END ELSE 0 END, '
            . 'retry_count = CASE WHEN first_failed_ticket_id > 0 THEN retry_count + 1 ELSE 0 END, '
            . 'last_error = CASE WHEN first_failed_ticket_id > 0 THEN last_error ELSE NULL END, '
            . 'lease_token = NULL, lease_until = 0, queued_at = 0';
        @Bind = (_Now(\%Param), _Now(\%Param));
    }
    else {
        $SQL = 'UPDATE redmine_sync_issue SET after_ticket_id = ?, lease_token = NULL, lease_until = 0, queued_at = 0';
        @Bind = ($Param{AfterTicketID} || 0);
    }
    my $Changed = $Self->_Do($SQL . ' WHERE issue_key = ? AND lease_token = ? AND round_generation = ? AND lease_until > ?',
        @Bind, $Param{IssueKey}, $Param{Token}, $Param{RoundGeneration}, _Now(\%Param));
    return 1 if $Changed;
    return $Self->_ReleaseStale(%Param);
}

# Continue the current scan after a failed ticket. The marker remembers the
# first unresolved gap, so finishing the scan rewinds instead of acknowledging.
sub RecordTicketFailure {
    my ($Self, %Param) = @_;
    return if !defined $Param{TicketID} || $Param{TicketID} !~ /\A[1-9][0-9]*\z/;
    my $Now = _Now(\%Param);
    my $HeaderUntil = 0;
    if (defined $Param{RetryAfterSeconds} && $Param{RetryAfterSeconds} > 0) {
        my $Delay = int($Param{RetryAfterSeconds});
        $Delay = 3600 if $Delay > 3600;
        $HeaderUntil = $Now + $Delay;
    }
    return $Self->_Do('UPDATE redmine_sync_issue SET '
        . 'first_failed_ticket_id = CASE WHEN first_failed_ticket_id = 0 OR first_failed_ticket_id > ? THEN ? ELSE first_failed_ticket_id END, '
        . 'after_ticket_id = CASE WHEN after_ticket_id < ? THEN ? ELSE after_ticket_id END, '
        . 'retry_at = CASE WHEN retry_at < ? THEN ? ELSE retry_at END, last_error = ? '
        . 'WHERE issue_key = ? AND lease_token = ? AND round_generation = ? AND lease_until > ?',
        $Param{TicketID}, $Param{TicketID}, $Param{TicketID}, $Param{TicketID},
        $HeaderUntil, $HeaderUntil, substr($Param{Error} || 'Ticket delivery failed', 0, 500),
        $Param{IssueKey}, $Param{Token}, $Param{RoundGeneration}, $Now) ? 1 : undef;
}

sub Fail {
    my ($Self, %Param) = @_;
    my $Row = $Self->GetIssue(IssueKey => $Param{IssueKey});
    return if !$Row;
    my $Delay = defined $Param{RetryAfterSeconds} ? $Param{RetryAfterSeconds}
        : 2 ** (($Row->{retry_count} || 0) > 7 ? 8 : ($Row->{retry_count} || 0) + 1);
    $Delay = 2 if $Delay < 2;
    my $MaxDelay = defined $Param{RetryAfterSeconds} ? 3600 : 300;
    $Delay = $MaxDelay if $Delay > $MaxDelay;
    my $Changed = $Self->_Do('UPDATE redmine_sync_issue SET retry_at = ?, retry_count = retry_count + 1, last_error = ?, lease_token = NULL, lease_until = 0, queued_at = 0 WHERE issue_key = ? AND lease_token = ? AND round_generation = ? AND lease_until > ?',
        _Now(\%Param) + $Delay, substr($Param{Error} || 'Sync failed', 0, 500),
        $Param{IssueKey}, $Param{Token}, $Param{RoundGeneration}, _Now(\%Param));
    return 1 if $Changed;
    return $Self->_ReleaseStale(%Param);
}

sub ReadyIssues {
    my ($Self, %Param) = @_;
    my $Now = _Now(\%Param);
    my $Limit = $Param{Limit} || 2;
    return $Self->_Rows('SELECT issue_key, issue_id, generation FROM redmine_sync_issue WHERE source_key = ? AND generation > done_generation AND (retry_at <= ? OR (first_failed_ticket_id > 0 AND after_ticket_id >= first_failed_ticket_id)) AND lease_until <= ? AND (queued_at = 0 OR queued_at <= ?) ORDER BY served_at, retry_at, issue_id',
        \@ReadyColumns, $Limit, $Param{SourceKey}, $Now, $Now, $Now - 30);
}

sub MarkQueued {
    my ($Self, %Param) = @_;
    my $Now = _Now(\%Param);
    return $Self->_Do('UPDATE redmine_sync_issue SET queued_at = ? WHERE issue_key = ? AND generation > done_generation AND (retry_at <= ? OR (first_failed_ticket_id > 0 AND after_ticket_id >= first_failed_ticket_id)) AND lease_until <= ? AND (queued_at = 0 OR queued_at <= ?)',
        $Now, $Param{IssueKey}, $Now, $Now, $Now - 30) ? 1 : undef;
}

sub CaptureSignature {
    my ($Self, %Param) = @_;
    my $Row = $Self->GetIssue(IssueKey => $Param{IssueKey});
    return if !defined $Param{RoundGeneration} || !$Row || $Row->{lease_token} ne $Param{Token} || $Row->{round_generation} != $Param{RoundGeneration}
        || $Row->{lease_until} <= _Now(\%Param);
    return 1 if $Row->{delivery_signature} eq $Param{Signature};
    if (!length $Row->{delivery_signature}) {
        return $Self->_Do('UPDATE redmine_sync_issue SET delivery_signature = ? WHERE issue_key = ? AND lease_token = ? AND round_generation = ? AND lease_until > ?',
            $Param{Signature}, $Param{IssueKey}, $Param{Token}, $Param{RoundGeneration}, _Now(\%Param)) ? 1 : undef;
    }
    return $Self->_Do('UPDATE redmine_sync_issue SET delivery_signature = ?, generation = generation + 1, queued_at = 0, retry_at = 0 WHERE issue_key = ? AND lease_token = ? AND round_generation = ? AND lease_until > ?',
        $Param{Signature}, $Param{IssueKey}, $Param{Token}, $Param{RoundGeneration}, _Now(\%Param)) ? 1 : undef;
}

sub MarkProbe {
    my ($Self, %Param) = @_;
    return $Self->_Do('UPDATE redmine_sync_issue SET probe_at = ? WHERE issue_key = ?', _Now(\%Param), $Param{IssueKey});
}

sub ObserveSignature {
    my ($Self, %Param) = @_;
    for (1..8) {
        my $Row = $Self->GetIssue(IssueKey => $Param{IssueKey});
        return if !$Row;
        return $Row if $Row->{delivery_signature} eq $Param{Signature};
        my $Changed = $Self->_Do('UPDATE redmine_sync_issue SET delivery_signature = ?, after_ticket_id = CASE WHEN generation > done_generation THEN after_ticket_id ELSE 0 END, round_generation = CASE WHEN generation > done_generation THEN round_generation ELSE generation + 1 END, generation = generation + 1, retry_at = 0, queued_at = 0, observed_at = ? WHERE issue_key = ? AND generation = ?',
            $Param{Signature}, _Now(\%Param), $Param{IssueKey}, $Row->{generation});
        return $Self->GetIssue(IssueKey => $Param{IssueKey}) if $Changed;
    }
    die 'Redmine sync signature contention';
}

sub LockAcquire {
    my ($Self, %Param) = @_;
    my $Key = _Key($Param{Key});
    my $Token = _Token();
    my $Now = _Now(\%Param);
    my $Until = $Now + ($Param{LeaseSeconds} || 120);
    my $Changed = $Self->_Do('UPDATE redmine_sync_lock SET lease_token = ?, lease_until = ? WHERE lock_key = ? AND lease_until <= ?',
        $Token, $Until, $Key, $Now);
    if (!$Changed) {
        my $Existing = $Self->_Rows('SELECT lease_token, lease_until FROM redmine_sync_lock WHERE lock_key = ?', \@LockColumns, undef, $Key);
        return if @$Existing;
        my $Inserted = eval {
            $Self->_Do('INSERT INTO redmine_sync_lock (lock_key, lease_token, lease_until) VALUES (?, ?, ?)', $Key, $Token, $Until);
            1;
        };
        my $Error = $@;
        my $Rows = $Self->_Rows('SELECT lease_token, lease_until FROM redmine_sync_lock WHERE lock_key = ?', \@LockColumns, undef, $Key);
        die $Error if !$Inserted && !@$Rows;
        return @$Rows && $Rows->[0]{lease_token} eq $Token && $Rows->[0]{lease_until} > $Now ? $Token : undef;
    }
    return $Self->LockValid(Key => $Param{Key}, Token => $Token, Now => $Now) ? $Token : undef;
}

sub LockValid {
    my ($Self, %Param) = @_;
    my $Rows = $Self->_Rows('SELECT lease_token, lease_until FROM redmine_sync_lock WHERE lock_key = ?', \@LockColumns, undef, _Key($Param{Key}));
    return @$Rows && $Rows->[0]{lease_token} eq $Param{Token} && $Rows->[0]{lease_until} > _Now(\%Param) ? 1 : undef;
}

sub LockRelease {
    my ($Self, %Param) = @_;
    return $Self->_Do('UPDATE redmine_sync_lock SET lease_until = 0 WHERE lock_key = ? AND lease_token = ?', _Key($Param{Key}), $Param{Token}) ? 1 : undef;
}

sub RenewLock {
    my ($Self, %Param) = @_;
    my $Now = _Now(\%Param);
    return $Self->_Do('UPDATE redmine_sync_lock SET lease_until = ? WHERE lock_key = ? AND lease_token = ? AND lease_until > ?',
        $Now + ($Param{LeaseSeconds} || 120), _Key($Param{Key}), $Param{Token}, $Now) ? 1 : undef;
}

sub RenewIssueLease {
    my ($Self, %Param) = @_;
    my $Now = _Now(\%Param);
    return $Self->_Do('UPDATE redmine_sync_issue SET lease_until = ? WHERE issue_key = ? AND lease_token = ? AND lease_until > ? AND round_generation = ?',
        $Now + ($Param{LeaseSeconds} || 120), $Param{IssueKey}, $Param{Token}, $Now,
        $Param{RoundGeneration}) ? 1 : undef;
}

# The caller owns commit/rollback. Do not nest or roll back its transaction.
# The locked row fences ArticleCreate and dynamic-field checkpoints together.
sub BeginTransaction {
    my ($Self, %Param) = @_;
    my $DBH = $Self->_DB();
    return if !$DBH->{AutoCommit};
    my $OK = eval {
        $DBH->begin_work() or die 'Cannot begin sync transaction';
        my $SQL = 'SELECT lease_token, lease_until FROM redmine_sync_lock WHERE lock_key = ?';
        $SQL .= ' FOR UPDATE' if lc($DBH->{Driver}{Name}) ne 'sqlite';
        # SQLite has no row locks: acquire its write lock before checking owner.
        $Self->_Do('UPDATE redmine_sync_lock SET lease_until = lease_until WHERE lock_key = ?', _Key($Param{LockKey}))
            if lc($DBH->{Driver}{Name}) eq 'sqlite';
        my $Rows = $Self->_Rows($SQL, \@LockColumns, undef, _Key($Param{LockKey}));
        die 'Sync transaction lease lost' if !@$Rows || $Rows->[0]{lease_token} ne $Param{Token}
            || $Rows->[0]{lease_until} <= _Now(\%Param);
        1;
    };
    if (!$OK) {
        eval { $DBH->rollback() if !$DBH->{AutoCommit}; };
        return;
    }
    return $DBH;
}

1;
