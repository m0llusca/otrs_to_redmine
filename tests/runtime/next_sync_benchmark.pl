# Real OTRS worker/fixture helper. Only the dedicated bridge-perf-local lab.
use strict;
use warnings;
use utf8;
use lib '/opt/otrs', '/opt/otrs/Kernel/cpan-lib';
BEGIN {
    die 'variant must be old or new' if !$ARGV[0] || $ARGV[0] !~ /\A(?:old|new)\z/;
    unshift @INC, '/bench/.state/release-1.0.30' if $ARGV[0] eq 'old';
}
use Kernel::System::ObjectManager;
use JSON::PP;
use BSD::Resource qw(getrusage);
use Time::HiRes qw(time);
use Digest::SHA qw(sha256_hex);
$|=1;
my ($Variant,$Action,$Scenario,$OptionsJSON)=@ARGV;
my $JSON=JSON::PP->new->canonical->utf8;
my $Options=$JSON->decode($OptionsJSON || '{}');
local $Kernel::OM=Kernel::System::ObjectManager->new();
my $Config=$Kernel::OM->Get('Kernel::Config');
my %Settings=(
    'Redmine::Enabled'=>1,'Redmine::InboundSync'=>1,'Redmine::AutoRetry'=>0,
    'Redmine::BaseURL'=>'http://redmine:8080','Redmine::APIKey'=>'local-next-sync-only',
    'Redmine::ProjectID'=>1,'Redmine::TrackerID'=>2,'Redmine::SyncBatchLimit'=>50,
    'Redmine::SyncAttachments'=>1,'Redmine::StatusSync'=>{'Проверка решения'=>'open|note','New'=>'closed successful'},
    'Redmine::MaxAttachmentBytes'=>5000000,'Redmine::MaxAttachmentTotalBytes'=>20000000,
    'Redmine::MaxAttachmentCount'=>20,'Redmine::NotifyOnStatusNote'=>0,
    'SendmailModule'=>'Kernel::System::Email::DoNotSendEmail',
    %{ $Options->{settings} || {} },
);
$Config->Set(Key=>$_,Value=>$Settings{$_}) for keys %Settings;
my $Cache=$Kernel::OM->Get('Kernel::System::Cache');
$Cache->Configure(CacheInMemory=>0,CacheInBackend=>1);
my $Bridge=$Kernel::OM->Get('Kernel::System::Redmine');
my $Ticket=$Kernel::OM->Get('Kernel::System::Ticket');
my $Article=$Kernel::OM->Get('Kernel::System::Ticket::Article');
my $DB=$Kernel::OM->Get('Kernel::System::DB');
my $Loaded=$INC{'Kernel/System/Redmine/Sync.pm'};
die 'old immutable overlay not loaded' if $Variant eq 'old' && $Loaded ne '/bench/.state/release-1.0.30/Kernel/System/Redmine/Sync.pm';
die 'new source must be installed' if $Variant eq 'new' && $Loaded ne '/opt/otrs/Kernel/System/Redmine/Sync.pm';
open my $Source,'<',$Loaded or die $!;
my $SourceSHA=do{local $/;sha256_hex(<$Source>)};close $Source;
open my $In,'<','/opt/otrs/var/tmp/bridge-benchmark.json' or die $!;
my $Fixture=do{local $/;$JSON->decode(<$In>)};close $In;
my @IDs=@{$Fixture->{audit_poll} || []};
die 'grow the fixture to exactly 1000 audit tickets first' if @IDs != 1000;
my $Count=$Options->{count} || 1000;
die 'count must be 1..1000' if $Count<1 || $Count>1000;
splice @IDs,$Count if @IDs>$Count;
my $Objects=join ',',map{int $_}@IDs;
sub emit { print JSON::PP->new->canonical->ascii->encode($_[0]),"\n"; }
sub rows {
    my ($SQL,@Bind)=@_;my @Refs=map{\$_}@Bind;
    $DB->Prepare(SQL=>$SQL,Bind=>\@Refs) or die 'fixture read failed';
    my @Rows;while(my @Row=$DB->FetchrowArray()){push @Rows,\@Row}return \@Rows;
}
sub scalar_sql { return rows(@_)->[0][0] || 0; }
sub sql {
    my ($SQL,@Bind)=@_;my @Refs=map{\$_}@Bind;
    $DB->Do(SQL=>$SQL,Bind=>\@Refs) or die 'fixture write failed';
}
sub questions {return rows("SHOW SESSION STATUS LIKE 'Questions'")->[0][1]+0;}
sub store {return $Kernel::OM->Get('Kernel::System::Redmine::SyncStore');}
sub pending {
    my $Source=store()->SourceKey();
    my $Rows=rows('SELECT issue_key, issue_id, generation, done_generation, after_ticket_id, retry_at, lease_until, queued_at, retry_count, first_failed_ticket_id, round_generation FROM redmine_sync_issue WHERE source_key = ? ORDER BY retry_at, issue_id',$Source);
    my @Work=grep{$_->[2]>$_->[3]}@$Rows;
    my @Due=grep{$_->[5]<=time() && $_->[6]<=time()}@Work;
    return {source_key=>$Source,total=>scalar(@$Rows),pending=>scalar(@Work),due=>scalar(@Due),
        first_issue_key=>@Due?$Due[0][0]:undef,
        generations=>[map{{issue_key=>$_->[0],issue_id=>$_->[1],generation=>$_->[2]+0,done_generation=>$_->[3]+0,
            after_ticket_id=>$_->[4]+0,retry_at=>$_->[5]+0,lease_until=>$_->[6]+0,queued_at=>$_->[7]+0,retry_count=>$_->[8]+0,first_failed_ticket_id=>$_->[9]+0,round_generation=>$_->[10]+0}}@$Rows]};
}
if($Action eq 'prepare') {
    my $All=join ',',map{int $_}@{$Fixture->{audit_poll}};
    my $Fields=join ',',map{int $_}values %{$Fixture->{field_ids}};
    sql("DELETE FROM dynamic_field_value WHERE object_id IN ($All) AND field_id IN ($Fields)");
    my %Values=(RedmineID=>'7001',RedmineStatus=>'New',RedmineLastUpdatedOn=>'2026-01-01T00:00:00Z',
        RedmineLastAttachmentSyncOn=>'2026-01-01T00:00:00Z',RedmineLastJournalID=>'10',
        RedmineLastAttachmentID=>'0',RedmineLastSyncAt=>'0');
    for my $Name(sort keys %Values) {
        my $Expression=$Name eq 'RedmineID' && $Scenario=~/unique|distinct/ ? 'CAST(id + 7000 AS CHAR)' : '?';
        my @Bind=($Fixture->{field_ids}{$Name});push @Bind,$Values{$Name} if $Expression eq '?';
        sql("INSERT INTO dynamic_field_value (field_id,object_id,value_text) SELECT ?,id,$Expression FROM ticket WHERE id IN ($Objects)",@Bind);
    }
    # State is fixture setup, outside the timed work. No synthetic notes/checkpoints.
    my $Closed=$Kernel::OM->Get('Kernel::System::State')->StateLookup(State=>'closed successful');
    sql("UPDATE ticket SET ticket_state_id = ? WHERE id IN ($Objects)",$Closed);
    my @Tables=$DB->ListTables();my %Tables=map{lc($_)=>1}@Tables;
    if($Tables{redmine_sync_issue}){sql('DELETE FROM redmine_sync_issue');sql('DELETE FROM redmine_sync_lock');}
    $Kernel::OM->ObjectEventsHandle();$Cache->CleanUp();
    my @IssueIDs=$Scenario=~/unique|distinct/ ? map{7000+$_}@IDs : (7001);
    emit({prepared=>scalar(@IDs),ticket_ids=>\@IDs,issue_ids=>\@IssueIDs,
        baseline_article_id=>scalar_sql('SELECT MAX(id) FROM article'),loaded_sync=>$Loaded,sync_sha256=>$SourceSHA});exit;
}
if($Action eq 'clear-cache') {$Cache->CleanUp();emit({cache_cleared=>1});exit;}
if($Action eq 'inspect') {
    my $Baseline=$Options->{baseline_article_id} || 0;
    my $New=rows("SELECT id,ticket_id FROM article WHERE ticket_id IN ($Objects) AND id > ? ORDER BY id",$Baseline);
    my %PerTicket;my $Files=0;my @Hashes;my @Bodies;
    for my $Row(@$New) {
        $PerTicket{$Row->[1]}++;
        next if !$Options->{verify_content};
        my $Backend=$Article->BackendForArticle(TicketID=>$Row->[1],ArticleID=>$Row->[0]);
        my %Data=$Backend->ArticleGet(TicketID=>$Row->[1],ArticleID=>$Row->[0]);
        push @Bodies,$Data{Body} || '' if @Bodies<3;
        my %Index=$Backend->ArticleAttachmentIndex(ArticleID=>$Row->[0],UserID=>1,ExcludePlainText=>1,ExcludeHTMLBody=>1);
        for my $FileID(sort {$a<=>$b}keys %Index) {
            my %File=$Backend->ArticleAttachment(ArticleID=>$Row->[0],FileID=>$FileID,UserID=>1);
            die 'attachment content missing during validation' if !defined $File{Content};
            my $Bytes=ref($File{Content}) eq 'SCALAR'?${$File{Content}}:$File{Content};
            push @Hashes,sha256_hex($Bytes);$Files++;
        }
    }
    my %Checkpoints;
    for my $Name(qw(RedmineStatus RedmineLastJournalID RedmineLastAttachmentID RedmineLastUpdatedOn RedmineLastSyncAt)) {
        $Checkpoints{$Name}=rows("SELECT value_text,COUNT(*) FROM dynamic_field_value WHERE field_id = ? AND object_id IN ($Objects) GROUP BY value_text",$Fixture->{field_ids}{$Name});
    }
    for my $Values(values %Checkpoints) {$_->[1]+=0 for @$Values;}
    my $States=rows("SELECT s.name,COUNT(*) FROM ticket t INNER JOIN ticket_state s ON s.id=t.ticket_state_id WHERE t.id IN ($Objects) GROUP BY s.name");
    $_->[1]+=0 for @$States;
    emit({new_notes=>scalar(@$New),tickets_with_notes=>scalar(keys %PerTicket),max_notes_per_ticket=>
        ((sort {$b<=>$a}values %PerTicket)[0] || 0),attachments=>$Files,attachment_hashes=>\@Hashes,
        sample_bodies=>\@Bodies,checkpoints=>\%Checkpoints,states=>$States,
        work=>$Variant eq 'new'?pending():undef});exit;
}
if($Action eq 'seed-sibling-file-cursors') {
    for my $ID (@IDs[1..$#IDs]) {
        $Bridge->_SetDF(TicketID=>$ID,Name=>'RedmineLastAttachmentID',Value=>'1',UserID=>1)
            or die 'cannot seed already-seen sibling file cursor';
    }
    $Kernel::OM->ObjectEventsHandle();$Cache->CleanUp();
    emit({siblings_seeded=>@IDs-1});exit;
}
if($Action eq 'force-ready') {
    die 'test-only durable controls require new variant' if $Variant ne 'new';
    my $Source=store()->SourceKey();
    sql('UPDATE redmine_sync_issue SET retry_at = 0, lease_until = 0, queued_at = 0 WHERE source_key = ?',$Source);
    sql('UPDATE redmine_sync_lock SET lease_until = 0');
    $Cache->CleanUp(Type=>'RedmineBridgeHTTP');emit({forced_ready=>1});exit;
}
if($Action eq 'force-probe') {
    die 'test-only probe control requires new variant' if $Variant ne 'new';
    sql('UPDATE redmine_sync_issue SET probe_at = 0 WHERE source_key = ?',store()->SourceKey());
    emit({probe_due=>1});exit;
}
if($Action eq 'claim-expired') {
    die 'test-only durable controls require new variant' if $Variant ne 'new';
    my $Work=pending();die 'no pending issue' if !$Work->{first_issue_key};
    my $Claim=store()->Claim(IssueKey=>$Work->{first_issue_key},LeaseSeconds=>1);
    die 'cannot claim fixture issue' if !$Claim;
    emit({claimed=>$Claim->{issue_key},token=>$Claim->{lease_token}});exit;
}
die 'unknown harness action' if $Action ne 'worker';
my $Mode=$Options->{mode} || ($Variant eq 'old'?'cron':'poll');
my %Result;
if($Options->{fault_field}) {
    die 'fault injection is verification-only and requires new source' if $Variant ne 'new';
    no warnings 'redefine';
    my $Original=$Bridge->can('_SetDF');
    *Kernel::System::Redmine::_SetDF=sub {
        my ($Self,%Param)=@_;
        die "Controlled checkpoint failure\n" if $Param{Name} eq $Options->{fault_field};
        return $Original->(@_);
    };
}
# Bootstrap is excluded; requests/DB/events from bridge work are included.
my $Q0=questions();my @R0=getrusage();my $T0=time();
if($Variant eq 'old') {
    die 'old worker supports cron only' if $Mode ne 'cron';
    my $OK=$Bridge->CronSync();%Result=(Success=>$OK?1:0);
}
elsif($Mode eq 'poll') {%Result=(Success=>$Bridge->PollSync()?1:0);}
elsif($Mode eq 'deliver') {
    my $Return=$Bridge->ProcessSyncBatch(SourceKey=>$Options->{source_key} || store()->SourceKey(),
        SeedIssueKey=>$Options->{seed_issue_key});
    die 'ProcessSyncBatch must return a hash reference' if ref($Return) ne 'HASH';
    %Result=%$Return;
}
elsif($Mode eq 'manual') {%Result=$Bridge->SyncTicketFromRedmine(TicketID=>$IDs[0],UserID=>1);}
else {die 'unknown new worker mode';}
$Kernel::OM->ObjectEventsHandle();
my $Wall=time()-$T0;my @R1=getrusage();my $Q1=questions();
# Peak RSS captured above, before validation or source/health inspection.
emit({variant=>$Variant,scenario=>$Scenario,mode=>$Mode,result=>\%Result,
    cpu_user_seconds=>$R1[0]-$R0[0],cpu_system_seconds=>$R1[1]-$R0[1],
    cpu_seconds=>($R1[0]-$R0[0])+($R1[1]-$R0[1]),wall_seconds=>$Wall,
    peak_rss_kib=>$R1[2],startup_peak_rss_kib=>$R0[2],sql_queries=>$Q1-$Q0-1,
    loaded_sync=>$Loaded,sync_sha256=>$SourceSHA,variable_check=>$INC{'Kernel/System/VariableCheck.pm'},
    cache_mode=>'backend_only',events_flushed=>1,
    health=>{map{$_=>$Cache->Get(Type=>'RedmineBridgeHealth',Key=>$_)}qw(SyncedCount LastSyncOK LastSyncError)} });
