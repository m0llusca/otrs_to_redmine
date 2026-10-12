"""Isolated real-OTRS comparison; all mutation targets belong to this test stack.

No production credentials, databases, networks or SSH access are used.
The Redmine fixture is a controlled HTTP peer; OTRS services are unmodified.
"""
import json
import argparse
import os
from pathlib import Path
import secrets
import statistics
import subprocess
import time
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
STATE = HERE / '.state'
RESULTS = HERE / 'results'
COMPOSE = ['docker', 'compose', '-f', str(HERE / 'compose.yaml')]
OTRS = 'bridge-perf-local-otrs-1'
DB = 'bridge-perf-local-mariadb-1'
PEER = 'bridge-perf-local-redmine-1'

def command(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'Local command failed ({result.returncode}): {redact(result.stderr)}')
    return result.stdout

def redact(text):
    if (HERE / '.env').exists():
        for line in (HERE / '.env').read_text().splitlines():
            value = line.partition('=')[2]
            if len(value) > 12:
                text = text.replace(value, '[redacted]')
    return text

def perl(variant, action, scenario=None, tls=False, upload_fs=False):
    args = ['docker', 'exec', '-u', 'otrs']
    if tls:
        args += ['-e','BRIDGE_PEER_TLS=1','-e','PERL_LWP_SSL_CA_FILE=/bench/.state/tls/cert.pem']
    if upload_fs:
        args += ['-e','BRIDGE_UPLOAD_FS=1']
    args += [OTRS, 'perl', '/bench/runner.pl', variant, action]
    if scenario:
        args.append(scenario)
    output = command(args)
    result = json.loads(output.strip().splitlines()[-1])
    if variant == 'installed' and action == 'run':
        assert result['loaded_sync'].startswith('/opt/otrs/'), 'Source overlay shadowed installed package'
    return result

def peer_control(scenario):
    script = 'fetch("http://localhost:8080/__control",{method:"POST",body:JSON.stringify({scenario:process.argv[1]})}).then(r=>r.json()).then(x=>console.log(JSON.stringify(x)))'
    command(['docker', 'exec', PEER, 'node', '-e', script, scenario])

def peer_stats():
    script = 'fetch("http://localhost:8080/__stats").then(r=>r.json()).then(x=>console.log(JSON.stringify(x)))'
    return json.loads(command(['docker', 'exec', PEER, 'node', '-e', script]))

def restore():
    with (STATE / 'seed.sql').open('rb') as stream:
        p = subprocess.run(['docker', 'exec', '-i', DB, 'sh', '-c',
            'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$OTRS_DB_NAME"'],
            stdin=stream, capture_output=True)
    if p.returncode:
        raise RuntimeError(redact(p.stderr.decode()))

def run_trial(variant, scenario, tls=False):
    restore()
    perl(variant, 'prepare', scenario)
    peer_control(scenario)
    result = perl(variant, 'run', scenario, tls=tls)
    result['protocol'] = 'https' if tls else 'http'
    peer = peer_stats()
    result['http_counts'] = peer['counts']
    result['http_requests'] = sum(peer['counts'].values())
    result['issue_gets'] = sum(v for k, v in peer['counts'].items() if k.startswith('GET /issues/'))
    result['file_downloads'] = sum(v for k, v in peer['counts'].items() if k.startswith('GET /attachments/download/'))
    result['cpu_seconds'] = result['cpu_user_seconds'] + result['cpu_system_seconds']
    assert (result['loaded_sync'].startswith('/opt/otrs/') if variant == 'installed'
        else f'/.state/{variant}/' in result['loaded_sync']), 'Wrong source variant loaded'
    assert result['variable_check'].replace('//','/').startswith(('/opt/otrs/','/Kernel/')), 'OTRS dependency was replaced by a double'
    if scenario == 'outbound':
        assert peer['uploaded_bytes'] == [1024*1024]*16, 'Outbound attachment bytes missing'
        assert peer['created']['description'] == 'Fixed description'
    if scenario == 'unchanged':
        assert result['checks']['processed_tickets'] == 50
    return result

