"""Additional actual Package Manager upgrade 1.0.29 -> final 1.0.31, local lab only."""
import json
from pathlib import Path
import run as lab
from package31 import console
from next_sync_regressions import restore_seed

def main():
    console('Dev::Package::Build','--module-directory','/bench/.state/package-1.0.29','/bench/.state/package-1.0.29/OTRSRedmineBridge.sopm','/tmp')
    restore_seed(lab.STATE/'seed.sql')
    query="""DROP TABLE IF EXISTS redmine_sync_issue; DROP TABLE IF EXISTS redmine_sync_lock;
DELETE v FROM dynamic_field_value v JOIN dynamic_field d ON d.id=v.field_id WHERE d.name='RedmineLastAttachmentSyncOn';
DELETE FROM dynamic_field WHERE name='RedmineLastAttachmentSyncOn';"""
    lab.command(['docker','exec',lab.DB,'sh','-c','exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$OTRS_DB_NAME" -e "$1"','query',query])
    console('Maint::Cache::Delete')
    console('Admin::Package::Install','/tmp/OTRSRedmineBridge-1.0.29.opm')
    lab.command(['docker','exec','-u','otrs',lab.OTRS,'perl','/bench/package_check.pl','before'])
    console('Admin::Package::Upgrade','/tmp/OTRSRedmineBridge-1.0.31.opm')
    proof=json.loads(lab.command(['docker','exec','-u','otrs',lab.OTRS,'perl','/bench/package_check.pl','after']).strip().splitlines()[-1])
    columns=lab.command(['docker','exec',lab.DB,'sh','-c','exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" "$OTRS_DB_NAME" -N -e "$1"','query','SHOW COLUMNS FROM redmine_sync_issue'])
    assert all(name in columns for name in ('first_failed_ticket_id','round_generation','served_at'))
    proof.update(upgrade_from='1.0.29',upgrade_to='1.0.31',new_attachment_cursor_was_absent=True,final_schema_created=True)
    (lab.RESULTS/'next-sync/upgrade-from-1.0.29.json').write_text(json.dumps(proof,indent=2)+'\n')
    print('Direct upgrade 1.0.29 -> final 1.0.31: PASS',flush=True)

if __name__=='__main__':main()
