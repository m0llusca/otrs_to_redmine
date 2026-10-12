"""Build/install/upgrade and verify only the dedicated local OTRS package stack.

Run after run.py --initialize-only and staging package-before/package-after
from the baseline/current SOPM file lists. Never uses host/server credentials.
"""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import xml.etree.ElementTree as ET
import run as m


def console(*args):
    output = m.command(['docker', 'exec', '-u', 'otrs', m.OTRS,
                        '/opt/otrs/bin/otrs.Console.pl', *args])
    assert 'Done.' in output
    return output


def package_check(action):
    output = m.command(['docker', 'exec', '-u', 'otrs', m.OTRS,
                        'perl', '/bench/package_check.pl', action])
    return json.loads(output.strip().splitlines()[-1])


def main():
    out = m.RESULTS / 'final-review'
    out.mkdir(exist_ok=True)
    dist = m.ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    logs = []
    for variant in ['before', 'after']:
        source = '/bench/.state/package-' + variant
        logs.append(console('Dev::Package::Build', '--module-directory', source,
                            source + '/OTRSRedmineBridge.sopm', '/tmp'))
    m.restore()
    m.command(['docker', 'exec', '-u', 'otrs', m.OTRS, '/opt/otrs/bin/otrs.Console.pl', 'Maint::Cache::Delete'])
    logs.append(console('Admin::Package::Install', '/tmp/OTRSRedmineBridge-1.0.29.opm'))
    package_check('before')
    logs.append(console('Admin::Package::Upgrade', '/tmp/OTRSRedmineBridge-1.0.30.opm'))
    upgrade = package_check('after')
    (out / 'upgrade.json').write_text(json.dumps(upgrade, indent=2) + '\n')
    print('Real Package::Install 1.0.29 -> Package::Upgrade 1.0.30: verified', flush=True)

    artifact = dist / 'OTRSRedmineBridge-1.0.30.opm'
    m.command(['docker', 'cp', m.OTRS + ':/tmp/' + artifact.name, str(artifact)])
    sopm = ET.parse(m.ROOT / 'OTRSRedmineBridge.sopm')
    opm = ET.parse(artifact)
    expected = {f.attrib['Location'] for f in sopm.findall('.//File')}
    files = opm.findall('.//File')
    assert opm.findtext('Version') == '1.0.30'
    assert {f.attrib['Location'] for f in files} == expected and len(files) == 18
    manifest = {}
    for file in files:
        name = file.attrib['Location']
        content = base64.b64decode(file.text)
        assert content == (m.ROOT / name).read_bytes(), name
        assert file.attrib['Permission'] == '644'
        manifest[name] = hashlib.sha256(content).hexdigest()
        installed = m.command(['docker', 'exec', m.OTRS, 'sha256sum', '/opt/otrs/' + name]).split()[0]
        assert installed == manifest[name], name
    assert all(not p.startswith(('tests/', 'scripts/', 'graphify-out/')) for p in expected)
    checksum = hashlib.sha256(artifact.read_bytes()).hexdigest()
    (out / 'package-manifest.json').write_text(json.dumps(dict(version='1.0.30', file_count=len(files),
        package_sha256=checksum, sources=manifest, all_payloads_match_source=True,
        all_installed_files_match_package=True, no_tests_secrets_or_graph_in_package=True), indent=2) + '\n')
    (dist / 'SHA256SUMS').write_text(checksum + '  ' + artifact.name + '\n')

    # Keep the original fixture dump for an independent fresh install below.
    shutil.copyfile(m.STATE / 'seed.sql', m.STATE / 'seed-before-package.sql')
    with (m.STATE / 'seed.sql').open('wb') as stream:
        subprocess.run(['docker', 'exec', m.DB, 'sh', '-c',
            'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --skip-comments "$OTRS_DB_NAME"'],
            stdout=stream, stderr=subprocess.PIPE, check=True)
    m.command(['python3', str(m.HERE / 'verify.py'), '--installed'])
    print('Installed-package functional suite: verified', flush=True)

    m.restore()
    m.perl('installed', 'prepare', 'extra')
    m.perl('installed', 'extra-setup', upload_fs=True)
    control = 'fetch("http://localhost:8080/__control",{method:"POST",body:JSON.stringify({scenario:"extra",verifyUploads:true})}).then(r=>r.json()).then(x=>console.log(JSON.stringify(x)))'
    m.command(['docker', 'exec', m.PEER, 'node', '-e', control])
    fs = m.perl('installed', 'run', 'extra', upload_fs=True)
    peer = m.peer_stats()
    assert peer['uploaded_hashes'] == [hashlib.sha256(b'E' * (512 * 1024)).hexdigest()]
    assert [f['token'] for f in peer['attached']] == ['bench-1']
    m.restore()
    m.perl('installed', 'prepare', 'outbound')
    m.peer_control('outbound')
    links = m.perl('installed', 'verify-links')
    (out / 'additional-functional.json').write_text(json.dumps(dict(fs_upload=fs,
        fs_hashes_and_tokens_verified=True, links=links), indent=2) + '\n')
    print('Real FS UploadCache + link/relink/unlink: verified', flush=True)

    # Small check on final package; earlier 72-run study remains unchanged.
    rows = []
    for repeat in range(5):
        for variant in (['before', 'installed'] if repeat % 2 == 0 else ['installed', 'before']):
            row = m.run_trial(variant, 'outbound')
            peer = m.peer_stats()
            row.update(connections=peer['data_connections'], open_connections_after=peer['open_data_connections'], repeat=repeat+1)
            assert row['connections'] == (22 if variant == 'before' else 1)
            assert row['open_connections_after'] == 0
            rows.append(row)
    (out / 'outbound-raw.json').write_text(json.dumps(rows, indent=2) + '\n')
    summary = {variant: {k: statistics.median(r[k] for r in rows if r['variant'] == variant)
        for k in ['cpu_seconds', 'wall_seconds', 'peak_rss_kib', 'connections']}
        for variant in ['before', 'installed']}
    (out / 'outbound-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Final package 10-run CPU/RSS and connection check: verified', flush=True)

    # Empty package repository again: verify a fresh install of final artifact.
    shutil.copyfile(m.STATE / 'seed-before-package.sql', m.STATE / 'seed.sql')
    m.restore()
    m.command(['docker', 'exec', '-u', 'otrs', m.OTRS, '/opt/otrs/bin/otrs.Console.pl', 'Maint::Cache::Delete'])
    logs.append(console('Admin::Package::Install', '/tmp/OTRSRedmineBridge-1.0.30.opm'))
    # Upgrade fixture assertions can also verify install-created fields/settings.
    fresh = m.command(['docker', 'exec', '-u', 'otrs', m.OTRS, '/opt/otrs/bin/otrs.Console.pl', 'Admin::Package::List'])
    assert 'OTRSRedmineBridge' in fresh and '1.0.30' in fresh
    fresh_fields = package_check('fresh')
    logs.append(console('Admin::Package::Reinstall', '/tmp/OTRSRedmineBridge-1.0.30.opm'))
    assert package_check('fresh') == fresh_fields, 'Reinstall changed dynamic field IDs'
    (out / 'package-commands.log').write_text('\n'.join(logs))
    (out / 'installation.json').write_text(json.dumps(dict(fresh_install=True, upgrade_from='1.0.29',
        upgrade_to='1.0.30', reinstall=True, package_sha256=checksum, unsigned_local_package=True,
        cloud_services_disabled=True, no_published_ports=True), indent=2) + '\n')
    print('Fresh install and reinstall 1.0.30: verified', flush=True)


if __name__ == '__main__':
    main()
