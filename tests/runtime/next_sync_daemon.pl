# Actual OTRS daemon -> SchedulerDB -> AsynchronousExecutor integration receipt.
# Run exclusively in bridge-perf-local AFTER preparing the existing 1000-ticket
# fixture and peer scenario. This script never resets fixtures or edits config.
use strict;
use warnings;
use utf8;
use lib '/opt/otrs', '/opt/otrs/Kernel/cpan-lib';
use Kernel::System::ObjectManager;
use JSON::PP;
use Time::HiRes qw(time);

my $JSON = JSON::PP->new->canonical->utf8;
my $Options = $JSON->decode($ARGV[0] || '{}');
my $MaximumRounds = $Options->{max_rounds} || 100;
die 'max_rounds must be 1..1000' if $MaximumRounds !~ /\A\d+\z/ || $MaximumRounds < 1 || $MaximumRounds > 1000;
local $Kernel::OM = Kernel::System::ObjectManager->new();
my $Config = $Kernel::OM->Get('Kernel::Config');

# Inspect installed registration BEFORE the test's process-local overrides.
my $DaemonModule = 'Kernel::System::Daemon::DaemonModules::RedmineBridgePoller';
my $Modules = $Config->Get('DaemonModules') || {};
die 'RedmineBridgePoller is not registered in installed SysConfig'
    if ref($Modules->{RedmineBridgePoller}) ne 'HASH'
    || ($Modules->{RedmineBridgePoller}->{Module} || '') ne $DaemonModule;
my $Cron = $Config->Get('Daemon::SchedulerCronTaskManager::Task') || {};
my @OldCron = grep {
    /RedmineBridgeSync/ || (ref($Cron->{$_}) eq 'HASH'
        && ($Cron->{$_}->{Function} || '') eq 'CronSync'
        && (($Cron->{$_}->{Module} || $Cron->{$_}->{Object} || '') eq 'Kernel::System::Redmine'))
} keys %$Cron;
die 'obsolete Redmine full-scan cron remains registered' if @OldCron;

my %Settings = (
    'Redmine::Enabled' => 1, 'Redmine::InboundSync' => 1, 'Redmine::AutoRetry' => 0,
    'Redmine::BaseURL' => 'http://redmine:8080', 'Redmine::APIKey' => 'local-next-sync-only',
    'Redmine::SyncBatchLimit' => 50, 'Redmine::SyncWorkers' => 2,
    'Redmine::SyncPollInterval' => 5, 'Redmine::SyncAttachments' => 1,
    'Redmine::StatusSync' => {'Проверка решения' => 'open|note', 'New' => 'closed successful'},
    'Redmine::NotifyOnStatusNote' => 0,
    'Redmine::MaxAttachmentBytes' => 5000000, 'Redmine::MaxAttachmentTotalBytes' => 20000000,
    'Redmine::MaxAttachmentCount' => 20,
    'SendmailModule' => 'Kernel::System::Email::DoNotSendEmail',
    %{$Options->{settings} || {}},
);
die 'integration proof is restricted to the isolated local peer'
    if $Settings{'Redmine::BaseURL'} ne 'http://redmine:8080';
$Config->Set(Key => $_, Value => $Settings{$_}) for keys %Settings;
my $Workers = $Settings{'Redmine::SyncWorkers'};
$Workers = 1 if !defined($Workers) || $Workers !~ /\A\d+\z/ || $Workers < 1;
$Workers = 4 if $Workers > 4;
my $Cache = $Kernel::OM->Get('Kernel::System::Cache');
$Cache->Configure(CacheInMemory => 0, CacheInBackend => 1);
my $DB = $Kernel::OM->Get('Kernel::System::DB');
my $Store = $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
my $Bridge = $Kernel::OM->Get('Kernel::System::Redmine');
my $Scheduler = $Kernel::OM->Get('Kernel::System::Daemon::SchedulerDB');
my $Executor = $Kernel::OM->Get('Kernel::System::Daemon::DaemonModules::SchedulerTaskWorker::AsynchronousExecutor');
my $Poller = $Kernel::OM->Get($DaemonModule);
my $Source = $Store->SourceKey();
my $Prefix = 'RedmineBridgeSync::' . substr($Source, 0, 16) . '::';
my $Loaded = $INC{'Kernel/System/Redmine/SyncCoordinator.pm'} || '';
die 'installed coordinator source is required' if $Loaded ne '/opt/otrs/Kernel/System/Redmine/SyncCoordinator.pm';

