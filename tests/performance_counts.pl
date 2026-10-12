# Compare deterministic operation counts, not CPU/RSS or production throughput.
# Optional argument: a checkout of the previous bridge source.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
BEGIN { unshift @INC, $ARGV[0] if @ARGV; }
use BridgeTest qw(fixture);
use JSON::PP;
my ($bridge, $services) = fixture(count => 125);
$bridge->CronSync();
print JSON::PP->new->canonical->pretty->encode({
    scenario => '125 linked tickets, one unchanged Redmine issue, batch limit 50',
    ticket_get_calls => scalar @{ $services->{gets} },
    redmine_requests => scalar @{ $services->{requests} },
    unchanged_updated_on_writes => scalar(grep { $_->[1] eq 'RedmineLastUpdatedOn' } @{ $services->{writes} }),
    processed_tickets => $services->{cache}{'RedmineBridgeHealth:SyncedCount'},
});
