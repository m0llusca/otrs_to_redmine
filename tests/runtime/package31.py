"""Build and verify package 1.0.31 only in the dedicated local OTRS lab."""
import argparse, base64, hashlib, json, shutil, subprocess
from pathlib import Path
import xml.etree.ElementTree as ET
import run as lab

OUT=lab.RESULTS/'next-sync'
OUT.mkdir(exist_ok=True)

def console(*args):
    result=lab.command(['docker','exec','-u','otrs',lab.OTRS,'/opt/otrs/bin/otrs.Console.pl',*args])
    if 'Done.' not in result: raise RuntimeError(result)
    with (OUT/'package-commands.log').open('a') as out: out.write(result+'\n')
    return result

def dump(path):
    with path.open('wb') as stream:
        subprocess.run(['docker','exec',lab.DB,'sh','-c','exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --skip-comments "$OTRS_DB_NAME"'],stdout=stream,stderr=subprocess.PIPE,check=True)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--fresh',action='store_true');args=ap.parse_args()
    if args.fresh:
        # Restore the original isolated pre-package database, then remove its
        # synthetic bridge definitions to exercise genuinely fresh field creation.
        lab.restore()
        sql="DROP TABLE IF EXISTS redmine_sync_issue; DROP TABLE IF EXISTS redmine_sync_lock; DELETE v FROM dynamic_field_value v JOIN dynamic_field d ON d.id=v.field_id WHERE d.name LIKE 'Redmine%'; DELETE FROM dynamic_field WHERE name LIKE 'Redmine%';"
        lab.command(['docker','exec',lab.DB,'sh','-c',
            'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$OTRS_DB_NAME" -e "$1"','query',sql])
        console('Maint::Cache::Delete')
        console('Admin::Package::Install','/tmp/OTRSRedmineBridge-1.0.31.opm')
        before=lab.command(['docker','exec',lab.DB,'sh','-c',"mariadb -uroot -p\"$MYSQL_ROOT_PASSWORD\" \"$OTRS_DB_NAME\" -N -e \"SELECT id,name FROM dynamic_field WHERE name LIKE 'Redmine%' ORDER BY id\""])
        assert len(before.strip().splitlines())==13 and 'RedmineLastSyncAt' not in before
        console('Admin::Package::Reinstall','/tmp/OTRSRedmineBridge-1.0.31.opm')
        after=lab.command(['docker','exec',lab.DB,'sh','-c',"mariadb -uroot -p\"$MYSQL_ROOT_PASSWORD\" \"$OTRS_DB_NAME\" -N -e \"SELECT id,name FROM dynamic_field WHERE name LIKE 'Redmine%' ORDER BY id\""])
        assert before==after
        (OUT/'fresh-install.json').write_text(json.dumps({'fresh_install':True,'reinstall':True,'fields':13,'IDs_preserved_on_reinstall':True})+'\n')
        print('Fresh install/reinstall: PASS');return
    stage=lab.STATE/'package-1.0.31'
    files=[f.attrib['Location'] for f in ET.parse(lab.ROOT/'OTRSRedmineBridge.sopm').findall('.//File')]
    for name in files+['OTRSRedmineBridge.sopm']:
        p=stage/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(lab.ROOT/name,p)
    console('Dev::Package::Build','--module-directory','/bench/.state/package-1.0.31','/bench/.state/package-1.0.31/OTRSRedmineBridge.sopm','/tmp')
    installed=lab.command(['docker','exec','-u','otrs',lab.OTRS,'/opt/otrs/bin/otrs.Console.pl','Admin::Package::List'])
    action='Admin::Package::Reinstall' if '1.0.31' in installed else 'Admin::Package::Upgrade'
    console(action,'/tmp/OTRSRedmineBridge-1.0.31.opm')
    tables=lab.command(['docker','exec',lab.DB,'sh','-c',
        'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$OTRS_DB_NAME" -N -e "$1"',
        'query', "SHOW TABLES LIKE 'redmine_sync_%'"])
    assert set(tables.strip().splitlines())=={'redmine_sync_issue','redmine_sync_lock'}, 'Schema upgrade did not create both tables'
    upgrade=json.loads(lab.command(['docker','exec','-u','otrs',lab.OTRS,'perl','/bench/package_check.pl','after']).strip().splitlines()[-1])
    (OUT/'upgrade.json').write_text(json.dumps(upgrade,indent=2)+'\n')
    artifact=lab.ROOT/'dist/OTRSRedmineBridge-1.0.31.opm';lab.command(['docker','cp',lab.OTRS+':/tmp/'+artifact.name,str(artifact)])
    payload=ET.parse(artifact);fs=payload.findall('.//File');assert len(fs)==21 and payload.findtext('Version')=='1.0.31'
    assert {f.attrib['Location'] for f in fs}==set(files)
    manifest={}
    for f in fs:
        name=f.attrib['Location'];content=base64.b64decode(f.text);assert content==(lab.ROOT/name).read_bytes()
        manifest[name]=hashlib.sha256(content).hexdigest()
        assert lab.command(['docker','exec',lab.OTRS,'sha256sum','/opt/otrs/'+name]).split()[0]==manifest[name]
    checksum=hashlib.sha256(artifact.read_bytes()).hexdigest()
    (OUT/'package-manifest.json').write_text(json.dumps({'version':'1.0.31','package_sha256':checksum,'sources':manifest,'file_count':len(fs),'payload_source_installed_match':True},indent=2)+'\n')
    previous=lab.ROOT/'dist/SHA256SUMS';lines=previous.read_text().splitlines() if previous.exists() else []
    lines=[line for line in lines if not line.endswith(artifact.name)];lines.append(checksum+'  '+artifact.name);previous.write_text('\n'.join(lines)+'\n')
    dump(lab.STATE/'next-sync-seed.sql')
    print('Upgrade/package payload: PASS; seed saved; Sync SHA256='+manifest['Kernel/System/Redmine/Sync.pm'])

if __name__=='__main__': main()
