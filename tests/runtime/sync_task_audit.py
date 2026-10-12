"""Additional focused measurements with daemon cache mode and event flushing."""
import json
from pathlib import Path
import run as m
from sync_audit import peer,stats
OUT=m.RESULTS/'sync-audit'
rows=[]
for scenario,config,variants in [
('shared_50',{},['current','skip_check_timestamp']),
('unique_50',{},['current','scoped_http']),
('mass_transition_50',{'changed':True,'status':'Проверка решения','journals':1,'statusDetail':True},['current']),
]:
    for variant in variants:
        m.restore()
        m.command(['docker','exec','-u','otrs',m.OTRS,'perl','/bench/sync_audit.pl','prepare',scenario,variant])
        peer(config)
        output=m.command(['docker','exec','-u','otrs',m.OTRS,'perl','/bench/sync_audit.pl','run',scenario,variant,'daemon_task'])
        row=json.loads(output.strip().splitlines()[-1]);row['peer']=stats()
        assert row['run_mode']=='daemon_task'
        assert row['articles_after']==(50 if scenario=='mass_transition_50' else 0)
        assert row['peer']['open_connections']==0
        rows.append(row)
        (OUT/'daemon-task-raw.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n')
        print(scenario,variant,'daemon-style task incl events: SQL',row['sql_queries'],'history',row['count']['history_add'],'TCP',row['peer']['connections'],flush=True)
