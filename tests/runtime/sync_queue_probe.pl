use strict;use warnings;
use lib '/opt/otrs','/opt/otrs/Kernel/cpan-lib';
use Kernel::System::ObjectManager;use JSON::PP;
{
  package Local::SyncAuditFailure;
  our @ObjectDependencies=();
  sub new {my($type)=@_;return bless {},$type}
  sub Fail {$main::BusinessCalled=1;return (Success=>0,Error=>'Controlled business failure')}
}
$INC{'Local/SyncAuditFailure.pm'}=__FILE__;
local $Kernel::OM=Kernel::System::ObjectManager->new();
my $Scheduler=$Kernel::OM->Get('Kernel::System::Scheduler');
my $DB=$Kernel::OM->Get('Kernel::System::DB');
my $name='LocalSyncAuditContinuation';
my %task=(Type=>'AsynchronousExecutor',Name=>$name,MaximumParallelInstances=>1,Data=>{Object=>'Local::SyncAuditFailure',Function=>'Fail',Params=>{}});
my $first=$Scheduler->TaskAdd(%task);my $second=$Scheduler->TaskAdd(%task);
$DB->Prepare(SQL=>'SELECT id FROM scheduler_task WHERE name = ?',Bind=>[\$name])or die 'Queue inspection failed';
my @ids;while(my @r=$DB->FetchrowArray()){push @ids,$r[0]}
our $BusinessCalled=0;
my $Worker=$Kernel::OM->Get('Kernel::System::Daemon::DaemonModules::SchedulerTaskWorker::AsynchronousExecutor');
my $handled=$Worker->Run(TaskID=>$ids[0],TaskName=>$name,Data=>$task{Data});
print JSON::PP->new->canonical->encode({first_add_return=>$first,second_add_return=>$second,actual_queue_rows=>scalar(@ids),business_function_called=>$BusinessCalled,business_function_success=>0,executor_return=>$handled}),"\n";