open my $FixtureFile, '<', '/opt/otrs/var/tmp/bridge-benchmark.json' or die '1000-ticket fixture is unavailable';
my $Fixture = do {local $/; $JSON->decode(<$FixtureFile>)};
close $FixtureFile;
my @IDs = @{$Fixture->{audit_poll} || []};
die 'prepare exactly 1000 existing audit tickets first' if @IDs != 1000;
die 'invalid fixture ticket ID' if grep {!defined($_) || $_ !~ /\A[1-9][0-9]*\z/} @IDs;
my $Objects = join ',', @IDs;
sub rows {
    my ($SQL, @Bind) = @_;
    my @Refs = map {\$_} @Bind;
    $DB->Prepare(SQL => $SQL, Bind => \@Refs) or die 'integration receipt SQL read failed';
    my @Rows;
    while (my @Row = $DB->FetchrowArray()) {push @Rows, \@Row;}
    return \@Rows;
}
sub scalar_sql {my $Rows = rows(@_); return @$Rows ? $Rows->[0][0] : 0;}
sub questions {return 0 + rows("SHOW SESSION STATUS LIKE 'Questions'")->[0][1];}
sub own_tasks {
    return rows('SELECT id, name, lock_key FROM scheduler_task WHERE task_type = ? AND name LIKE ? ORDER BY id',
        'AsynchronousExecutor', "$Prefix%");
}
sub work {
    my $Rows = rows('SELECT issue_key, issue_id, generation, done_generation, after_ticket_id, retry_at, lease_until, queued_at, last_error FROM redmine_sync_issue WHERE source_key = ? ORDER BY issue_id', $Source);
    my @Pending = grep {$_->[2] > $_->[3]} @$Rows;
    return {
        total_issues => scalar @$Rows, pending_issues => scalar @Pending,
        progressed_issues => scalar(grep {$_->[4] > 0} @Pending),
        max_cursor => ((sort {$b <=> $a} map {0 + $_->[4]} @Pending)[0] || 0),
        durable_errors => scalar(grep {defined($_->[8]) && length($_->[8])} @$Rows),
    };
}
sub notes {
    return scalar_sql("SELECT COUNT(*) FROM article WHERE ticket_id IN ($Objects) AND id > ?", $_[0]);
}
my $LinkField = $Fixture->{field_ids}->{RedmineID};
die 'fixture RedmineID field missing' if !$LinkField;
my $LinkedTickets = 0 + scalar_sql("SELECT COUNT(*) FROM dynamic_field_value WHERE field_id = ? AND object_id IN ($Objects) AND value_text IS NOT NULL", $LinkField);
die 'all 1000 fixture tickets must be linked before the exclusive daemon proof' if $LinkedTickets != 1000;
my $InitialTasks = own_tasks();
die 'existing own-source scheduler tasks must be drained before the exclusive proof' if @$InitialTasks;
my $BaselineArticle = scalar_sql('SELECT MAX(id) FROM article') || 0;
my $Before = work();
my $SQLBefore = questions();
my $Started = time();
my (@Slices, $MaxQueued, $Rounds, $TasksExecuted, $EventFlushes, $CapacityChecks);
$MaxQueued = $Rounds = $TasksExecuted = $EventFlushes = $CapacityChecks = 0;
my $FirstQueue;
for my $Round (1 .. $MaximumRounds) {
    $Rounds = $Round;
    # Actual daemon Run performs polling (when due) and dispatch on every loop.
    $Poller->Run() or die 'registered poller stopped unexpectedly';
    my $Tasks = own_tasks();
    die 'bridge scheduler capacity exceeded' if @$Tasks > $Workers;
    $CapacityChecks++;
    $MaxQueued = @$Tasks if @$Tasks > $MaxQueued;
    $FirstQueue = scalar @$Tasks if !defined $FirstQueue;
    my $BeforeRound = work();
    last if !$BeforeRound->{pending_issues} && !@$Tasks;
    die 'pending work did not produce a runnable scheduler task (check peer/retry state)' if !@$Tasks;
    for my $Queued (@$Tasks) {
        my ($ID, $Name, $LockKey) = @$Queued;
        die 'another scheduler worker owns this test task' if $LockKey;
        my %Task = $Scheduler->TaskGet(TaskID => $ID);
        die 'queued scheduler payload missing' if !$Task{TaskID} || ref($Task{Data}) ne 'HASH';
        die 'unexpected executor payload' if ($Task{Type} || '') ne 'AsynchronousExecutor'
            || ($Task{Data}->{Object} || '') ne 'Kernel::System::Redmine'
            || ($Task{Data}->{Function} || '') ne 'ProcessSyncBatch'
            || ref($Task{Data}->{Params}) ne 'HASH'
            || ($Task{Data}->{Params}->{SourceKey} || '') ne $Source
            || !length($Task{Data}->{Params}->{SeedIssueKey} || '');
        $Scheduler->TaskLock(TaskID => $ID, NodeID => $Config->Get('NodeID') || 1, PID => $$)
            or die 'cannot lock actual queued scheduler task';
        my $WorkBefore = work();
        my $NotesBefore = notes($BaselineArticle);
        my $TaskSQLBefore = questions();
        my $TaskStarted = time();
        $Executor->Run(TaskID => $ID, TaskName => $Name, Data => $Task{Data})
            or die 'real AsynchronousExecutor failed';
        # Match SchedulerTaskWorker exactly: flush transactional events while
        # this task still consumes bridge capacity, then delete its queue row.
        $Kernel::OM->ObjectEventsHandle();
        $EventFlushes++;
        my $WhileFlushing = own_tasks();
        die 'running task disappeared before transactional events flushed'
            if !grep {$_->[0] == $ID} @$WhileFlushing;
        die 'capacity exceeded during event flush' if @$WhileFlushing > $Workers;
        $CapacityChecks++;
        $Scheduler->TaskDelete(TaskID => $ID) or die 'cannot delete completed scheduler task';
        my $AfterTask = work();
        die 'worker left a durable delivery error' if $AfterTask->{durable_errors};
        $TasksExecuted++;
        push @Slices, {
            task_id => 0 + $ID, pending_before => $WorkBefore->{pending_issues},
            pending_after => $AfterTask->{pending_issues}, max_cursor_after => $AfterTask->{max_cursor},
            progressed_issues_after => $AfterTask->{progressed_issues},
            notes_created => 0 + notes($BaselineArticle) - $NotesBefore,
            sql_queries => questions() - $TaskSQLBefore - 1,
            wall_seconds => time() - $TaskStarted, events_flushed => 1,
        };
    }
    # The task row has gone, so the next Run can schedule the next persisted
    # slice immediately; it does not wait for the five-minute legacy cron.
}
my $After = work();
my $RemainingTasks = own_tasks();
die 'fixture source did not drain inside max_rounds' if $After->{pending_issues} || @$RemainingTasks;
die 'proof requires queued delivery work; prepare a changed peer scenario first' if !$TasksExecuted;
my $Notes = 0 + notes($BaselineArticle);
if (defined $Options->{expected_notes}) {
    die 'unexpected actual OTRS article count' if $Notes != $Options->{expected_notes};
}
my $PersistedReload = $Poller->{DiscardCount} == 60 && $Poller->{DiscardAt} > 0 ? 1 : 0;
print $JSON->encode({
    success => JSON::PP::true, fixture_tickets => scalar @IDs, linked_fixture_tickets => $LinkedTickets,
    registered_daemon => $DaemonModule, legacy_sync_cron_removed => JSON::PP::true,
    loaded_coordinator => $Loaded, source_key => $Source,
    execution_path => 'Poller.Run -> SchedulerDB.TaskAdd/TaskGet/TaskLock -> AsynchronousExecutor.Run -> ObjectEventsHandle -> TaskDelete',
    sync_workers => 0 + $Workers, maximum_own_scheduler_tasks => $MaxQueued,
    first_queue_count => $FirstQueue, tasks_executed => $TasksExecuted, rounds => $Rounds,
    capacity_checks => $CapacityChecks, event_flushes => $EventFlushes,
    before => $Before, after => $After, new_notes => $Notes,
    slices => \@Slices, sql_queries => questions() - $SQLBefore - 1,
    wall_seconds => time() - $Started,
    configuration_recycle_configured => $PersistedReload,
    scope => 'real registered daemon and core asynchronous executor; serial executor harness, not fork/process supervision',
}), "\n";
