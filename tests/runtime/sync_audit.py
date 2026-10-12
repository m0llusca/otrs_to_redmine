"""New sync investigation only: original 1.0.30 and process-local prototypes.

Requires run.py --initialize-only, sync_audit.pl grow, fixed 1000-ticket seed,
then the isolated redmine service running sync_audit_peer.mjs. No package edits.
"""
import json
import statistics
import sys
from pathlib import Path
import run as m
OUT=m.RESULTS/'sync-audit'
OUT.mkdir(exist_ok=True)

def audit(action,scenario,variant):
    text=m.command(['docker','exec','-u','otrs',m.OTRS,'perl','/bench/sync_audit.pl',action,scenario,variant])
    return json.loads(text.strip().splitlines()[-1])

def peer(config):
    script='fetch("http://localhost:8080/__control",{method:"POST",body:process.argv[1]}).then(r=>r.json()).then(x=>console.log(JSON.stringify(x)))'
    m.command(['docker','exec',m.PEER,'node','-e',script,json.dumps(config)])

def stats():
    script='fetch("http://localhost:8080/__stats").then(r=>r.json()).then(x=>console.log(JSON.stringify(x)))'
    return json.loads(m.command(['docker','exec',m.PEER,'node','-e',script]))

cases=[
('shared_50',{},['current','skip_check_timestamp'],3),
('unique_50',{},['current','scoped_http'],3),
('ordinary_10',{'changed':True,'journals':1000,'noteWords':100},['current','skip_unused_journals','drop_json_copy'],3),
('failure_10',{'changed':True,'status':'Проверка решения','journals':1,'statusDetail':True,'fileError':True,'metadataBytes':4},['current','memoize_failed_download'],2),
('empty',{},['current'],1),
('shared_1000',{},['current','skip_check_timestamp'],1),
('unique_1000',{},['current','scoped_http'],1),
('mass_transition_1000',{'changed':True,'status':'Проверка решения','journals':1,'statusDetail':True},['current','scoped_http'],1),
]
def main():
    rows=[]
    for scenario,config,variants,repeats in cases:
        for repeat in range(repeats):
            offset=repeat%len(variants)
            for variant in variants[offset:]+variants[:offset]:
                m.restore();audit('prepare',scenario,variant);peer(config)
                row=audit('run',scenario,variant);row['repeat']=repeat+1;row['peer']=stats()
                assert row['loaded_sync']=='/opt/otrs/Kernel/System/Redmine/Sync.pm'
                assert row['peer']['open_connections']==0
                expected_notes=1000 if scenario=='mass_transition_1000' else 0
                assert row['articles_after']==expected_notes,(scenario,variant,row['articles_after'])
                assert row['health']['LastSyncOK']==(0 if scenario=='failure_10' else 1)
                rows.append(row)
                (OUT/'raw.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
                print(f'{scenario} {variant} #{repeat+1}: CPU={row["cpu_seconds"]:.3f}s SQL={row["sql_queries"]} history={row["count"]["history_add"]} HTTP={sum(row["peer"]["counts"].values())} TCP={row["peer"]["connections"]}',flush=True)
    summary={}
    for scenario,config,variants,repeats in cases:
        summary[scenario]={}
        for variant in variants:
            selected=[r for r in rows if r['scenario']==scenario and r['variant']==variant]
            summary[scenario][variant]={k:statistics.median(r[k] for r in selected) for k in ['cpu_seconds','wall_seconds','peak_rss_kib','sql_queries','articles_after']}
            result=summary[scenario][variant]
            result['repeats']=len(selected)
            for key in ['history_add','ticket_get','html_to_ascii']:
                result[key]=statistics.median(r['count'][key] for r in selected)
            for key in ['connections','response_bytes']:
                result[key]=statistics.median(r['peer'][key] for r in selected)
            result['http_requests']=statistics.median(sum(r['peer']['counts'].values()) for r in selected)
            result['last_check_field_writes']=statistics.median(r['count']['field_sets'].get('RedmineLastSyncAt',0) for r in selected)
    (OUT/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    print('Sync audit complete:',len(rows),'new runs',flush=True)

if __name__ == "__main__":
    main()
