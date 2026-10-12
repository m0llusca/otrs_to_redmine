#!/bin/bash
# The historical image helpers inspect command exit codes themselves and are
# not compatible with bash errexit (e.g. grep-before-insert in add_config_value).
exec > >(perl -pe 'BEGIN { $|=1; @secrets=map {$ENV{$_}} grep {/PASSWORD|SECRET|TOKEN|API.?KEY/i && length($ENV{$_})} keys %ENV } for $secret (@secrets) { s/\Q$secret\E/[redacted]/g }') 2>&1
rm -f /tmp/bridge-runtime-ready
cd /
. /functions.sh
wait_for_db
load_defaults
add_config_value Database "${OTRS_DB_NAME}"
add_config_value SendmailModule Kernel::System::Email::DoNotSendEmail
add_config_value CheckMXRecord 0
add_config_value CloudServices::Disabled 1
add_config_value Package::AllowNotVerifiedPackages 1
set -e
cp -a /bench/.state/after/Kernel/. /opt/otrs/Kernel/
cp -a /bench/.state/after/var/packagesetup /opt/otrs/var/
# No cron, daemon, mail fetcher or web server: only explicitly invoked tests run.
/opt/otrs/bin/otrs.SetPermissions.pl --otrs-user=otrs --web-group=apache /opt/otrs
su -s /bin/bash otrs -c '/opt/otrs/bin/otrs.Console.pl Maint::Config::Rebuild'
touch /tmp/bridge-runtime-ready
exec tail -f /dev/null
