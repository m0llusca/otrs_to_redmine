"""Compare the legacy, memory-optimized and CPU-optimized sources on real OTRS.

Requires run.py --initialize-only and an immutable .state/pre_cpu snapshot.
Only the dedicated local runtime stack and synthetic fixture are touched.
"""
import hashlib
import argparse
import json
import random
import statistics
import run as runtime

def main():
    m=runtime
    parser=argparse.ArgumentParser()
    parser.add_argument('--tls',action='store_true')
    parser.add_argument('--repeats',type=int,default=15)
    args=parser.parse_args()
    assert args.repeats>=3
    output=m.RESULTS/'cpu-investigation'
    prefix='comparison-https' if args.tls else 'comparison'
    expected=json.loads((output/'pre-cpu-source.json').read_text())
    for name,digest in expected.items():
        assert hashlib.sha256((m.STATE/'pre_cpu'/name).read_bytes()).hexdigest()==digest
    variants=['before','pre_cpu','after']
    # Excluded warmups precede the balanced, rotating measurement order.
    for variant in variants:
        m.run_trial(variant,'outbound',tls=args.tls)
    rows=[]
    for repeat in range(args.repeats):
        offset=repeat%3
        order=variants[offset:]+variants[:offset]
        for variant in order:
            row=m.run_trial(variant,'outbound',tls=args.tls)
            peer=m.peer_stats()
            row['connections']=peer['data_connections']
            row['open_connections_after']=peer['open_data_connections']
            row['repeat']=repeat+1
            rows.append(row)
            (output/(prefix+'-raw.json')).write_text(json.dumps(rows,indent=2)+'\n')
            print(f'{variant} #{repeat+1}: CPU={row["cpu_seconds"]:.4f}s RSS={row["peak_rss_kib"]/1024:.2f}MiB TCP={row["connections"]}',flush=True)
    summary={}
    for variant in variants:
        selected=[r for r in rows if r['variant']==variant]
        summary[variant]={k:statistics.median(r[k] for r in selected)
            for k in ['cpu_seconds','wall_seconds','peak_rss_kib','sql_queries','http_requests','connections']}
        summary[variant]['cpu_range']=[min(r['cpu_seconds'] for r in selected),max(r['cpu_seconds'] for r in selected)]
        assert all(r['open_connections_after']==0 for r in selected), 'An operation retained a socket'
    # Paired bootstrap interval for median CPU reduction, to display noise.
    pairs=[]
    for repeat in range(1,args.repeats+1):
        p=next(r for r in rows if r['repeat']==repeat and r['variant']=='pre_cpu')
        a=next(r for r in rows if r['repeat']==repeat and r['variant']=='after')
        pairs.append(1-a['cpu_seconds']/p['cpu_seconds'])
    rng=random.Random(712)
    estimates=sorted(statistics.median(rng.choices(pairs,k=len(pairs))) for _ in range(10000))
    report={'repeats_per_variant':args.repeats,'protocol':'https' if args.tls else 'http','summary':summary,
        'paired_median_cpu_reduction':statistics.median(pairs),
        'paired_bootstrap_95_interval':[estimates[250],estimates[9749]],
        'scope':'OTRS 6.0.10, Perl5.16.3, amd64 emulated on arm64; one-worker CPU/RSS; controlled local HTTP peer'}
    (output/(prefix+'-summary.json')).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2),flush=True)

if __name__=='__main__':
    main()
