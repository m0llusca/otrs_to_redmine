"""Final installed package measurements; reuse immutable unchanged baseline trials."""
import json,statistics
from pathlib import Path
from next_sync_benchmark import Harness,parser,write_json,SCENARIOS
args=parser().parse_args();h=Harness(args,label='final-package')
root=Path(__file__).parent/'results/next-sync'
idle=root/'20261012-152650-benchmark-42f3e1f3/raw.json'
mass=root/'20261012-154013-baseline-mass-959e1c8d/raw.json'
old=[row for p in (idle,mass) for row in json.loads(p.read_text()) if row['variant']=='old']
rows=[];seeds={}
for scenario in SCENARIOS:
 shape='steady_unique' if scenario in ('steady_unique','mass_distinct') else 'steady_shared'
 if shape not in seeds: seeds[shape]=h.warm_seed('new',shape)
 for repeat in range(1,(args.mass_repeats if scenario.startswith('mass_') else args.idle_repeats)+1):
  row=h.trial('new',scenario,repeat,*seeds[shape]);rows.append(row);write_json(h.out/'raw.json',rows)
  print(f'{scenario} new #{repeat}: CPU={row["cpu_seconds"]:.3f}s RSS={row["peak_rss_kib"]/1024:.2f}MiB SQL={row["sql_queries"]} HTTP={row["http_requests"]} workers={row["worker_count"]}',flush=True)
fields=('cpu_seconds','wall_seconds','peak_rss_kib','sql_queries','http_requests','connections','response_bytes','worker_count')
summary={}
for scenario in SCENARIOS:
 summary[scenario]={}
 for variant,collection in [('old',old),('new',rows)]:
  selected=[r for r in collection if r['scenario']==scenario]
  summary[scenario][variant]={f:statistics.median(r[f] for r in selected) for f in fields}
  summary[scenario][variant].update(repeats=len(selected),cpu_range=[min(r['cpu_seconds'] for r in selected),max(r['cpu_seconds'] for r in selected)])
write_json(h.out/'summary.json',summary)
write_json(h.out/'baseline-evidence.json',{'idle':str(idle),'mass':str(mass),'baseline_reused_unchanged':True})
print(h.out)
