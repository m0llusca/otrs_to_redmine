"""Exclusive actual-fork OTRS daemon proof and resident-process memory receipt.

Authoring does not run the lab. Explicit execution:
  python3 next_sync_native.py --allow-local-mutations \
    --seed tests/runtime/.state/next-sync-seed.sql --new-sync-sha256 SHA256

Targets are fixed to bridge-perf-local. Stop every other benchmark beforehand.
The override exists only in the lab container and is removed in finally cleanup.
RSS includes shared pages; whole-daemon proportional-set size is also sampled.
CPU from /proc sampling is a lower bound, not a CPU benchmark replacement.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import statistics
import subprocess
import time
from pathlib import Path
import run as lab
from next_sync_benchmark import Harness, write_json

HERE = Path(__file__).resolve().parent
EXPECTED_SEED = HERE / '.state' / 'next-sync-seed.sql'
OVERRIDE = '/opt/otrs/Kernel/Config/Files/ZZZBridgeBench.pm'
CONFIG = '/opt/otrs/Kernel/Config.pm'
CONFIG_BACKUP = '/opt/otrs/var/tmp/bridge-native-Config.pm.bak'
PID_DIR = '/opt/otrs/var/run/next-sync-native/'
PID_FILE = PID_DIR + 'Daemon-NodeID-1.pid'
DAEMON = '/opt/otrs/bin/otrs.Daemon.pl'
MODULES = {
    'RedmineBridgePoller': {'Module': 'Kernel::System::Daemon::DaemonModules::RedmineBridgePoller'},
    'SchedulerTaskWorker': {'Module': 'Kernel::System::Daemon::DaemonModules::SchedulerTaskWorker'},
}

# OTRS6's daemon keeps the original argv for all forks. The immediate child
# module is identified by its real redirected stdout logfile; worker forks are
# descendants of SchedulerTaskWorker. No production instrumentation is added.
SAMPLER = r'''
use strict; use warnings; use JSON::PP; use POSIX ();
my $Root;
if(open my $F,'<',$ARGV[0]) {local $/;$Root=<$F>;close $F;}
$Root=$ARGV[1] if !defined($Root)||$Root!~/\A\d+\s*\z/;
$Root=0 if !defined($Root)||$Root!~/\A\d+\s*\z/; $Root=0+$Root;
my $Known=JSON::PP->new->decode($ARGV[2]||'[]');my %Known=map {$_->[0]=>$_->[1]} @$Known;
my $Ticks=POSIX::sysconf(POSIX::_SC_CLK_TCK()); my %P;
for my $Dir (glob('/proc/[0-9]*')) {
    my ($ID)=$Dir=~m{/([0-9]+)$};
    open my $F,'<',"$Dir/stat" or next;my $S=<$F>;close $F;
    next if $S!~/\A\d+ \(.*\) (.*)\z/s;my @A=split /\s+/,$1;
    my ($RSS,$PSS)=(0,undef);
    if(open my $St,'<',"$Dir/status") {while(<$St>){$RSS=0+$1 if /^VmRSS:\s+(\d+)/;}close $St;}
    if(open my $Sm,'<',"$Dir/smaps_rollup") {while(<$Sm>){$PSS=0+$1 if /^Pss:\s+(\d+)/;}close $Sm;}
    my $FD=readlink("$Dir/fd/1")||'';
    $P{$ID}={pid=>0+$ID,ppid=>0+$A[1],state=>$A[0],rss_kib=>$RSS,pss_kib=>$PSS,
        cpu_ticks=>0+$A[11]+$A[12],start_ticks=>0+$A[19],stdout=>$FD};
}
my %Selected;
$Selected{$Root}=1 if $Root&&$P{$Root}&&(!exists($Known{$Root})||$P{$Root}->{start_ticks}==$Known{$Root});
for my $ID(keys %Known) {$Selected{$ID}=1 if $P{$ID}&&$P{$ID}->{start_ticks}==$Known{$ID};}
for(1..8) {my $Added=0;for my $ID(keys %P) {next if $Selected{$ID};
    if($Selected{$P{$ID}->{ppid}}) {$Selected{$ID}=1;$Added++;}}
    last if !$Added;
}
for my $ID(keys %Selected) {
    my $X=$P{$ID};
    $X->{role}=$ID==$Root?'supervisor':$X->{ppid}==$Root&&$X->{stdout}=~/RedmineBridgePollerOUT/?'poller':
        $X->{ppid}==$Root&&$X->{stdout}=~/SchedulerTaskWorkerOUT/?'scheduler_manager':'other';
}
for(1..8) {for my $ID(keys %Selected) {my $X=$P{$ID};my $Parent=$P{$X->{ppid}};
    $X->{role}='delivery_worker' if $Parent&&$Selected{$X->{ppid}}
        && ($Parent->{role}||'')=~/^(scheduler_manager|delivery_worker)$/;
}}
my @Rows=map {$P{$_}} sort {$a<=>$b} keys %Selected;
print JSON::PP->new->canonical->encode({root_pid=>$Root,clock_ticks=>$Ticks,processes=>\@Rows}),"\n";
'''
CONFIG_PROBE = r'''
use Kernel::System::ObjectManager;use JSON::PP;
local $Kernel::OM=Kernel::System::ObjectManager->new();my $C=$Kernel::OM->Get('Kernel::Config');
my $S=$Kernel::OM->Get('Kernel::System::Redmine::SyncStore');
print JSON::PP->new->canonical->encode({modules=>$C->Get('DaemonModules'),
    workers=>$C->Get('Redmine::SyncWorkers'),enabled=>$C->Get('Redmine::Enabled'),
    inbound=>$C->Get('Redmine::InboundSync'),base_url=>$C->Get('Redmine::BaseURL'),
    mailer=>$C->Get('SendmailModule'),pid_path=>$C->Get('Daemon::PID::Path'),source_key=>$S->SourceKey()}),"\n";
'''


def docker(args, **kwargs):
    flags = ['-i'] if 'input' in kwargs else []
    return lab.command(['docker', 'exec', *flags, lab.OTRS, *args], **kwargs)


def otrs(args, **kwargs):
    flags = ['-i'] if 'input' in kwargs else []
    return lab.command(['docker', 'exec', *flags, '-u', 'otrs', lab.OTRS, *args], **kwargs)


def exists(path):
    return subprocess.run(['docker', 'exec', lab.OTRS, 'test', '-e', path], capture_output=True).returncode == 0


def sample(root_pid=0, known_identities=None):
    return json.loads(otrs(['perl', '-e', SAMPLER, PID_FILE, str(root_pid), json.dumps(known_identities or [])]))


def sql(statement):
    output = lab.command(['docker', 'exec', '-i', lab.DB, 'sh', '-c',
        'exec mariadb --batch --skip-column-names -uroot -p"$MYSQL_ROOT_PASSWORD" "$OTRS_DB_NAME"'],
        input=statement + '\n')
    return [line.split('\t') for line in output.splitlines()]


def native_progress(source, baseline, ids):
    if len(source) != 64 or any(c not in '0123456789abcdef' for c in source):
        raise ValueError('invalid derived source key')
    objects = ','.join(str(int(value)) for value in ids)
    prefix = 'RedmineBridgeSync::' + source[:16] + '::%'
    row = sql(f"""SELECT
        (SELECT COUNT(*) FROM redmine_sync_issue WHERE source_key='{source}' AND generation>done_generation),
        (SELECT COALESCE(MAX(after_ticket_id),0) FROM redmine_sync_issue WHERE source_key='{source}'),
        (SELECT COUNT(*) FROM redmine_sync_issue WHERE source_key='{source}' AND last_error IS NOT NULL AND last_error<>''),
        (SELECT COUNT(*) FROM scheduler_task WHERE task_type='AsynchronousExecutor' AND name LIKE '{prefix}'),
        (SELECT COUNT(*) FROM scheduler_task WHERE task_type='AsynchronousExecutor' AND name LIKE '{prefix}' AND lock_key<>0),
        (SELECT COUNT(*) FROM article WHERE ticket_id IN ({objects}) AND id>{int(baseline)});
    """)[0]
    return dict(zip(('pending', 'max_cursor', 'errors', 'queued', 'running_tasks', 'new_notes'), map(int, row)))


def override_text(count, workers):
    settings = {
        'DaemonModules': MODULES, 'NodeID': 1, 'Daemon::PID::Path': PID_DIR,
        'Daemon::Log::STDOUT': 1, 'Daemon::Log::STDERR': 1,
        'Daemon::SchedulerTaskWorker::MaximumWorkers': workers,
        'Redmine::Enabled': 1, 'Redmine::InboundSync': 1, 'Redmine::AutoRetry': 0,
        'Redmine::BaseURL': 'http://redmine:8080', 'Redmine::APIKey': 'local-next-sync-only',
        'Redmine::SyncPollInterval': 5, 'Redmine::SyncBatchLimit': 50, 'Redmine::SyncWorkers': workers,
        'Redmine::SyncAttachments': 1, 'Redmine::NotifyOnStatusNote': 0,
        'Redmine::StatusSync': {'Проверка решения': 'open|note', 'New': 'closed successful'},
        'Redmine::MaxAttachmentBytes': 5000000, 'Redmine::MaxAttachmentTotalBytes': 20000000,
        'Redmine::MaxAttachmentCount': 20,
        'SendmailModule': 'Kernel::System::Email::DoNotSendEmail',
    }
    encoded = json.dumps(settings, ensure_ascii=True)
    return ('package Kernel::Config::Files::ZZZBridgeBench;\nuse strict; use warnings; use JSON::PP ();\n'
            'sub Load { my ($Package,$Self)=@_; my $Values=JSON::PP->new->decode(<<\'NATIVE_BENCH_JSON\');\n'
            + encoded + '\nNATIVE_BENCH_JSON\n'
            '$Self->{$_}=$Values->{$_} for keys %$Values;return 1;}\n1;\n')


def summarize(samples):
    peaks = {}
    identities = {}
    tree_rss = []
    tree_pss = []
    idle_pollers = []
    idle_trees = []
    for measurement in samples:
        processes = measurement['processes']
        tree_rss.append(sum(p['rss_kib'] for p in processes))
        if processes and all(p['pss_kib'] is not None for p in processes):
            tree_pss.append(sum(p['pss_kib'] for p in processes))
        for process in processes:
            role = process['role']
            peaks[role] = max(peaks.get(role, 0), process['rss_kib'])
            key = (process['pid'], process['start_ticks'])
            retained_role = identities.get(key, {}).get('role', role) if role == 'other' else role
            identities[key] = {**process, 'role': retained_role, 'clock_ticks': measurement['clock_ticks']}
        if measurement.get('idle') and not any(p['role'] == 'delivery_worker' for p in processes):
            idle_pollers.extend(p for p in processes if p['role'] == 'poller')
            idle_trees.append(processes)
    def median(values):
        return statistics.median(values) if values else None
    return {
        'peak_process_rss_kib_by_role': peaks,
        'peak_whole_daemon_rss_sum_kib': max(tree_rss, default=0),
        'peak_whole_daemon_pss_sum_kib': max(tree_pss, default=None),
        'idle_poller_median_rss_kib': median([p['rss_kib'] for p in idle_pollers]),
        'idle_poller_peak_rss_kib': max((p['rss_kib'] for p in idle_pollers), default=None),
        'idle_poller_median_pss_kib': median([p['pss_kib'] for p in idle_pollers if p['pss_kib'] is not None]),
        'idle_whole_daemon_median_rss_sum_kib': median([sum(p['rss_kib'] for p in rows) for rows in idle_trees]),
        'idle_whole_daemon_median_pss_sum_kib': median([
            sum(p['pss_kib'] for p in rows) for rows in idle_trees
            if all(p['pss_kib'] is not None for p in rows)]),
        'distinct_native_delivery_processes_observed': sum(p['role'] == 'delivery_worker' for p in identities.values()),
        'poller_pids_observed': sorted({p['pid'] for p in identities.values() if p['role'] == 'poller'}),
        'sampled_process_cpu_seconds_lower_bound': sum(p['cpu_ticks'] / p['clock_ticks'] for p in identities.values()),
        'rss_boundary': 'RSS sums count shared fork pages repeatedly; PSS sum apportions shared pages. Persistent poller memory is additional to the per-worker benchmark peak, not included in that peak.',
        'cpu_boundary': 'Sampled /proc CPU ticks can miss short-lived workers and worker tail CPU; do not use as before/after CPU comparison.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-local-mutations', action='store_true')
    parser.add_argument('--seed', required=True)
    parser.add_argument('--new-sync-sha256', required=True)
    parser.add_argument('--new-version', default='1.0.31')
    parser.add_argument('--count', type=int, default=1000, choices=(100, 1000))
    parser.add_argument('--workers', type=int, default=2, choices=(1, 2, 3, 4))
    parser.add_argument('--timeout', type=int, default=900)
    parser.add_argument('--idle-seconds', type=int, default=15)
    args = parser.parse_args()
    if not args.allow_local_mutations:
        parser.error('Explicit --allow-local-mutations is required; stop all other benchmarks first.')
    if Path(args.seed).resolve(strict=True) != EXPECTED_SEED.resolve(strict=True):
        parser.error('Only the explicit tests/runtime/.state/next-sync-seed.sql snapshot is allowed.')
    if not 30 <= args.timeout <= 900 or not 5 <= args.idle_seconds <= 120:
        parser.error('timeout must be 30..900; idle-seconds must be 5..120.')
    # Read-only preflight gates run before restoration or scheduler cleanup.
    for container in (lab.OTRS, lab.DB, lab.PEER):
        labels = json.loads(lab.command(['docker', 'inspect', '--format', '{{json .Config.Labels}}', container]))
        if labels.get('com.docker.compose.project') != 'bridge-perf-local':
            raise RuntimeError('Refusing a container outside the fixed isolated Compose project.')
        networks = json.loads(lab.command(['docker', 'inspect', '--format', '{{json .NetworkSettings.Networks}}', container]))
        if not networks:
            raise RuntimeError('Isolated test container has no known network.')
        for network in networks:
            internal = lab.command(['docker', 'network', 'inspect', '--format', '{{.Internal}}', network]).strip()
            if internal != 'true':
                raise RuntimeError('Refusing a test container attached to a non-internal network.')
    installed = subprocess.check_output(['docker', 'exec', lab.OTRS, 'cat', '/opt/otrs/Kernel/System/Redmine/Sync.pm'])
    if hashlib.sha256(installed).hexdigest() != args.new_sync_sha256:
        raise RuntimeError('Installed Sync.pm does not match approved SHA256.')
    running = docker(['ps', '-eo', 'args'])
    if any('/bench/' in line and any(name in line for name in (
            'next_sync_benchmark.pl', 'runner.pl', 'sync_audit.pl', 'next_sync_daemon.pl'))
            for line in running.splitlines()):
        raise RuntimeError('Another lab worker is active; this proof requires exclusive use.')
    if any('otrs.Daemon.pl' in line and 'start' in line for line in running.splitlines()):
        raise RuntimeError('A daemon is already running; do not take over another run.')
    if exists(OVERRIDE) or exists(CONFIG_BACKUP):
        raise RuntimeError('Native override already exists; preserve and inspect previous run first.')
    peer = lab.peer_stats()
    if not {'config', 'response_bytes', 'open_connections'} <= peer.keys():
        raise RuntimeError('The isolated fake peer must run next_sync_peer.mjs.')

    harness = Harness(args, label='native-daemon')
    environment_file = harness.out / 'environment.json'
    environment = json.loads(environment_file.read_text())
    environment.update({
        'measurement': 'actual native daemon supervisor and SchedulerTaskWorker forks; /proc RSS/PSS sampling includes persistent poller, managers and delivery children',
        'aggregation': 'peak process RSS by role; peak whole-tree RSS/PSS; idle median poller and whole-tree footprint; sampled CPU is lower-bound only',
        'validation': 'real queued native fork delivery and post-drain core article/checkpoint verification',
        'native_only': True,
    })
    write_json(environment_file, environment)
    report = {'complete': False, 'started_at_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'fixture_count': args.count, 'native_fork_supervision': True, 'samples': [], 'progress': [],
              'cleanup': {}, 'scope': 'actual OTRS daemon supervisor, only poller and native scheduler worker modules; local controlled HTTP peer'}
    output = harness.out / 'native-daemon.json'
    write_json(output, report)
    override_owned = False
    config_owned = False
    start_attempted = False
    primary_error = None
    try:
        harness.restore()
        fixture = harness.perl('new', 'prepare', 'mass_shared', count=args.count)
        harness.peer({'issueIDs': fixture['issue_ids'], 'phase': 'changed', 'attachments': False})
        # No production scheduler/database is reachable: the project + seed +
        # source gates above restrict this reset to the synthetic local stack.
        sql('DELETE FROM scheduler_task;')
        text = override_text(args.count, args.workers)
        otrs(['perl', '-MFcntl=O_WRONLY,O_CREAT,O_EXCL', '-e',
              'sysopen(my $F,$ARGV[0],O_WRONLY|O_CREAT|O_EXCL,0600) or die "override exists";local $/;print {$F} <STDIN>;close $F or die "override write failed";', OVERRIDE], input=text)
        override_owned = True
        # Core calls Config.pm::Load again after Files/*.pm, so its mailer
        # settings win over a file override. Reapply this isolated test config
        # at that final call; preserve and restore the exact container file.
        original_config = subprocess.check_output(['docker', 'exec', lab.OTRS, 'cat', CONFIG])
        marker = b'    return 1;'
        if original_config.count(marker) != 1:
            raise RuntimeError('Unexpected lab Config.pm; refusing to patch it.')
        report['original_config_sha256'] = hashlib.sha256(original_config).hexdigest()
        docker(['cp', '--', CONFIG, CONFIG_BACKUP])
        config_owned = True
        addition = (b"    require Kernel::Config::Files::ZZZBridgeBench;\n"
                    b"    Kernel::Config::Files::ZZZBridgeBench->Load($Self);\n")
        docker(['sh', '-c', 'cat > "$1"', 'write', CONFIG],
               input=original_config.replace(marker, addition + marker).decode())
        otrs(['/opt/otrs/bin/otrs.Console.pl', 'Maint::Config::Rebuild'], timeout=90)
        otrs(['/opt/otrs/bin/otrs.Console.pl', 'Maint::Cache::Delete'], timeout=60)
        config = json.loads(otrs(['perl', '-I/opt/otrs', '-I/opt/otrs/Kernel/cpan-lib', '-e', CONFIG_PROBE]))
        report['config_probe'] = config
        if config['modules'] != MODULES or int(config['workers']) != args.workers:
            raise RuntimeError('Container-only configuration did not restrict actual daemon modules/workers.')
        if config['base_url'] != 'http://redmine:8080' or config['pid_path'] != PID_DIR:
            raise RuntimeError('Actual fresh core configuration escaped isolated endpoint/PID directory.')
        if config['mailer'] != 'Kernel::System::Email::DoNotSendEmail' or not config['enabled'] or not config['inbound']:
            raise RuntimeError('Actual daemon configuration mail/sync restrictions failed.')
        report['fixture'] = fixture
        start_attempted = True
        report['daemon_start'] = otrs(['sh', '-c',
            'exec /opt/otrs/bin/otrs.Daemon.pl start </dev/null >/opt/otrs/var/tmp/bridge-native-supervisor.log 2>&1'], timeout=30)
        started = time.monotonic()
        deadline = started + args.timeout
        next_progress = started
        drained_at = None
        first_work_seen = False
        seen_native_workers = False
        while time.monotonic() < deadline:
            measured = sample()
            measured['elapsed_seconds'] = time.monotonic() - started
            if not measured['root_pid'] and measured['elapsed_seconds'] > 20:
                raise RuntimeError('Native supervisor did not create its own PID file.')
            measured['idle'] = drained_at is not None
            report['samples'].append(measured)
            if measured['elapsed_seconds'] > 10 and not measured['processes']:
                raise RuntimeError('Owned native daemon supervisor exited before completion.')
            native_workers = sum(p['role'] == 'delivery_worker' for p in measured['processes'])
            if native_workers > args.workers:
                raise AssertionError('Observed native delivery fork count exceeds SyncWorkers.')
            seen_native_workers |= bool(native_workers)
            now = time.monotonic()
            if now >= next_progress:
                progress = native_progress(config['source_key'], fixture['baseline_article_id'], fixture['ticket_ids'])
                progress['elapsed_seconds'] = now - started
                report['progress'].append(progress)
                if progress['queued'] > args.workers:
                    raise AssertionError('Actual queued/running scheduler tasks exceeded SyncWorkers.')
                if progress['errors']:
                    raise AssertionError('Native core worker persisted a delivery error.')
                first_work_seen |= progress['pending'] > 0 or progress['new_notes'] > 0
                print(json.dumps({'native_progress': progress, 'native_workers': native_workers}), flush=True)
                if first_work_seen and not progress['pending'] and not progress['queued'] and progress['new_notes'] == args.count:
                    drained_at = drained_at or now
                next_progress = now + 1
                write_json(output, report)
            if drained_at is not None and now - drained_at >= args.idle_seconds:
                break
            time.sleep(0.25)
        else:
            raise TimeoutError('Actual native daemon did not drain and complete idle sampling before timeout.')
        if not seen_native_workers:
            raise AssertionError('No actual SchedulerTaskWorker child was sampled; fork proof unavailable.')
        check = harness.inspect('new', 'mass_shared', fixture, content=True)
        if check['new_notes'] != args.count or check['tickets_with_notes'] != args.count or check['max_notes_per_ticket'] != 1:
            raise AssertionError('Native worker produced missing or duplicate OTRS notes.')
        if check['work']['pending'] or check['work']['total'] != 1:
            raise AssertionError('Native shared-issue durable fanout did not drain.')
        if check['checkpoints']['RedmineLastJournalID'] != [['11', args.count]] or check['states'] != [['open', args.count]]:
            raise AssertionError('Actual native ticket checkpoints/states are incomplete.')
        report['validation'] = check
        report['peer'] = harness.stats()
        # Recheck the complete delivered source through the public poll/worker
        # path; identical source activity must not create a second note.
        replay_poll = harness.perl('new', 'worker', 'verify', mode='poll', count=args.count)
        if not replay_poll['result'].get('Success'):
            raise AssertionError('Post-delivery source replay failed.')
        replay_workers = harness.drain('verify', fixture)
        replay = harness.inspect('new', 'verify', fixture)
        if replay['new_notes'] != args.count or replay['max_notes_per_ticket'] != 1:
            raise AssertionError('Native complete-source replay created duplicate notes.')
        report['replay'] = {'poll': replay_poll, 'workers': replay_workers, 'validation': replay}
        report['memory'] = summarize(report['samples'])
        if report['memory']['idle_poller_median_rss_kib'] is None:
            raise AssertionError('Resident idle poller was not identifiable from native core process tree.')
        report['drain_wall_seconds'] = drained_at - started
        report['complete'] = True
    except BaseException as error:
        primary_error = error
        report['error'] = lab.redact(str(error))
    finally:
        # Stop only the daemon that this proof started, while its PID override
        # still exists. Reap its entire known tree before removing that config.
        cleanup_errors = []
        if start_attempted:
            try:
                last_tree = sample()
                known = {(p['pid'], p['start_ticks']) for measurement in report['samples'] + [last_tree]
                         for p in measurement['processes']}
                owned_root = last_tree['root_pid'] or next(
                    (row['root_pid'] for row in reversed(report['samples']) if row['root_pid']), 0)
                if not owned_root:
                    processes = docker(['ps', '-eo', 'args'])
                    if any('otrs.Daemon.pl' in line and 'start' in line for line in processes.splitlines()):
                        raise RuntimeError('Daemon start has no owned PID receipt; override retained for explicit recovery.')
                report['cleanup']['stop'] = otrs([DAEMON, 'stop'], timeout=40)
                for _ in range(120):
                    # Core stop removes its PID file before all processes exit.
                    # Track PID+start-time identities as well, including workers
                    # orphaned while their scheduler manager is stopping.
                    current = sample(owned_root, sorted(known))
                    known.update((p['pid'], p['start_ticks']) for p in current['processes'])
                    # This minimal container's PID 1 is tail, which may retain
                    # reparented zombies. They have exited and hold no memory.
                    if not any(p['state'] != 'Z' for p in current['processes']):
                        report['cleanup']['exited_zombies_retained_by_container_init'] = len(current['processes'])
                        break
                    time.sleep(0.25)
                else:
                    raise RuntimeError('Owned native daemon tree remains after graceful stop; override retained for recovery.')
                report['cleanup']['native_tree_stopped'] = True
            except BaseException as error:
                cleanup_errors.append(lab.redact(str(error)))
        if override_owned and (not start_attempted or report['cleanup'].get('native_tree_stopped')):
            try:
                if config_owned:
                    docker(['cp', '--', CONFIG_BACKUP, CONFIG])
                    restored = subprocess.check_output(['docker', 'exec', lab.OTRS, 'cat', CONFIG])
                    if hashlib.sha256(restored).hexdigest() != report['original_config_sha256']:
                        raise RuntimeError('Lab Config.pm restoration hash mismatch.')
                    docker(['rm', '--', CONFIG_BACKUP])
                    report['cleanup']['original_config_restored'] = True
                otrs(['rm', '--', OVERRIDE])
                otrs(['/opt/otrs/bin/otrs.Console.pl', 'Maint::Config::Rebuild'], timeout=90)
                otrs(['/opt/otrs/bin/otrs.Console.pl', 'Maint::Cache::Delete'], timeout=60)
                report['cleanup']['override_removed_and_config_rebuilt'] = True
            except BaseException as error:
                cleanup_errors.append(lab.redact(str(error)))
        if cleanup_errors:
            report['cleanup']['errors'] = cleanup_errors
            report['complete'] = False
        report['memory'] = summarize(report['samples'])
        report['finished_at_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        write_json(output, report)
    print(output, flush=True)
    if primary_error is not None:
        raise primary_error
    if not report['complete']:
        raise RuntimeError('Native proof cleanup incomplete; inspect saved receipt before another run.')


if __name__ == '__main__':
    main()
