package StoreTest;
use strict;
use warnings;
use DBI;
use File::Temp qw(tempdir);
use Exporter 'import';
use Scalar::Util qw(weaken);
our @EXPORT_OK = qw(store_fixture);
my (@DatabaseHandles,@StatementOwners);

sub register_fixture_owner {
    my ($Owner)=@_;
    push @StatementOwners,$Owner;
    weaken($StatementOwners[-1]);
    return 1;
}

sub cleanup_fixtures {
    # Cyclic test callbacks can keep Services/adapter statements alive until
    # global destruction. Drop those references before DBI's END disconnect_all.
    for my $Owner(grep {defined} @StatementOwners) {
        for my $Key(qw(sth Cursor)) {
            my $Statement=delete $Owner->{$Key};
            next if !$Statement;
            $Statement->finish() or die 'Fixture statement finish failed';
        }
    }
    for my $DB(grep {defined} @DatabaseHandles) {
        next if !$DB->{Active};
        for my $Statement(grep {defined} @{$DB->{ChildHandles} || []}) {
            $Statement->finish() or die 'Fixture child statement finish failed' if $Statement->{Active};
        }
        $DB->rollback() or die 'Fixture rollback failed' if !$DB->{AutoCommit};
        $DB->disconnect() or die 'Fixture disconnect failed';
    }
    @StatementOwners=();@DatabaseHandles=();
    return 1;
}

END {cleanup_fixtures()}

sub store_fixture {
    my (%Param) = @_;
    my $Octets = $Param{OctetBackend} || 0;
    my $Dir = tempdir(CLEANUP => 1);
    my @DB = map { DBI->connect("dbi:SQLite:dbname=$Dir/store.sqlite", '', '',
        { RaiseError=>1, PrintError=>0, AutoCommit=>1, sqlite_unicode=>!$Octets }) } 1..2;
    for my $DB(@DB) {push @DatabaseHandles,$DB;weaken($DatabaseHandles[-1]);}
    $DB[0]->do('CREATE TABLE redmine_sync_issue (issue_key VARCHAR(64) PRIMARY KEY, source_key VARCHAR(64) NOT NULL, issue_id INTEGER NOT NULL, updated_on VARCHAR(40) DEFAULT \'\', issue_status VARCHAR(250) DEFAULT \'\', links_hash VARCHAR(64) DEFAULT \'\', generation INTEGER NOT NULL DEFAULT 1, round_generation INTEGER NOT NULL DEFAULT 1, done_generation INTEGER NOT NULL DEFAULT 0, after_ticket_id INTEGER NOT NULL DEFAULT 0, first_failed_ticket_id INTEGER NOT NULL DEFAULT 0, lease_token VARCHAR(64) DEFAULT \'\', lease_until INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0, served_at INTEGER NOT NULL DEFAULT 0, queued_at INTEGER NOT NULL DEFAULT 0, delivery_signature VARCHAR(64) DEFAULT \'\', observed_at INTEGER NOT NULL DEFAULT 0, probe_at INTEGER NOT NULL DEFAULT 0, last_error VARCHAR(2000) DEFAULT \'\', retry_count INTEGER NOT NULL DEFAULT 0, UNIQUE(source_key, issue_id))');
    $DB[0]->do('CREATE TABLE redmine_sync_lock (lock_key VARCHAR(64) PRIMARY KEY, lease_token VARCHAR(64), lease_until INTEGER NOT NULL)');
    my $Count = 0;
    require Kernel::System::Redmine::SyncStore;
    my @Stores = map { StoreTest::Store->new(DBObject=>bless({dbh=>$_, Backend=>bless({'DB::PreProcessSQL'=>$Octets, 'DB::PreProcessBindData'=>$Octets, 'DB::Encode'=>$Octets}, 'StoreTest::Backend')},'StoreTest::DB')) } @DB;
    register_fixture_owner($_->{DBObject}) for @Stores;
    $Stores[0]{_WriteCounter}=\$Count;
    return (\@Stores, \@DB, \$Count, $Dir);
}
# Count calls at the DB adapter boundary, without SQLite XS callbacks during
# global destruction (which crash some bundled macOS DBD::SQLite builds).
package StoreTest::Store;
our @ISA=('Kernel::System::Redmine::SyncStore');
sub _Do {
    my ($Self,$SQL,@Bind)=@_;
    ${$Self->{_WriteCounter}}++ if $Self->{_WriteCounter} && $SQL =~ /^\s*(?:INSERT|UPDATE|DELETE)\b/i;
    $Self->{_OnDML}->($SQL) if $Self->{_OnDML};
    return $Self->SUPER::_Do($SQL,@Bind);
}
package StoreTest::DB;
sub Connect { $_[0]{dbh} }
sub Prepare {
    my ($Self,%Param)=@_;
    my $SQL=$Param{SQL};
    $Self->{Backend}->PreProcessSQL(\$SQL) if $Self->{Backend}{'DB::PreProcessSQL'};
    my @Bind=map {$$_} @{$Param{Bind} || []};
    $Self->{Backend}->PreProcessBindData(\@Bind) if $Self->{Backend}{'DB::PreProcessBindData'};
    $Self->{LastLimit}=$Param{Limit};
    $SQL.=' LIMIT '.int($Param{Limit}) if $Param{Limit};
    $Self->{Cursor}=$Self->{dbh}->prepare($SQL);
    return $Self->{Cursor}->execute(@Bind);
}
sub FetchrowArray {
    my ($Self)=@_;
    my @Row=$Self->{Cursor}->fetchrow_array();
    if ($Self->{Backend}{'DB::Encode'}) {
        @Row=map { defined $_ ? Encode::decode_utf8($_) : undef } @Row;
    }
    return @Row;
}
package StoreTest::Backend;
use Encode ();
sub PreProcessSQL { $_[0]{SQLCalls}++; ${$_[1]}=Encode::encode_utf8(${$_[1]}); }
sub PreProcessBindData {
    $_[0]{BindCalls}++;
    for (@{$_[1]}) { $_=Encode::encode_utf8($_) if defined $_; }
}
1;
