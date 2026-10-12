"""Existing create/upload/link behavior through actual installed OTRS core.

Run only AFTER the exclusive next-sync benchmark/verification. The operator must
first switch the isolated fake peer service back to `node /bench/redmine.mjs`.
This script never switches/restarts services and never modifies installed code.
It restores the explicitly supplied post-1.0.31-schema SQL seed for every case;
.state/seed.sql and previous reports are never replaced.

  python3 tests/runtime/next_sync_regressions.py --allow-local-mutations \
    --seed tests/runtime/.state/next-sync-seed.sql --new-sync-sha256 SHA256

Default report: results/next-sync/functional-legacy-paths.json. If that report
already exists, supply a new --output path; prior evidence is preserved.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time
import run as lab

HERE = Path(__file__).resolve().parent
DEFAULT_OUTPUT = HERE / 'results' / 'next-sync' / 'functional-legacy-paths.json'
OUTBOUND_BYTES = 1024 * 1024
FORM_BYTES = 512 * 1024


def restore_seed(seed):
    with seed.open('rb') as stream:
        result = subprocess.run(['docker', 'exec', '-i', lab.DB, 'sh', '-c',
            'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$OTRS_DB_NAME"'],
            stdin=stream, capture_output=True)
    if result.returncode:
        raise RuntimeError(lab.redact(result.stderr.decode()))


def control(scenario):
    script = 'fetch("http://localhost:8080/__control",{method:"POST",body:JSON.stringify({scenario:process.argv[1],verifyUploads:true})}).then(r=>{if(!r.ok)throw Error(r.status);return r.json()}).then(x=>console.log(JSON.stringify(x)))'
    return json.loads(lab.command(['docker', 'exec', lab.PEER, 'node', '-e', script, scenario]))


def upload_backend_probe(use_fs=False):
    """Same explicit FS configuration as runner.pl; verify loaded core backend."""
    code = r'''
use strict; use warnings; use lib '/opt/otrs','/opt/otrs/Kernel/cpan-lib';
use Kernel::System::ObjectManager; use JSON::PP;
local $Kernel::OM=Kernel::System::ObjectManager->new();
my $Config=$Kernel::OM->Get('Kernel::Config');
$Config->Set(Key=>'WebUploadCacheModule',Value=>'Kernel::System::Web::UploadCache::FS') if $ARGV[0] eq 'FS';
my $Upload=$Kernel::OM->Get('Kernel::System::Web::UploadCache');
my $Expected='Kernel/System/Web/UploadCache/'.$ARGV[0].'.pm';
die "Expected core UploadCache backend was not loaded" if !$INC{$Expected};
my $Configured=$Config->Get('WebUploadCacheModule') || '';
die "Unexpected configured UploadCache backend" if length($Configured) && $Configured ne 'Kernel::System::Web::UploadCache::'.$ARGV[0];
print JSON::PP->new->canonical->encode({requested=>$ARGV[0],configured=>$Configured,loaded=>$INC{$Expected}}),"\n";
'''
    return json.loads(lab.command(['docker', 'exec', '-u', 'otrs', lab.OTRS, 'perl', '-e', code, 'FS' if use_fs else 'DB']).strip().splitlines()[-1])


def validate_uploads(peer, expected_bytes, expected_byte, filenames):
    count = len(filenames)
    expected_hash = hashlib.sha256(expected_byte * expected_bytes).hexdigest()
    assert peer['uploaded_bytes'] == [expected_bytes] * count, 'uploaded byte counts differ'
    assert peer['uploaded_hashes'] == [expected_hash] * count, 'uploaded SHA256 differs'
    files = peer['attached']
    assert len(files) == count, 'upload tokens were not attached to the issue'
    assert {item['token'] for item in files} == {f'bench-{i}' for i in range(1, count + 1)}, 'token missing or reused'
    assert {item['filename'] for item in files} == set(filenames), 'attachment filename differs'
    assert all(item['content_type'] == 'application/octet-stream' for item in files), 'attachment MIME type differs'
    issue = peer['created']
    assert issue['subject'] == 'Benchmark create'
    assert issue['description'] == 'Fixed description'
    for key, value in (('project_id', 1), ('tracker_id', 2), ('priority_id', 2), ('assigned_to_id', 2)):
        assert int(issue[key]) == value, f'{key} differs'
    assert issue['due_date'] == '2026-12-01'
    assert peer['counts'].get('POST /issues.json', 0) == 1, 'create executed more than once'
    assert sum(value for key, value in peer['counts'].items() if key.startswith('POST /uploads.json')) == count
    assert peer['open_data_connections'] == 0, 'operation-scoped HTTP client survived the worker'
    return {'files': count, 'bytes_per_file': expected_bytes, 'sha256': expected_hash,
        'tokens_attached_once': True, 'description_priority_assignee_due_date': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-local-mutations', action='store_true')
    parser.add_argument('--seed', required=True, help='explicit 1000-ticket SQL seed captured after 1.0.31 schema installation')
    parser.add_argument('--new-sync-sha256', required=True, help='approved installed Sync.pm SHA256')
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    if not args.allow_local_mutations:
        parser.error('--allow-local-mutations is required; stop the exclusive benchmark first')
    seed = Path(args.seed).resolve(strict=True)
    output = args.output.resolve()
    if output.exists():
        raise FileExistsError(f'Preserving previous report: {output}; use a new --output path')
    # Fail before database restoration if the service still runs the new peer.
    peer = lab.peer_stats()
    if not {'scenario', 'data_connections', 'open_data_connections', 'uploaded_hashes'} <= peer.keys():
        raise RuntimeError('Switch only the isolated fake peer to /bench/redmine.mjs before this script')
    installed = subprocess.check_output(['docker', 'exec', lab.OTRS, 'cat', '/opt/otrs/Kernel/System/Redmine/Sync.pm'])
    actual_sha = hashlib.sha256(installed).hexdigest()
    if actual_sha != args.new_sync_sha256:
        raise AssertionError('Installed Sync.pm does not match the approved 1.0.31 source hash')
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {
        'installed_version': '1.0.31', 'installed_sync_sha256': actual_sha,
        'seed': str(seed), 'seed_sha256': hashlib.sha256(seed.read_bytes()).hexdigest(),
        'started_at_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'targets': {'otrs': lab.OTRS, 'db': lab.DB, 'fake_peer': lab.PEER},
        'scope': 'actual installed OTRS core + original runner.pl; controlled legacy peer only; functional checks, not benchmark comparisons',
        'cases': [], 'complete': False,
    }
    # Reserve the evidence filename exclusively, before any mutation.
    with output.open('x') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')

    def persist(case):
        report['cases'].append(case)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(case['name'] + ': PASS', flush=True)

    for name, scenario, use_fs in (
        ('outbound_16x1MiB', 'outbound', False),
        ('form_extra_DB', 'extra', False),
        ('form_extra_FS', 'extra', True),
    ):
        restore_seed(seed)
        prepared = lab.perl('installed', 'prepare', scenario)
        backend = upload_backend_probe(use_fs) if scenario == 'extra' else None
        extra = lab.perl('installed', 'extra-setup', upload_fs=use_fs) if scenario == 'extra' else None
        control(scenario)
        worker = lab.perl('installed', 'run', scenario, upload_fs=use_fs)
        peer = lab.peer_stats()
        assert worker['checks']['operation_success'] == 1
        assert worker['checks']['new_notes'] == 1, 'bridge create note missing or duplicated'
        expected = validate_uploads(peer,
            OUTBOUND_BYTES if scenario == 'outbound' else FORM_BYTES,
            b'A' if scenario == 'outbound' else b'E',
            [f'outgoing-{i}.bin' for i in range(1, 17)] if scenario == 'outbound' else ['extra.bin'])
        persist({'name': name, 'prepared': prepared, 'upload_cache': backend,
            'extra_setup': extra, 'worker': worker, 'peer': peer, 'assertions': expected})

    restore_seed(seed)
    prepared = lab.perl('installed', 'prepare', 'outbound')
    control('unchanged')
    links = lab.perl('installed', 'verify-links')
    assert links['link_relink_unlink'] and links['stream_cursor_cleared']
    peer = lab.peer_stats()
    assert peer['open_data_connections'] == 0
    assert not peer['uploaded_bytes'], 'link/relink/unlink unexpectedly uploaded data'
    assert peer['created'] is None, 'link-only path unexpectedly created a Redmine issue'
    persist({'name': 'link_relink_unlink', 'prepared': prepared, 'worker': links, 'peer': peer})
    report['complete'] = True
    report['finished_at_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    main()