def main():
    STATE.mkdir(exist_ok=True)
    RESULTS.mkdir(exist_ok=True)
    if not (HERE / '.env').exists():
        values = dict(OTRS_INSTALL='no', OTRS_DB_HOST='mariadb', OTRS_DB_NAME='bridge_benchmark',
            OTRS_DB_USER='otrs', OTRS_DB_PASSWORD=secrets.token_hex(20), MYSQL_ROOT_PASSWORD=secrets.token_hex(20),
            MARIADB_ROOT_HOST='%', OTRS_ROOT_PASSWORD=secrets.token_hex(20), OTRS_HOSTNAME='otrs-benchmark.invalid',
            OTRS_LANGUAGE='en', OTRS_TIMEZONE='UTC', OTRS_ALLOW_NOT_VERIFIED_PACKAGES='yes')
        (HERE / '.env').write_text('\n'.join(k+'='+v for k,v in values.items())+'\n')
        (HERE / '.env').chmod(0o600)
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', help='Git commit for the before version; defaults to the saved report baseline or HEAD')
    parser.add_argument('--initialize-only', action='store_true')
    args = parser.parse_args()
    saved = RESULTS/'summary.json'
    requested = args.baseline or (json.loads(saved.read_text())['baseline_commit'] if saved.exists() else 'HEAD')
    baseline = command(['git', '-C', str(ROOT), 'rev-parse', requested]).strip()
    files = [f.attrib['Location'] for f in ET.parse(ROOT/'OTRSRedmineBridge.sopm').findall('.//File')]
    for variant in ['before', 'after']:
        for name in files:
            p = STATE/variant/name
            p.parent.mkdir(parents=True, exist_ok=True)
            if variant == 'before':
                content = subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{baseline}:{name}'])
            else:
                content = (ROOT/name).read_bytes()
            p.write_bytes(content)
    command(COMPOSE+['up','-d'])
    for _ in range(120):
        ready = subprocess.run(['docker','exec',OTRS,'test','-f','/tmp/bridge-runtime-ready'],capture_output=True)
        if ready.returncode == 0:
            break
        time.sleep(1)
    else:
        raise RuntimeError('Local OTRS initialization did not finish')
    exists = subprocess.run(['docker','exec',OTRS,'test','-f','/opt/otrs/var/tmp/bridge-benchmark.json'],capture_output=True)
    if exists.returncode:
        print(perl('after','setup'), flush=True)
    with (STATE/'seed.sql').open('wb') as output:
        p = subprocess.run(['docker','exec',DB,'sh','-c',
            'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --skip-comments "$OTRS_DB_NAME"'],
            stdout=output,stderr=subprocess.PIPE)
    if p.returncode:
        raise RuntimeError(redact(p.stderr.decode()))
    if args.initialize_only:
        print('Isolated OTRS stack initialized; fixed fixture snapshot saved.', flush=True)
        return
    trials = []
    warmups = []
    for scenario in ['unchanged','inbound','outbound']:
        for variant in ['before','after']:
            warmups.append(run_trial(variant,scenario))
        for repeat in range(5):
            order = ['before','after'] if repeat%2 == 0 else ['after','before']
            for variant in order:
                result = run_trial(variant,scenario)
                result['repeat'] = repeat+1
                trials.append(result)
                (RESULTS/'raw.json').write_text(json.dumps(trials,ensure_ascii=False,indent=2)+'\n')
                print(f'{scenario} {variant} #{repeat+1}: CPU={result["cpu_seconds"]:.3f}s RSS={result["peak_rss_kib"]/1024:.2f}MiB wall={result["wall_seconds"]:.3f}s',flush=True)
    summary = {}
    fields = ['cpu_seconds','wall_seconds','peak_rss_kib','sql_queries','http_requests','issue_gets','file_downloads']
    for scenario in ['unchanged','inbound','outbound']:
        summary[scenario] = {}
        for variant in ['before','after']:
            rows = [r for r in trials if r['scenario']==scenario and r['variant']==variant]
            summary[scenario][variant] = {field:statistics.median(r[field] for r in rows) for field in fields}
            summary[scenario][variant]['cpu_range'] = [min(r['cpu_seconds'] for r in rows),max(r['cpu_seconds'] for r in rows)]
            summary[scenario][variant]['rss_range_kib'] = [min(r['peak_rss_kib'] for r in rows),max(r['peak_rss_kib'] for r in rows)]
    output = dict(baseline_commit=baseline,otrs='6.0.10 CE',perl='5.16.3',database='MariaDB 10.11',
        host='Apple Silicon arm64; OTRS image amd64 under emulation',
        process_metrics='BSD::Resource getrusage RUSAGE_SELF; Linux peak RSS in KiB; CPU delta around bridge operation, excluding bootstrap and validation',
        memory_scope='OTRS Perl worker peak RSS includes bootstrap; database and HTTP peer excluded',
        repeats=5,warmups_excluded=len(warmups),network='internal Docker bridge; no published ports; no production access',
        summary=summary)
    (RESULTS/'summary.json').write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n')
    (RESULTS/'warmups.json').write_text(json.dumps(warmups,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(summary,ensure_ascii=False,indent=2),flush=True)

if __name__=='__main__':
    main()
