use strict;
use warnings;
use utf8;
use lib '/opt/otrs', '/opt/otrs/Kernel/cpan-lib';
BEGIN {
    die 'invalid source variant' if !$ARGV[0] || $ARGV[0] !~ /\A(?:before|after|pre_cpu|installed)\z/;
    unshift @INC, '/bench/.state/' . $ARGV[0] if $ARGV[0] ne 'installed';
}
use Kernel::System::ObjectManager;
use JSON::PP;
use Time::HiRes qw(time);
use BSD::Resource qw(getrusage);
use Digest::SHA qw(sha256_hex);
my ($variant, $operation, $scenario) = @ARGV;
local $Kernel::OM = Kernel::System::ObjectManager->new();
my $Config = $Kernel::OM->Get('Kernel::Config');
my %Settings = (
    'Redmine::Enabled'=>1, 'Redmine::InboundSync'=>1, 'Redmine::AutoRetry'=>0,
    'Redmine::BaseURL'=>'http://redmine:8080', 'Redmine::APIKey'=>'local-fixture-only',
    'Redmine::ProjectID'=>1, 'Redmine::TrackerID'=>2, 'Redmine::PriorityID'=>2,
    'Redmine::SyncBatchLimit'=>50, 'Redmine::SyncAttachments'=>1,
    'Redmine::MaxAttachmentBytes'=>5000000, 'Redmine::MaxAttachmentTotalBytes'=>20000000,
    'Redmine::MaxAttachmentCount'=>20, 'Redmine::StatusSync'=>{'Проверка решения'=>'open|note'},
    'Redmine::NotifyOnStatusNote'=>0, 'Redmine::FormLoadAllProjects'=>0,
    'Redmine::OTRSBaseURL'=>'http://otrs-benchmark.invalid/otrs',
    'SendmailModule'=>'Kernel::System::Email::DoNotSendEmail',
);
$Settings{'Redmine::BaseURL'}='https://redmine:8443' if $ENV{BRIDGE_PEER_TLS};
$Settings{'WebUploadCacheModule'}='Kernel::System::Web::UploadCache::FS' if $ENV{BRIDGE_UPLOAD_FS};
$Config->Set(Key=>$_,Value=>$Settings{$_}) for keys %Settings;
my $Bridge=$Kernel::OM->Get('Kernel::System::Redmine');
my $Ticket=$Kernel::OM->Get('Kernel::System::Ticket');
my $Article=$Kernel::OM->Get('Kernel::System::Ticket::Article');
my $DB=$Kernel::OM->Get('Kernel::System::DB');
my $Cache=$Kernel::OM->Get('Kernel::System::Cache');
my $FixturePath='/opt/otrs/var/tmp/bridge-benchmark.json';
my $JSON=JSON::PP->new->canonical;
sub read_fixture {open my $f,'<',$FixturePath or die $!;local $/;return $JSON->decode(<$f>)}
sub write_fixture {open my $f,'>',$FixturePath or die $!;print {$f} $JSON->encode($_[0]);close $f}
sub is_outbound {return $scenario eq 'outbound' || $scenario eq 'extra'}
sub create_ticket {
    my ($title)=@_;
    my $id=$Ticket->TicketCreate(Title=>$title,Queue=>'Raw',Lock=>'unlock',Priority=>'3 normal',
        State=>'open',CustomerID=>'bridge-benchmark',CustomerUser=>'benchmark@example.invalid',OwnerID=>1,UserID=>1);
    die 'TicketCreate failed' if !$id;return $id;
}
sub sql {
    my ($query,@bind)=@_;
    my @refs=map {\$_} @bind;
    $DB->Do(SQL=>$query,Bind=>\@refs) or die 'Fixture SQL failed';
}
sub session_queries {
    $DB->Prepare(SQL=>"SHOW SESSION STATUS LIKE 'Questions'") or die 'Query stats unavailable';
    my @row=$DB->FetchrowArray();return 0+$row[1];
}
if ($operation eq 'setup') {
    $Kernel::OM->Get('var::packagesetup::OTRSRedmineBridge')->CodeInstall();
    my @poll=map {create_ticket("Unchanged benchmark $_")} 1..125;
    my @incoming=map {create_ticket("Inbound benchmark $_")} 1..10;
    my $outgoing=create_ticket('Outbound benchmark');
    my @files=map {{Filename=>"outgoing-$_.bin",Content=>'A'x(1024*1024),ContentType=>'application/octet-stream'}} 1..16;
    my $aid=$Article->BackendForChannel(ChannelName=>'Internal')->ArticleCreate(
        TicketID=>$outgoing,SenderType=>'agent',IsVisibleForCustomer=>0,Subject=>'Benchmark input',Body=>'Fixed problem statement',
        ContentType=>'text/plain; charset=utf-8',HistoryType=>'AddNote',HistoryComment=>'%%Benchmark',UserID=>1,Attachment=>\@files);
    die 'Input article failed' if !$aid;
    my %field_ids;
    for my $name (qw(RedmineID RedmineURL RedmineEscalationStatus RedmineLastError RedmineStatus RedmineProjectID RedmineTrackerID RedmineLastJournalID RedmineLastAttachmentID RedmineRetryPayload RedmineRetryCount RedmineLastUpdatedOn RedmineLastSyncAt RedmineLastAttachmentSyncOn)) {
        my $field=$Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(Name=>$name);
        die "Missing dynamic field $name" if !$field || !$field->{ID};$field_ids{$name}=$field->{ID};
    }
    write_fixture({poll=>\@poll,incoming=>\@incoming,outgoing=>$outgoing,field_ids=>\%field_ids});
    print $JSON->encode({setup=>1,poll_tickets=>125,incoming_tickets=>10,outgoing_attachments=>16,otrs_version=>'6.0.10',perl=>"$^V"}),"\n";
    exit;
}
my $Fixture=read_fixture();
if ($operation eq 'verify-links') {
    my $ID=$Fixture->{outgoing};
    my %link=$Bridge->LinkTicketToIssue(TicketID=>$ID,UserID=>1,IssueID=>900);
    die 'Link failed' if !$link{Success} || $Bridge->_GetDF(TicketID=>$ID,Name=>'RedmineID') ne '900';
    my %relink=$Bridge->RelinkTicketToIssue(TicketID=>$ID,UserID=>1,IssueID=>901);
    die 'Relink failed' if !$relink{Success} || $Bridge->_GetDF(TicketID=>$ID,Name=>'RedmineID') ne '901';
    my %unlink=$Bridge->UnlinkTicketFromIssue(TicketID=>$ID,UserID=>1);
    die 'Unlink failed' if !$unlink{Success} || length($Bridge->_GetDF(TicketID=>$ID,Name=>'RedmineID')||'');
    die 'Stream cursor survived unlink' if length($Bridge->_GetDF(TicketID=>$ID,Name=>'RedmineLastAttachmentSyncOn')||'');
    print "{\"link_relink_unlink\":true,\"stream_cursor_cleared\":true}\n";exit;
}
if ($operation eq 'verify-tls-rejection') {
    local $Bridge->{_RequestScope}={};
    my %reply=$Bridge->_Request(Method=>'GET',Path=>'/health');
    die 'Untrusted peer certificate was accepted' if $reply{Success};
    print "{\"untrusted_certificate_rejected\":true}\n";exit;
}
if ($operation eq 'verify-pages') {
    my $objects=join ',',map {int $_} @{$Fixture->{poll}};
    my $field=$Fixture->{field_ids}{RedmineLastSyncAt};
    $DB->Prepare(SQL=>"SELECT COUNT(DISTINCT object_id) FROM dynamic_field_value WHERE object_id IN ($objects) AND field_id = ? AND value_text <> '0'",Bind=>[\$field]) or die 'Page verification failed';
    my @row=$DB->FetchrowArray();
    print $JSON->encode({visited_tickets=>0+$row[0]}),"\n";exit;
}
if ($operation eq 'close-incoming') {
    $Ticket->TicketStateSet(TicketID=>$_,State=>'closed successful',UserID=>1,SendNoNotification=>1) or die 'Cannot prepare state transition'
        for @{$Fixture->{incoming}};
    $Cache->CleanUp();
    print "{\"closed\":10}\n";exit;
}
if ($operation eq 'verify-replay') {
    my %before=map {$_=>join(',',sort map {$_->{ArticleID}} $Article->ArticleList(TicketID=>$_))} @{$Fixture->{incoming}};
    $Bridge->CronSync();
    for my $id (@{$Fixture->{incoming}}) {
        my $after=join(',',sort map {$_->{ArticleID}} $Article->ArticleList(TicketID=>$id));
        die 'Duplicate inbound note on replay' if $after ne $before{$id};
    }
    print "{\"duplicate_notes\":0,\"tickets_checked\":10}\n";exit;
}
if ($operation eq 'extra-setup') {
    my $upload=$Kernel::OM->Get('Kernel::System::Web::UploadCache');
    my $form=$upload->FormIDCreate();
    $upload->FormIDAddFile(FormID=>$form,Filename=>'extra.bin',Content=>'E'x(512*1024),ContentType=>'application/octet-stream') or die 'Extra upload fixture failed';
    $Fixture->{extra_form}=$form;write_fixture($Fixture);
    print "{\"extra_uploaded\":524288}\n";exit;
}
if ($operation eq 'prepare') {
    my @all=(@{$Fixture->{poll}},@{$Fixture->{incoming}},$Fixture->{outgoing});
    my $objects=join ',',map {int $_} @all;
    my $fields=join ',',map {int $_} values %{$Fixture->{field_ids}};
    sql("DELETE FROM dynamic_field_value WHERE object_id IN ($objects) AND field_id IN ($fields)");
    my @ids=$scenario eq 'unchanged' ? @{$Fixture->{poll}} : is_outbound() ? () : @{$Fixture->{incoming}};
    my %values=(RedmineID=>$scenario eq 'unchanged'?'7001':'7002',RedmineStatus=>'New',RedmineLastUpdatedOn=>'2026-01-01T00:00:00Z',RedmineLastAttachmentSyncOn=>'2026-01-01T00:00:00Z',RedmineLastJournalID=>'10',RedmineLastAttachmentID=>'0',RedmineLastSyncAt=>'0');
    for my $id (@ids) {
        for my $name (keys %values) {
            sql('INSERT INTO dynamic_field_value (field_id,object_id,value_text) VALUES (?,?,?)',$Fixture->{field_ids}{$name},$id,$values{$name});
        }
    }
    # Collect validation metadata in this separate preparation process, so the
    # measured worker does not prewarm all TicketGet caches via ArticleList.
    my @validation_ids=$scenario eq 'unchanged' ? @{$Fixture->{poll}}
        : is_outbound() ? ($Fixture->{outgoing}) : @{$Fixture->{incoming}};
    my %baseline_articles;
    for my $id (@validation_ids) {
        $baseline_articles{$id}={map {$_->{ArticleID}=>1} $Article->ArticleList(TicketID=>$id)};
    }
    $Fixture->{baseline_articles}=\%baseline_articles;
    write_fixture($Fixture);
    # Ensure both versions see the same fresh cache state and traversal start.
    $Cache->CleanUp();
    print "{\"prepared\":true}\n";exit;
}
die 'unknown operation' if $operation ne 'run';
my @ids=$scenario eq 'unchanged' ? @{$Fixture->{poll}} : is_outbound() ? ($Fixture->{outgoing}) : @{$Fixture->{incoming}};
my %before_articles=%{$Fixture->{baseline_articles}};
my $q0=session_queries();my @r0=getrusage();my $t0=time();
DB::enable_profile() if $ENV{BRIDGE_PROFILE};
my %result;
if (is_outbound()) {
    %result=$Bridge->EscalateTicket(TicketID=>$Fixture->{outgoing},UserID=>1,ProjectID=>1,TrackerID=>2,
        PriorityID=>2,AssignedToID=>2,DueDate=>'2026-12-01',Subject=>'Benchmark create',Description=>'Fixed description',
        IncludeAttachments=>$scenario eq 'extra'?0:1,FormID=>$scenario eq 'extra'?$Fixture->{extra_form}:undef);
} else { $Bridge->CronSync();%result=(Success=>1); }
if ($ENV{BRIDGE_PROFILE}) { DB::disable_profile(); DB::finish_profile(); }
my $elapsed=time()-$t0;my @r1=getrusage();my $q1=session_queries();
my %checks=(operation_success=>$result{Success}?1:0);
my $notes=0;my $files=0;
for my $id (@ids) {
    my %ticket=$Ticket->TicketGet(TicketID=>$id,DynamicFields=>1,UserID=>1);
    die 'Created issue link missing in OTRS' if is_outbound() && ($ticket{DynamicField_RedmineID}||0)!=900;
    for my $meta ($Article->ArticleList(TicketID=>$id)) {
        next if $before_articles{$id}{$meta->{ArticleID}};
        $notes++;
        next if is_outbound();
        my $backend=$Article->BackendForArticle(%$meta);
        my %note=$backend->ArticleGet(TicketID=>$id,ArticleID=>$meta->{ArticleID});
        die 'Transition comment missing' if ($note{Body}||'')!~/Controlled status transition/;
        $checks{comment_present}=1;
        my %index=$backend->ArticleAttachmentIndex(ArticleID=>$meta->{ArticleID},UserID=>1,ExcludePlainText=>1,ExcludeHTMLBody=>1);
        for my $fid (keys %index) {
            my %file=$backend->ArticleAttachment(ArticleID=>$meta->{ArticleID},FileID=>$fid,UserID=>1);
            my $bytes=$file{Content};$bytes=$$bytes if ref $bytes eq 'SCALAR';
            my $expected=$scenario eq 'binary'?"\x00\xff\x80A":('R'x(1024*1024));
            die 'Attachment bytes differ' if sha256_hex($bytes) ne sha256_hex($expected);$files++;
        }
    }
    if ($scenario eq 'inbound' || $scenario eq 'binary') {
        die 'Status not applied' if ($ticket{State}||'') ne 'open';
        die 'Journal cursor wrong' if ($ticket{DynamicField_RedmineLastJournalID}||0)!=11;
    }
}
$checks{new_notes}=$notes;$checks{stored_attachments}=$files;
if($scenario eq 'unchanged') {
    die 'Unexpected note' if $notes;
    die 'CronSync health failure' if !$Cache->Get(Type=>'RedmineBridgeHealth',Key=>'LastSyncOK');
    $checks{processed_tickets}=$Cache->Get(Type=>'RedmineBridgeHealth',Key=>'SyncedCount');
}
if($scenario eq 'inbound' || $scenario eq 'binary') {
    die 'Missing sibling notes' if $notes!=10;
    die 'Missing incoming attachments' if $files!=($scenario eq 'binary'?10:20);
}
die 'Operation failed' if !$checks{operation_success};
print $JSON->encode({variant=>$variant,scenario=>$scenario,wall_seconds=>$elapsed,
    cpu_user_seconds=>$r1[0]-$r0[0],cpu_system_seconds=>$r1[1]-$r0[1],
    peak_rss_kib=>$r1[2],startup_peak_rss_kib=>$r0[2],sql_queries=>$q1-$q0-1,
    loaded_sync=>$INC{'Kernel/System/Redmine/Sync.pm'},
    variable_check=>$INC{'Kernel/System/VariableCheck.pm'},checks=>\%checks}),"\n";
