"""Reproducible 1.0.30 overlay vs installed 1.0.31 comparison in the local lab.

Preparation (performed/authorized separately): install new OPM/schema, grow audit
fixture to 1000 with sync_audit.pl grow, dump a full SQL seed, restart only the
fake redmine service with command `node /bench/next_sync_peer.mjs`.

Run explicitly:
  python3 next_sync_benchmark.py --allow-local-mutations --seed PATH \
    --new-sync-sha256 SHA256 [--idle-repeats 3 --mass-repeats 1]

The explicit gate protects against accidentally executing this harness while it
is only being authored/reviewed. All targets are fixed to bridge-perf-local.
Each run creates a fresh timestamp/UUID directory; earlier evidence is preserved.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import time
import uuid
import run as lab

HERE = Path(__file__).resolve().parent
RESULTS = HERE / 'results' / 'next-sync'
SCENARIOS = ('steady_shared', 'steady_unique', 'mass_shared', 'mass_distinct')
BINARY_SHA = hashlib.sha256(bytes((0, 255, 128, 65))).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


class Harness:
    def __init__(self, args, label='benchmark'):
        if not args.allow_local_mutations:
            raise RuntimeError('Explicit --allow-local-mutations is required for the isolated lab.')
        self.args = args
        self.seed = Path(args.seed).resolve(strict=True)
        self.out = RESULTS / (time.strftime('%Y%m%d-%H%M%S') + '-' + label + '-' + uuid.uuid4().hex[:8])
        self.out.mkdir(parents=True, exist_ok=False)
        self.old_sha = hashlib.sha256((HERE / '.state/release-1.0.30/Kernel/System/Redmine/Sync.pm').read_bytes()).hexdigest()
        write_json(self.out / 'environment.json', {
            'seed': str(self.seed), 'seed_sha256': hashlib.sha256(self.seed.read_bytes()).hexdigest(),
            'old_version': '1.0.30', 'old_sync_sha256': self.old_sha,
            'new_version': args.new_version, 'new_sync_sha256': args.new_sync_sha256,
            'targets': {'otrs': lab.OTRS, 'db': lab.DB, 'fake_peer': lab.PEER},
            'measurement': 'fresh daemon-style worker per call; bootstrap excluded; ObjectEventsHandle included; RSS captured before validation',
            'aggregation': 'CPU/wall/SQL sums; peak RSS max; peer HTTP/connections/response bytes over complete sweep',
            'validation': 'separate processes after measured workers; no SQL wrappers or TicketGet instrumentation',
            'database': 'actual OTRS MariaDB connection SHOW SESSION Questions includes raw DBI store queries',
            'cache': 'process memory disabled, shared backend enabled; cache cleared once after each SQL restoration',
        })

    def perl(self, variant, action, scenario, **options):
        start = time.monotonic()
        result = subprocess.run(['docker', 'exec', '-u', 'otrs', lab.OTRS, 'perl',
            '/bench/next_sync_benchmark.pl', variant, action, scenario,
            json.dumps(options, ensure_ascii=False)], capture_output=True, text=True, timeout=900)
        if result.returncode:
            raise RuntimeError(lab.redact(result.stderr + result.stdout)[-6000:])
        value = json.loads(result.stdout.strip().splitlines()[-1])
        value['host_process_wall_seconds'] = time.monotonic() - start
        if result.stderr.strip():
            value['stderr'] = lab.redact(result.stderr.strip())
        if action in ('worker', 'prepare'):
            expected = self.old_sha if variant == 'old' else self.args.new_sync_sha256
            if value['sync_sha256'] != expected:
                raise AssertionError(f'{variant} loaded unexpected Sync.pm SHA256')
            if action == 'worker':
                assert value['cache_mode'] == 'backend_only' and value['events_flushed'] == 1
                assert value['variable_check'].replace('//', '/').startswith(('/opt/otrs/', '/Kernel/')), 'core dependency shadowed'
        return value

    def restore(self, seed=None):
        with Path(seed or self.seed).open('rb') as stream:
            result = subprocess.run(['docker', 'exec', '-i', lab.DB, 'sh', '-c',
                'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$OTRS_DB_NAME"'],
                stdin=stream, capture_output=True)
        if result.returncode:
            raise RuntimeError(lab.redact(result.stderr.decode()))
        self.perl('new', 'clear-cache', 'setup')

    def dump(self, path):
        with path.open('xb') as stream:
            result = subprocess.run(['docker', 'exec', lab.DB, 'sh', '-c',
                'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --skip-comments "$OTRS_DB_NAME"'],
                stdout=stream, stderr=subprocess.PIPE)
        path.chmod(0o600)
        if result.returncode:
            raise RuntimeError(lab.redact(result.stderr.decode()))

    def peer(self, config):
        script = 'fetch("http://localhost:8080/__control",{method:"POST",body:process.argv[1]}).then(r=>{if(!r.ok)throw Error(r.status);return r.json()}).then(x=>console.log(JSON.stringify(x)))'
        return json.loads(lab.command(['docker', 'exec', lab.PEER, 'node', '-e', script, json.dumps(config, ensure_ascii=False)]))

    def stats(self):
        script = 'fetch("http://localhost:8080/__stats").then(r=>r.json()).then(x=>console.log(JSON.stringify(x)))'
        return json.loads(lab.command(['docker', 'exec', lab.PEER, 'node', '-e', script]))

    def inspect(self, variant, scenario, fixture, content=False):
        return self.perl(variant, 'inspect', scenario, count=fixture['prepared'],
            baseline_article_id=fixture['baseline_article_id'], verify_content=content)

    def drain(self, scenario, fixture, max_workers=200, allow_failure=False):
        workers = []
        for _ in range(max_workers):
            work = self.inspect('new', scenario, fixture)['work']
            if not work['pending']:
                return workers
            if not work['due']:
                if allow_failure:
                    return workers
                raise AssertionError('work remains delayed/leased after benchmark delivery')
            worker = self.perl('new', 'worker', scenario, mode='deliver', count=fixture['prepared'],
                source_key=work['source_key'], seed_issue_key=work['first_issue_key'])
            workers.append(worker)
            if not worker['result'].get('Success'):
                if allow_failure:
                    return workers
                raise AssertionError(f'delivery failed: {worker["result"]}')
        work = self.inspect('new', scenario, fixture)['work']
        if work['pending']:
            raise AssertionError(f'{work["pending"]} pending issues after {max_workers} bounded workers; bounded delivery did not drain; inspect per-worker Processed/deadline metrics')
        return workers

    def warm_seed(self, variant, scenario):
        self.restore()
        fixture = self.perl(variant, 'prepare', scenario)
        self.peer({'issueIDs': fixture['issue_ids'], 'phase': 'steady'})
        if variant == 'old':
            # No durable outbox exists in 1.0.30; prepared fixture is its baseline.
            warmup = []
        else:
            warmup = [self.perl('new', 'worker', scenario, mode='poll')]
            assert warmup[0]['result'].get('Success'), warmup[0]['result']
            warmup += self.drain(scenario, fixture)
        check = self.inspect(variant, scenario, fixture, content=True)
        assert check['new_notes'] == 0, 'steady warmup fabricated notes'
        if variant == 'new':
            assert check['work']['total'] == len(fixture['issue_ids'])
            assert check['work']['pending'] == 0, 'real new warmup did not finish'
        path = self.out / f'warm-{variant}-{scenario}.sql'
        self.dump(path)
        write_json(self.out / f'warm-{variant}-{scenario}.json', {'fixture': fixture, 'workers': warmup, 'validation': check})
        return path, fixture

    def trial(self, variant, scenario, repeat, seed, fixture):
        self.restore(seed)
        mass = scenario.startswith('mass_')
        self.peer({'issueIDs': fixture['issue_ids'], 'phase': 'changed' if mass else 'steady',
            'attachments': scenario == 'mass_shared'})
        start = time.monotonic()
        if variant == 'old':
            workers = [self.perl('old', 'worker', scenario, mode='cron') for _ in range(20)]
        else:
            workers = [self.perl('new', 'worker', scenario, mode='poll')]
            assert workers[0]['result'].get('Success'), workers[0]['result']
            if mass:
                workers += self.drain(scenario, fixture)
        host_wall = time.monotonic() - start
        write_json(self.out / f"{scenario}-{variant}-{repeat}-workers.json", {"workers": workers})
        check = self.inspect(variant, scenario, fixture, content=True)
        expected = 1000 if mass else 0
        assert check['new_notes'] == expected and check['tickets_with_notes'] == expected, check
        assert check['max_notes_per_ticket'] == (1 if mass else 0), 'duplicate/missing note'
        expected_files = 1000 if scenario == 'mass_shared' else 0
        assert check['attachments'] == expected_files, 'attachment fanout mismatch'
        assert all(value == BINARY_SHA for value in check['attachment_hashes']), 'binary attachment bytes changed'
        if mass:
            assert check['checkpoints']['RedmineLastJournalID'] == [['11', 1000]], check['checkpoints']
            assert check['checkpoints']['RedmineStatus'] == [['Проверка решения', 1000]], check['checkpoints']
            assert check['states'] == [['open', 1000]], check['states']
        if variant == 'new':
            assert check['work']['pending'] == 0, 'unacknowledged durable work'
        peer = self.stats()
        assert peer['open_connections'] == 0, 'HTTP client escaped worker lifetime'
        row = {'variant': variant, 'scenario': scenario, 'repeat': repeat, 'workers': workers,
            'worker_count': len(workers), 'host_orchestration_wall_seconds': host_wall,
            'peer': peer, 'validation': check}
        for field in ('cpu_seconds', 'cpu_user_seconds', 'cpu_system_seconds', 'wall_seconds', 'sql_queries', 'host_process_wall_seconds'):
            row[field] = sum(worker[field] for worker in workers)
        row['peak_rss_kib'] = max(worker['peak_rss_kib'] for worker in workers)
        row['http_requests'] = sum(peer['counts'].values())
        row['connections'] = peer['connections']
        row['response_bytes'] = peer['response_bytes']
        write_json(self.out / f'{scenario}-{variant}-{repeat}.json', row)
        return row


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--allow-local-mutations', action='store_true')
    p.add_argument('--seed', required=True, help='full 1000-ticket SQL dump, after 1.0.31 schema installation')
    p.add_argument('--new-sync-sha256', required=True, help='expected installed Sync.pm SHA256 from approved manifest')
    p.add_argument('--new-version', default='1.0.31')
    p.add_argument('--idle-repeats', type=int, default=3)
    p.add_argument('--mass-repeats', type=int, default=1)
    p.add_argument('--scenarios', nargs='+', choices=SCENARIOS, default=list(SCENARIOS))
    return p


def main():
    args = parser().parse_args()
    h = Harness(args)
    trials = []
    warm_seeds = {}
    for scenario in args.scenarios:
        shape = 'steady_unique' if scenario in ('steady_unique', 'mass_distinct') else 'steady_shared'
        if shape not in warm_seeds:
            warm_seeds[shape] = {variant: h.warm_seed(variant, shape) for variant in ('old', 'new')}
        seeds = warm_seeds[shape]
        repeats = args.mass_repeats if scenario.startswith('mass_') else args.idle_repeats
        for repeat in range(1, repeats + 1):
            for variant in (('old', 'new') if repeat % 2 else ('new', 'old')):
                row = h.trial(variant, scenario, repeat, *seeds[variant])
                trials.append(row)
                write_json(h.out / 'raw.json', trials)
                print(f'{scenario} {variant} #{repeat}: CPU={row["cpu_seconds"]:.3f}s RSS={row["peak_rss_kib"]/1024:.2f}MiB SQL={row["sql_queries"]} HTTP={row["http_requests"]} workers={row["worker_count"]}', flush=True)
    fields = ('cpu_seconds', 'wall_seconds', 'peak_rss_kib', 'sql_queries', 'http_requests', 'connections', 'response_bytes', 'worker_count')
    summary = {}
    for scenario in args.scenarios:
        summary[scenario] = {}
        for variant in ('old', 'new'):
            rows = [row for row in trials if row['scenario'] == scenario and row['variant'] == variant]
            summary[scenario][variant] = {field: statistics.median(row[field] for row in rows) for field in fields}
            summary[scenario][variant]['repeats'] = len(rows)
            summary[scenario][variant]['cpu_range'] = [min(row['cpu_seconds'] for row in rows), max(row['cpu_seconds'] for row in rows)]
    write_json(h.out / 'summary.json', summary)
    print(h.out)


if __name__ == '__main__':
    main()
