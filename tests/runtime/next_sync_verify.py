"""Focused real-core correctness checks, separate from performance measurement.

Uses the same explicit local mutation gate/seed/hash arguments as the benchmark.
No generated done rows: every warm generation is actually delivered through OTRS.
Test-only force-ready/probe controls advance expired fixture timestamps instead of
waiting minutes. Injection only affects one worker process; installed code stays
unchanged. Raw failure, replay, generation and concurrency evidence is persisted.
"""
from concurrent.futures import ThreadPoolExecutor
import time
from next_sync_benchmark import Harness, parser, write_json, BINARY_SHA


def main():
    args = parser().parse_args()
    h = Harness(args, label='verify')
    results = {}

    def setup(count=1, warm=False):
        h.restore()
        fixture = h.perl('new', 'prepare', 'steady_shared', count=count)
        h.peer({'issueIDs': fixture['issue_ids'], 'phase': 'steady'})
        if warm:
            poll(fixture)
            h.drain('verify', fixture)
        return fixture

    def poll(fixture):
        row = h.perl('new', 'worker', 'verify', mode='poll', count=fixture['prepared'])
        assert row['result'].get('Success'), row['result']
        return row

    def deliver_one(fixture, **options):
        work = h.inspect('new', 'verify', fixture)['work']
        return h.perl('new', 'worker', 'verify', mode='deliver', count=fixture['prepared'],
            source_key=work['source_key'], seed_issue_key=work['first_issue_key'], **options)

    def check(fixture):
        return h.inspect('new', 'verify', fixture, content=True)

    def save(name, data):
        results[name] = data
        write_json(h.out / 'verification.json', results)
        print(name + ': PASS', flush=True)

    # Replay a 100-note/file fanout, then replay with no duplicate database notes.
    f = setup(100, warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed', 'attachments': True})
    poll(f); workers = h.drain('verify', f)
    first = check(f)
    assert first['new_notes'] == first['tickets_with_notes'] == first['attachments'] == 100
    assert first['max_notes_per_ticket'] == 1
    assert all(value == BINARY_SHA for value in first['attachment_hashes'])
    poll(f); replay_workers = h.drain('verify', f)
    replay = check(f)
    assert replay['new_notes'] == 100 and not replay['work']['pending']
    save('fanout_100_and_replay', {'workers': workers, 'first': first, 'replay_workers': replay_workers, 'replay': replay, 'peer': h.stats()})

    # A return to New between polls is still represented by journal 11 -> 12.
    f = setup(warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'rapid'})
    poll(f); h.drain('verify', f); rapid = check(f)
    assert rapid['new_notes'] == 1
    assert rapid['checkpoints']['RedmineLastJournalID'] == [['12', 1]]
    assert rapid['checkpoints']['RedmineStatus'] == [['New', 1]]
    assert rapid['states'] == [['closed successful', 1]]
    assert 'Controlled status transition' in rapid['sample_bodies'][0]
    save('short_transition_and_return', rapid)

    # File failure remains pending; recovering the same version delivers once.
    f = setup(warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed', 'attachments': True, 'fileError': True})
    poll(f); failed_worker = deliver_one(f); failed = check(f)
    assert not failed_worker['result'].get('Success')
    assert failed['new_notes'] == 0 and failed['work']['pending'] == 1
    assert failed['checkpoints']['RedmineLastJournalID'] == [['10', 1]]
    h.peer({'merge': True, 'fileError': False, 'resetStats': False})
    h.perl('new', 'force-ready', 'verify', count=1)
    recovery_workers = h.drain('verify', f); recovered = check(f)
    assert recovered['new_notes'] == recovered['attachments'] == 1
    poll(f); h.drain('verify', f); assert check(f)['new_notes'] == 1
    save('attachment_404_recovery', {'failure': failed, 'failed_worker': failed_worker, 'recovery_workers': recovery_workers, 'recovered': recovered, 'peer': h.stats()})

    # One failed ticket must not block healthy siblings in later batches.
    f = setup(60, warm=True)
    h.perl('new', 'seed-sibling-file-cursors', 'verify', count=60)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed', 'attachments': True, 'fileError': True})
    poll(f); gap_first = deliver_one(f)
    assert not gap_first['result'].get('Success') and gap_first['result'].get('Succeeded') == 49
    h.drain('verify', f, allow_failure=True)
    gap_failed = check(f)
    assert gap_failed['new_notes'] == gap_failed['tickets_with_notes'] == 59
    assert gap_failed['states'] == [['open', 60]]
    assert gap_failed['work']['pending'] == 1
    assert gap_failed['work']['generations'][0]['first_failed_ticket_id'] == int(f['ticket_ids'][0])
    h.peer({'merge': True, 'fileError': False, 'resetStats': False})
    gap_recovery_workers = []
    for _ in range(6):
        h.perl('new', 'force-ready', 'verify', count=60)
        gap_recovery_workers += h.drain('verify', f, allow_failure=True)
        gap_recovered = check(f)
        if not gap_recovered['work']['pending']:
            break
    else:
        raise AssertionError('recovered gap failed to complete its retained scan/retry rounds')
    assert gap_recovered['new_notes'] == gap_recovered['tickets_with_notes'] == 60
    assert gap_recovered['max_notes_per_ticket'] == 1 and gap_recovered['attachments'] == 1
    assert not gap_recovered['work']['pending']
    save('failed_ticket_gap_preserves_healthy_siblings', {'first_batch': gap_first,
        'failed': gap_failed, 'recovery_workers': gap_recovery_workers, 'recovered': gap_recovered, 'peer': h.stats()})

    # The HTTP cooldown shared between fresh workers issues no second request.
    f = setup(warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed', 'quota': {'code': 429, 'count': 1, 'retryAfter': 60}})
    limited = h.perl('new', 'worker', 'verify', mode='manual', count=1)
    before = h.stats()
    blocked = h.perl('new', 'worker', 'verify', mode='manual', count=1)
    after = h.stats()
    assert not limited['result'].get('Success') and not blocked['result'].get('Success')
    assert before['counts'] == after['counts'], 'cooldown made an extra network request'
    h.peer({'merge': True, 'quota': None, 'resetStats': False})
    h.perl('new', 'force-ready', 'verify', count=1)
    poll(f); h.drain('verify', f); quota_recovery = check(f)
    assert quota_recovery['new_notes'] == 1
    save('429_shared_cooldown_and_recovery', {'limited': limited, 'blocked': blocked, 'before': before, 'after': after, 'recovery': quota_recovery})

    # Failure after ArticleCreate/attachment/first DF write rolls them all back.
    f = setup(warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed', 'attachments': True})
    poll(f)
    injected = deliver_one(f, fault_field='RedmineLastJournalID')
    rolled_back = check(f)
    assert not injected['result'].get('Success')
    assert rolled_back['new_notes'] == rolled_back['attachments'] == 0
    assert rolled_back['checkpoints']['RedmineStatus'] == [['New', 1]]
    assert rolled_back['checkpoints']['RedmineLastJournalID'] == [['10', 1]]
    assert rolled_back['work']['generations'][0]['after_ticket_id'] == int(f['ticket_ids'][0]) - 1
    h.perl('new', 'force-ready', 'verify', count=1)
    h.drain('verify', f); committed = check(f)
    assert committed['new_notes'] == committed['attachments'] == 1
    save('actual_core_article_df_atomic_rollback', {'injected_worker': injected, 'rolled_back': rolled_back, 'retry': committed})

    # A worker exits after Claim. Lease expiration lets the next process resume.
    f = setup(warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed'})
    poll(f)
    abandoned = h.perl('new', 'claim-expired', 'verify', count=1)
    time.sleep(1.2)
    h.drain('verify', f); resumed = check(f)
    assert resumed['new_notes'] == 1 and not resumed['work']['pending']
    save('expired_lease_restart', {'abandoned': abandoned, 'resumed': resumed})

    # The tuple is unchanged, but an intentionally due probe sees a new journal.
    f = setup(warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed'})
    poll(f); h.drain('verify', f)
    h.peer({'merge': True, 'phase': 'later', 'updatedOn': '2026-01-02T00:00:00Z', 'resetStats': False})
    h.perl('new', 'force-probe', 'verify', count=1)
    poll(f); h.drain('verify', f); overwritten = check(f)
    assert overwritten['checkpoints']['RedmineLastJournalID'] == [['12', 1]]
    assert overwritten['new_notes'] == 2
    save('same_timestamp_overwrite_probe', overwritten)

    # New generation arrives after the first bounded 50-ticket worker.
    f = setup(100, warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed'})
    poll(f); first_batch = deliver_one(f); first_check = check(f)
    first_processed = first_batch['result'].get('Processed', 0)
    assert first_batch['result'].get('Success') and 1 <= first_processed <= 50
    assert first_check['new_notes'] == first_processed
    h.peer({'merge': True, 'phase': 'later', 'updatedOn': '2026-01-03T00:00:00Z', 'resetStats': False})
    poll(f); late_workers = h.drain('verify', f); late = check(f)
    assert late['new_notes'] == 100 + first_processed and late['tickets_with_notes'] == 100
    assert late['checkpoints']['RedmineLastJournalID'] == [['12', 100]]
    assert not late['work']['pending']
    save('late_generation_N_plus_1', {'first_batch': first_batch, 'first_validation': first_check, 'workers': late_workers, 'final': late})

    # Two independent Perl processes overlap on the same seed issue.
    f = setup(100, warm=True)
    h.peer({'issueIDs': f['issue_ids'], 'phase': 'changed', 'delayMillis': 100})
    poll(f)
    work = h.inspect('new', 'verify', f)['work']
    def concurrent_worker(_):
        return h.perl('new', 'worker', 'verify', mode='deliver', count=100,
            source_key=work['source_key'], seed_issue_key=work['first_issue_key'])
    with ThreadPoolExecutor(max_workers=2) as pool:
        overlap = list(pool.map(concurrent_worker, range(2)))
    h.drain('verify', f); concurrent = check(f)
    assert concurrent['new_notes'] == concurrent['tickets_with_notes'] == 100
    assert concurrent['max_notes_per_ticket'] == 1 and not concurrent['work']['pending']
    save('cross_process_delivery_concurrency', {'overlap': overlap, 'final': concurrent})
    print(h.out)


if __name__ == '__main__':
    main()
