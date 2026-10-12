# Real OTRS audit. Experimental changes exist only as process-local wrappers.
use strict;
use warnings;
use utf8;
use lib '/opt/otrs', '/opt/otrs/Kernel/cpan-lib';
use Kernel::System::ObjectManager;
use JSON::PP;
use BSD::Resource qw(getrusage);
use Time::HiRes qw(time);
$|=1;
my ($action,$scenario,$variant,$run_mode)=@ARGV;
local $Kernel::OM=Kernel::System::ObjectManager->new();
my $Config=$Kernel::OM->Get('Kernel::Config');
my %settings=('Redmine::Enabled'=>1,'Redmine::InboundSync'=>1,'Redmine::AutoRetry'=>0,
'Redmine::BaseURL'=>'http://redmine:8080','Redmine::APIKey'=>'local-sync-audit-only',
'Redmine::ProjectID'=>1,'Redmine::TrackerID'=>2,'Redmine::SyncBatchLimit'=>50,
'Redmine::SyncAttachments'=>1,'Redmine::StatusSync'=>{'Проверка решения'=>'open|note'},
'Redmine::MaxAttachmentBytes'=>5000000,'Redmine::MaxAttachmentTotalBytes'=>20000000,
'Redmine::MaxAttachmentCount'=>20,'Redmine::NotifyOnStatusNote'=>0,
'Redmine::FormLoadAllProjects'=>0,'SendmailModule'=>'Kernel::System::Email::DoNotSendEmail');
$Config->Set(Key=>$_,Value=>$settings{$_}) for keys %settings;
my $Bridge=$Kernel::OM->Get('Kernel::System::Redmine');
my $Ticket=$Kernel::OM->Get('Kernel::System::Ticket');
my $DB=$Kernel::OM->Get('Kernel::System::DB');
my $Cache=$Kernel::OM->Get('Kernel::System::Cache');
$Cache->Configure(CacheInMemory=>0,CacheInBackend=>1) if ($run_mode||'') eq 'daemon_task';
my $JSON=JSON::PP->new->canonical;
my $path='/opt/otrs/var/tmp/bridge-benchmark.json';
open my $in,'<',$path or die $!;my $Fixture=do{local $/;$JSON->decode(<$in>)};close $in;
sub save_fixture {open my $out,'>',$path or die $!;print {$out} $JSON->encode($Fixture);close $out}
sub sql {my($query,@bind)=@_;my @refs=map{\$_}@bind;$DB->Do(SQL=>$query,Bind=>\@refs)or die 'Audit fixture SQL failed'}
if($action eq 'grow'){
  my @ids=@{$Fixture->{audit_poll}||$Fixture->{poll}};
  while(@ids<1000){
    my $id=$Ticket->TicketCreate(Title=>'Synthetic mass incident audit '.(@ids+1),Queue=>'Raw',Lock=>'unlock',Priority=>'3 normal',State=>'open',CustomerID=>'bridge-benchmark',CustomerUser=>'benchmark@example.invalid',OwnerID=>1,UserID=>1)or die 'Audit ticket create failed';
    push @ids,$id;
    if(@ids%100==0){$Fixture->{audit_poll}=\@ids;save_fixture();print 'Created ',scalar(@ids)," synthetic audit tickets\n";}
  }
  $Fixture->{audit_poll}=\@ids;save_fixture();$Cache->CleanUp();print "{\"synthetic_tickets\":1000}\n";exit;
}
my @ids=@{$Fixture->{audit_poll}};
if($scenario=~/_(\d+)\z/){splice @ids,$1 if @ids>$1;}
@ids=() if $scenario eq 'empty';
if($action eq 'prepare'){
  my $all=join ',',map{int $_}@{$Fixture->{audit_poll}};
  my $fields=join ',',map{int $_} values %{$Fixture->{field_ids}};
  sql("DELETE FROM dynamic_field_value WHERE object_id IN ($all) AND field_id IN ($fields)");
  if(@ids){
    my $objects=join ',',map{int $_}@ids;
    my %values=(RedmineID=>'7001',RedmineStatus=>'New',RedmineLastUpdatedOn=>'2026-01-01T00:00:00Z',RedmineLastAttachmentSyncOn=>'2026-01-01T00:00:00Z',RedmineLastJournalID=>'10',RedmineLastAttachmentID=>'0',RedmineLastSyncAt=>'0');
    for my $name(keys %values){
      my $expression=$name eq 'RedmineID'&&$scenario=~/unique/?'CAST(id + 7000 AS CHAR)':'?';
      my @bind=($Fixture->{field_ids}{$name});push @bind,$values{$name} if $expression eq '?';
      sql("INSERT INTO dynamic_field_value (field_id,object_id,value_text) SELECT ?,id,$expression FROM ticket WHERE id IN ($objects)",@bind);
    }
  }
  $Cache->CleanUp();print $JSON->encode({prepared=>scalar(@ids)}),"\n";exit;
}
die 'Invalid audit action' if $action ne 'run';
$variant||='current';
if($variant eq 'skip_unused_journals'){
  open my $codefile,'<','/opt/otrs/Kernel/System/Redmine/Sync.pm' or die $!;
  my $code=do{local $/;<$codefile>};close $codefile;
  $code=~s/use warnings;/use warnings; no warnings 'redefine';/;
  my $changed=($code=~s/(        my \$Notes = \$Journal->\{notes\})/        next JOURNAL if !\$WriteNote || !\$Self->_JournalHasStatusChange(\$Journal);\n$1/);
  die 'Prototype injection did not match current source' if $changed!=1;
  eval $code;die $@ if $@;
}
my %FailedDownloads;
my %count=(ticket_get=>0,history_add=>0,events=>{},field_sets=>{},sql_prepare=>0,sql_do=>0,sql_writes=>{},sql_templates=>{},html_to_ascii=>0,request_calls=>0);
sub wrap {
  my($name,$before)=@_;
  no strict 'refs';no warnings 'redefine';
  my $original=\&{$name};
  *{$name}=sub{$before->(@_);return $original->(@_)};
}
sub sql_count {
  my($method,$self,%p)=@_;$count{$method}++;
  my $sql=$p{SQL}||'';$sql=~s/\s+/ /g;$sql=~s/^\s+|\s+$//g;
  $sql=~s/'[^']*'/?/g;$sql=~s/\b\d+\b/?/g;
  $count{sql_templates}{$sql}++;
  $count{sql_writes}{uc($1).' '.lc($2)}++ if $sql=~/\A\s*(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+([a-z_]+)/i;
}
wrap('Kernel::System::Ticket::TicketGet',sub{$count{ticket_get}++});
wrap('Kernel::System::Ticket::HistoryAdd',sub{$count{history_add}++});
# EventHandler is inherited; install a wrapper in Ticket without replacing parent.
{
  no warnings 'redefine';
  my $orig=$Ticket->can('EventHandler');
  *Kernel::System::Ticket::EventHandler=sub{my($s,%p)=@_;$count{events}{$p{Event}||'?'}++;return $orig->(@_)};
}
wrap('Kernel::System::DB::Prepare',sub{sql_count('sql_prepare',@_)});
wrap('Kernel::System::DB::Do',sub{sql_count('sql_do',@_)});
{
  no warnings 'redefine';
  my $orig=$Bridge->can('_SetDF');
  *Kernel::System::Redmine::_SetDF=sub{
    my($s,%p)=@_;
    return 1 if $variant eq 'skip_check_timestamp' && $p{Name} eq 'RedmineLastSyncAt';
    $count{field_sets}{$p{Name}}++;return $orig->(@_);
  };
  my $request=$Bridge->can('_Request');
  *Kernel::System::Redmine::_Request=sub{
    my($s,%p)=@_;$count{request_calls}++;
    my $key=$p{Path}||'';
    return %{ $FailedDownloads{$key} } if $variant eq 'memoize_failed_download' && $FailedDownloads{$key};
    my %r=$request->(@_);
    $FailedDownloads{$key}={%r} if $variant eq 'memoize_failed_download' && $key=~m{^/attachments/download/} && ($r{HTTPCode}||0)==404;
    delete $r{Content} if $variant eq 'drop_json_copy' && ($p{ExpectJSON}//1) && $p{Path}=~m{^/issues/};
    return %r;
  };
}
# Warm modules outside timing without warming ticket or Redmine caches.
my $HTML=$Kernel::OM->Get('Kernel::System::HTMLUtils');
wrap('Kernel::System::HTMLUtils::ToAscii',sub{$count{html_to_ascii}++});
sub questions {$DB->Prepare(SQL=>"SHOW SESSION STATUS LIKE 'Questions'");my @r=$DB->FetchrowArray();return 0+$r[1]}
my $cycles=$scenario=~/1000/?20:1;
my $q0=questions();
%count=(ticket_get=>0,history_add=>0,events=>{},field_sets=>{},sql_prepare=>0,sql_do=>0,sql_writes=>{},sql_templates=>{},html_to_ascii=>0,request_calls=>0);
my @r0=getrusage();my $t0=time();
for(1..$cycles){
  %FailedDownloads=();
  if($variant eq 'scoped_http'){local $Bridge->{_RequestScope}={};$Bridge->CronSync();}
  else{$Bridge->CronSync();}
}
$Kernel::OM->ObjectEventsHandle() if ($run_mode||'') eq 'daemon_task';
my $wall=time()-$t0;my @r1=getrusage();my $q1=questions();
my $health={map{$_=>$Cache->Get(Type=>'RedmineBridgeHealth',Key=>$_)}qw(SyncedCount LastSyncOK LastSyncError)};
my $objects=join ',',map{int $_}@ids;
my $notes=0;
if(@ids){$DB->Prepare(SQL=>"SELECT COUNT(*) FROM article WHERE ticket_id IN ($objects)");my @r=$DB->FetchrowArray();$notes=0+$r[0];}
my $templates=delete $count{sql_templates};
my @sql=map{{sql=>$_,count=>$templates->{$_}}}sort{$templates->{$b}<=>$templates->{$a}||$a cmp $b}keys %$templates;
print $JSON->encode({scenario=>$scenario,variant=>$variant,run_mode=>$run_mode||'method_only',cycles=>$cycles,cpu_seconds=>($r1[0]-$r0[0])+($r1[1]-$r0[1]),wall_seconds=>$wall,peak_rss_kib=>$r1[2],sql_queries=>$q1-$q0-1,articles_after=>$notes,count=>\%count,sql_templates=>\@sql,health=>$health,loaded_sync=>$INC{'Kernel/System/Redmine/Sync.pm'}}),"\n";
