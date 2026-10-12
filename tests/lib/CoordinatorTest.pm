package CoordinatorTest;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use StoreTest qw(store_fixture);
use Kernel::System::Redmine::HTTP;
use Scalar::Util qw(weaken);
our @EXPORT_OK = qw(coordinator_fixture coordinator_fair_fixture);
sub coordinator_fixture {
    my (%P)=@_;
    my ($Stores,$DB,$Writes)=store_fixture();
    my $S=bless {store=>$Stores->[0],dbh=>$DB->[0], settings=>{
        'Redmine::Enabled'=>1,'Redmine::InboundSync'=>1,
        'Redmine::BaseURL'=>'http://redmine.test','Redmine::APIKey'=>'fixture',
        'Redmine::SyncAttachments'=>1,'Redmine::SyncBatchLimit'=>2,
        'Redmine::StatusSync'=>{'New'=>'open'},%{$P{settings}||{}}},
        cache=>{},requests=>[],tasks=>[],processed=>[],issues=>{},logs=>[],selects=>[],now=>1000},'CoordinatorTest::Services';
    StoreTest::register_fixture_owner($S);
    $S->{dbh}->do('CREATE TABLE ticket (id INTEGER PRIMARY KEY, archive_flag INTEGER DEFAULT 0)');
    $S->{dbh}->do('CREATE TABLE dynamic_field_value (field_id INTEGER, object_id INTEGER, value_text TEXT)');
    $S->{dbh}->do('CREATE TABLE scheduler_task (id INTEGER PRIMARY KEY, task_type TEXT, name TEXT)');
    for my $I (1..($P{count}||3)) {
        my $Issue=$P{unique}?$I:7;
        $S->{dbh}->do('INSERT INTO ticket (id) VALUES (?)',undef,$I);
        $S->{dbh}->do('INSERT INTO dynamic_field_value VALUES (1,?,?)',undef,$I,"$Issue");
        $S->{issues}{$Issue}={id=>$Issue,updated_on=>'2026-01-01',status=>{name=>'New'},journals=>[],attachments=>[]};
    }
    $S->{issue_writes}=0;
    my$WeakServices=$S;weaken($WeakServices);
    $Stores->[0]{_OnDML}=sub {
        $WeakServices->{issue_writes}++ if $WeakServices && $_[0] =~ /^\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+redmine_sync_issue\b/i;
    };
    $Kernel::OM=$S;
    require Kernel::System::Redmine::SyncCoordinator;
    return (bless({},'CoordinatorTest::Bridge'),$S,$Writes,$Stores);
}
sub coordinator_fair_fixture {
    my(%P)=@_;
    require BridgeTest;
    my ($Bridge,$Services)=BridgeTest::fixture(count=>$P{count}||1000,settings=>{
        'Redmine::SyncBatchLimit'=>$P{batch}||50,'Redmine::SyncAttachments'=>$P{attachments}?1:0,
        'Redmine::StatusSync'=>{'Проверка решения'=>'open|note'}});
    StoreTest::register_fixture_owner($Services);
    $Services->{now}=time();
    $Services->{issues}{7}{status}={id=>2,name=>'Проверка решения'};
    $Services->{issues}{7}{journals}=[{id=>11,notes=>'FAIR-JID-11',user=>{name=>'Fixture'},
        details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]}];
    return (bless($Bridge,'CoordinatorTest::FairBridge'),$Services);
}
package CoordinatorTest::Services;
sub Get {
    my ($S,@A)=@_;
    return $S->{store} if @A==1 && $A[0] eq 'Kernel::System::Redmine::SyncStore';
    return $S if @A==1 && $A[0]=~/^Kernel::/;
    return $S->{settings}{$A[0]} if @A==1;
    my %P=@A; return $S->{cache}{"$P{Type}:$P{Key}"};
}
sub Set {my($S,%P)=@_;$S->{cache}{"$P{Type}:$P{Key}"}=$P{Value};return 1}
sub Configure {my($S,%P)=@_;$S->{configured}=\%P;return 1}
sub DynamicFieldGet {return {ID=>1}}
sub Prepare {
    my($S,%P)=@_;die 'SQL boundary unavailable' if $S->{fail_select};
    push @{$S->{selects}},\%P;
    my $SQL=$P{SQL};$SQL.=' LIMIT '.int($P{Limit}) if $P{Limit};
    $S->{sth}=$S->{dbh}->prepare($SQL);$S->{sth}->execute(map {$$_} @{$P{Bind}||[]});return 1;
}
sub FetchrowArray {return $_[0]{sth}->fetchrow_array()}
sub TaskAdd {
    my($S,%P)=@_;return if $S->{fail_queue};
    push @{$S->{tasks}},\%P;
    $S->{dbh}->do('INSERT INTO scheduler_task (task_type,name) VALUES (?,?)',undef,$P{Type},$P{Name});
    return scalar @{$S->{tasks}};
}
sub Log {my($S,%P)=@_;push @{$S->{logs}},\%P;return 1}
package CoordinatorTest::Bridge;
our @ISA=('Kernel::System::Redmine::SyncCoordinator','Kernel::System::Redmine::HTTP');
sub _SyncNow {return $Kernel::OM->{now}}
sub _Request {
    my($Self,%P)=@_;my$S=$Kernel::OM;push @{$S->{requests}},{%P,Scoped=>$Self->{_RequestScope}?1:0};
    $S->{on_request}->(\%P) if $S->{on_request};
    return (Success=>0,Error=>'fixture transport error',RetryAfterSeconds=>99) if $S->{fail_http};
    if($P{Path}=~m{^/issues\.json\?issue_id=([0-9,]+).*offset=(\d+)}) {
        my @IDs=split /,/,$1;my$Offset=$2;my @Issues=map {$S->{issues}{$_}} grep {$S->{issues}{$_}&&!$S->{omitted}{$_}} @IDs;
        my$Total=@Issues;my$Limit=$S->{server_limit}||100;@Issues=splice @Issues,$Offset,$Limit;
        push @Issues,$S->{foreign_issue} if $S->{foreign_issue};
        return (Success=>1,Data=>{issues=>\@Issues,total_count=>$Total,limit=>$Limit,offset=>$Offset});
    }
    if($P{Path}=~m{^/issues/(\d+)\.json}) {
        my$I=$S->{issues}{$1};return (Success=>0,HTTPCode=>404,Error=>'missing') if !$I;
        return (Success=>1,Content=>'raw must be stripped',Data=>{issue=>$I});
    }
    die "Unexpected request $P{Path}";
}
sub SyncTicketFromRedmine {
    my($Self,%P)=@_;my$S=$Kernel::OM;push @{$S->{processed}},\%P;
    $S->{on_ticket}->(\%P) if $S->{on_ticket};
    return (Success=>0,Error=>'ticket failed',RetryAfterSeconds=>33) if $S->{fail_ticket}&&$P{TicketID}==$S->{fail_ticket};
    if($S->{atomic_progress}) {$S->{store}->Progress(%{$P{Work}},AfterTicketID=>$P{TicketID},Now=>$S->{now});return(Success=>1,Status=>'Synced',ProgressCommitted=>1)}
    return (Success=>1,Status=>'Synced');
}
package CoordinatorTest::FairBridge;
our @ISA=('BridgeTest::Bridge');
sub _SyncNow {return $Kernel::OM->{now}}
sub _Request {
    my($Self,%P)=@_;
    if($P{Path}=~m{^/issues\.json\?issue_id=([0-9,]+).*offset=(\d+)}) {
        my@IDs=split /,/,$1;my$Offset=$2;
        my@Issues=map {$Kernel::OM->{issues}{$_}} grep {$Kernel::OM->{issues}{$_}} @IDs;
        my$Total=@Issues;@Issues=splice @Issues,$Offset,100;
        push @{$Kernel::OM->{requests}},\%P;
        return(Success=>1,Data=>{issues=>\@Issues,total_count=>$Total,limit=>100,offset=>$Offset});
    }
    if($Kernel::OM->{missing_file_http404}&&$P{Path}=~m{^/attachments/download/}) {
        push@{$Kernel::OM->{requests}},\%P;
        return(Success=>0,HTTPCode=>404,Error=>'fixture attachment missing');
    }
    return $Self->SUPER::_Request(%P);
}
1;
