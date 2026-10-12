"""Reuse measured idle baseline fixtures for full baseline mass delivery runs."""
import json
from pathlib import Path
from next_sync_benchmark import Harness,parser,write_json
args=parser().parse_args();h=Harness(args,label='baseline-mass')
previous=Path(__file__).parent/'results/next-sync/20261012-152650-benchmark-42f3e1f3'
trials=[]
for scenario,shape in [('mass_shared','steady_shared'),('mass_distinct','steady_unique')]:
 fixture=json.loads((previous/f'warm-old-{shape}.json').read_text())['fixture']
 row=h.trial('old',scenario,1,previous/f'warm-old-{shape}.sql',fixture)
 trials.append(row);write_json(h.out/'raw.json',trials)
 print(f'{scenario} old: CPU={row["cpu_seconds"]:.3f}s RSS={row["peak_rss_kib"]/1024:.2f}MiB SQL={row["sql_queries"]} HTTP={row["http_requests"]}',flush=True)
print(h.out)
