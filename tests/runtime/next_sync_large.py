"""Large-file resource/correctness comparison on actual local OTRS core.

Run after the exclusive 1000-ticket benchmark, while next_sync_peer.mjs is still
running (before the legacy-peer switch). Never changes installed source/services.
Each variant starts with the same explicit post-schema seed and ten shared links.
New source gets a real ten-ticket steady warmup outside the measured window.
Private warm SQL snapshots stay under .state, never in public result artifacts.

  python3 tests/runtime/next_sync_large.py --allow-local-mutations \
    --seed tests/runtime/.state/next-sync-seed.sql --new-sync-sha256 SHA256

Default: two repeats, 10 notes and 10 identical 4 MiB attachments per trial.
The output directory must not exist; previous reports are never overwritten.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import statistics
import uuid
from next_sync_benchmark import Harness, HERE, RESULTS, write_json

SCENARIO = 'large_shared'
COUNT = 10
FILE_BYTES = 4 * 1024 * 1024
FILE_SHA = hashlib.sha256(b'R' * FILE_BYTES).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-local-mutations', action='store_true')
    parser.add_argument('--seed', required=True)
    parser.add_argument('--new-sync-sha256', required=True)
    parser.add_argument('--new-version', default='1.0.31')
    parser.add_argument('--repeats', type=int, choices=range(1, 11), default=2)
    parser.add_argument('--output-dir', type=Path, default=RESULTS / 'large-file-memory')
    args = parser.parse_args()
    destination = args.output_dir.resolve()
    if destination.exists():
        raise FileExistsError(f'Preserving existing evidence: {destination}; use another --output-dir')
    h = Harness(args, label='large')
    destination.parent.mkdir(parents=True, exist_ok=True)
    h.out.rename(destination)
    h.out = destination
    private = HERE / '.state' / ('next-sync-large-' + uuid.uuid4().hex[:12])
    private.mkdir(mode=0o700, exist_ok=False)
    write_json(h.out / 'case.json', {'scenario': SCENARIO, 'tickets': COUNT,
        'file_bytes': FILE_BYTES, 'file_sha256': FILE_SHA, 'repeats': args.repeats,
        'private_seed_directory': str(private),
        'metrics': 'worker CPU/SQL/wall sums; peak RSS maximum before validation; bootstrap excluded; events included',
        'old_work': 'one CronSync, up to 50 tickets, actual fixture has ten links',
        'new_work': 'one PollSync then bounded ProcessSyncBatch workers; real steady warmup excluded'})

    seeds = {}
    for variant in ('old', 'new'):
        h.restore()
        fixture = h.perl(variant, 'prepare', SCENARIO, count=COUNT)
        h.peer({'issueIDs': fixture['issue_ids'], 'phase': 'steady'})
        warmup = []
        if variant == 'new':
            warmup.append(h.perl('new', 'worker', SCENARIO, mode='poll', count=COUNT))
            assert warmup[0]['result'].get('Success'), warmup[0]['result']
            warmup += h.drain(SCENARIO, fixture)
        check = h.inspect(variant, SCENARIO, fixture, content=True)
        assert check['new_notes'] == check['attachments'] == 0, 'warmup fabricated a note/file'
        if variant == 'new':
            assert check['work']['total'] == 1 and check['work']['pending'] == 0
        seed = private / f'{variant}.sql'
        h.dump(seed)
        seeds[variant] = (seed, fixture)
        write_json(h.out / f'warmup-{variant}.json', {'fixture': fixture, 'workers': warmup,
            'validation': check, 'seed_sha256': hashlib.sha256(seed.read_bytes()).hexdigest()})

    trials = []
    for repeat in range(1, args.repeats + 1):
        for variant in (('old', 'new') if repeat % 2 else ('new', 'old')):
            seed, fixture = seeds[variant]
            h.restore(seed)
            h.peer({'issueIDs': fixture['issue_ids'], 'phase': 'changed',
                'attachments': True, 'largeBytes': FILE_BYTES})
            if variant == 'old':
                workers = [h.perl('old', 'worker', SCENARIO, mode='cron', count=COUNT)]
            else:
                workers = [h.perl('new', 'worker', SCENARIO, mode='poll', count=COUNT)]
                assert workers[0]['result'].get('Success'), workers[0]['result']
                workers += h.drain(SCENARIO, fixture)
            assert all(worker['result'].get('Success') for worker in workers), workers
            check = h.inspect(variant, SCENARIO, fixture, content=True)
            assert check['new_notes'] == check['tickets_with_notes'] == check['attachments'] == COUNT
            assert check['max_notes_per_ticket'] == 1, 'duplicate note'
            assert check['attachment_hashes'] == [FILE_SHA] * COUNT, 'large-file SHA mismatch'
            assert check['checkpoints']['RedmineLastJournalID'] == [['11', COUNT]]
            assert check['checkpoints']['RedmineLastAttachmentID'] == [['1', COUNT]]
            assert check['checkpoints']['RedmineStatus'] == [['Проверка решения', COUNT]]
            assert check['states'] == [['open', COUNT]]
            if variant == 'new':
                assert check['work']['pending'] == 0
            peer = h.stats()
            assert peer['open_connections'] == 0
            row = {'variant': variant, 'scenario': SCENARIO, 'repeat': repeat,
                'workers': workers, 'worker_count': len(workers), 'validation': check, 'peer': peer}
            for field in ('cpu_seconds', 'cpu_user_seconds', 'cpu_system_seconds', 'wall_seconds',
                'sql_queries', 'host_process_wall_seconds'):
                row[field] = sum(worker[field] for worker in workers)
            row['peak_rss_kib'] = max(worker['peak_rss_kib'] for worker in workers)
            row['http_requests'] = sum(peer['counts'].values())
            row['response_bytes'] = peer['response_bytes']
            row['connections'] = peer['connections']
            if variant == 'new':
                # Replay is correctness-only and excluded from the row's metrics.
                replay_poll = h.perl('new', 'worker', SCENARIO, mode='poll', count=COUNT)
                assert replay_poll['result'].get('Success')
                replay_workers = h.drain(SCENARIO, fixture)
                replay = h.inspect('new', SCENARIO, fixture, content=True)
                assert replay['new_notes'] == replay['attachments'] == COUNT
                assert replay['max_notes_per_ticket'] == 1 and replay['work']['pending'] == 0
                row['replay'] = {'poll': replay_poll, 'workers': replay_workers, 'validation': replay}
            trials.append(row)
            write_json(h.out / f'large-file-{variant}-{repeat}.json', row)
            write_json(h.out / 'large-file-raw.json', trials)
            print(f'{variant} #{repeat}: CPU={row["cpu_seconds"]:.3f}s RSS={row["peak_rss_kib"]/1024:.2f}MiB SQL={row["sql_queries"]} workers={row["worker_count"]}', flush=True)
    fields = ('cpu_seconds', 'wall_seconds', 'peak_rss_kib', 'sql_queries',
        'http_requests', 'response_bytes', 'connections', 'worker_count')
    summary = {}
    for variant in ('old', 'new'):
        rows = [row for row in trials if row['variant'] == variant]
        summary[variant] = {field: statistics.median(row[field] for row in rows) for field in fields}
        summary[variant]['repeats'] = len(rows)
        summary[variant]['cpu_range'] = [min(row['cpu_seconds'] for row in rows), max(row['cpu_seconds'] for row in rows)]
        summary[variant]['peak_rss_range_kib'] = [min(row['peak_rss_kib'] for row in rows), max(row['peak_rss_kib'] for row in rows)]
    write_json(h.out / 'large-file-summary.json', summary)
    print(h.out)


if __name__ == '__main__':
    main()
