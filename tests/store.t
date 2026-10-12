use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
use Test::More;
use StoreTest qw(store_fixture);

sub observed {
    my ($Store,%Extra)=@_;
    return $Store->Observe(SourceKey=>'source',IssueID=>7,UpdatedOn=>'2026-10-12T01:00:00Z',Status=>'Open',LinksHash=>'links',Now=>100,%Extra);
}

subtest 'durable observations and zero-write unchanged polling' => sub {
    my ($S,$DB,$DML)=store_fixture();
    my $Row=observed($S->[0]);
    is($Row->{generation},1,'first version pending');
    is($Row->{done_generation},0,'not acknowledged');
    my $Before=$$DML;
    is(observed($S->[0],Now=>101)->{key},$Row->{key},'same durable key');
    is($$DML,$Before,'unchanged observation has zero DML');
    is($S->[1]->GetIssue(SourceKey=>'source',IssueID=>7)->{observed_at},100,'visible on independent connection');
    is(scalar @{$S->[0]->ListIssues(SourceKey=>'source')},1,'source issue list');
    isnt($S->[0]->SourceKey(BaseURL=>'https://redmine',APIKey=>'a'),$S->[0]->SourceKey(BaseURL=>'https://redmine',APIKey=>'b'),'credential/source isolation');
};

subtest 'exclusive issue leases, progress, failure, recovery and acknowledgement' => sub {
    my ($S)=store_fixture(); my $Row=observed($S->[0]); my $Key=$Row->{key};
    my $Claim=$S->[0]->Claim(IssueKey=>$Key,Now=>100,LeaseSeconds=>10);
    ok($Claim->{lease_token},'lease token issued');
    ok(!$S->[1]->Claim(IssueKey=>$Key,Now=>101),'second connection cannot claim');
    ok($S->[0]->Progress(IssueKey=>$Key,Token=>$Claim->{lease_token},RoundGeneration=>1,AfterTicketID=>500,Now=>101),'checkpoint');
    ok($S->[0]->Fail(IssueKey=>$Key,Token=>$Claim->{lease_token},RoundGeneration=>1,Error=>'temporary',RetryAfterSeconds=>1,Now=>102),'failure retained');
    my $Failed=$S->[1]->GetIssue(SourceKey=>'source',IssueID=>7);
    is($Failed->{after_ticket_id},500,'failure preserves cursor');
    is($Failed->{retry_at},104,'minimum retry delay');
    is($Failed->{done_generation},0,'failure never acknowledges work');
    ok(!$S->[1]->Claim(IssueKey=>$Key,Now=>103),'retry delay respected');
    my $Retry=$S->[1]->Claim(IssueKey=>$Key,Now=>104,LeaseSeconds=>10);
    ok($Retry,'retry can claim');
    ok(!$S->[0]->Progress(IssueKey=>$Key,Token=>$Claim->{lease_token},RoundGeneration=>1,AfterTicketID=>700,Now=>105),'old token fenced');
    my $Recover=$S->[0]->Claim(IssueKey=>$Key,Now=>114);
    ok($Recover,'expired lease reclaimed');
    ok($S->[0]->Release(IssueKey=>$Key,Token=>$Recover->{lease_token},RoundGeneration=>1,AfterTicketID=>1000,Done=>1,Now=>115),'complete generation');
    my $Done=$S->[0]->GetIssue(SourceKey=>'source',IssueID=>7);
    is($Done->{done_generation},1,'completion recorded');
    is($Done->{after_ticket_id},0,'completed cursor cleared');
    ok(!$S->[1]->Claim(IssueKey=>$Key,Now=>116),'completed generation cannot claim');
};

subtest 'new observations preserve owned round and old round tokens remain fenced' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $C=$S->[0]->Claim(IssueKey=>$R->{key},Now=>100);
    my $N=observed($S->[1],UpdatedOn=>'later',Now=>101);
    is($N->{generation},2,'new snapshot advances latest generation');
    ok($S->[0]->Progress(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,AfterTicketID=>500,Now=>102),'owned round progresses despite latest snapshot change');
    ok($S->[0]->Release(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,Done=>1,Now=>103),'old round completes without acknowledging latest version');
    my $Current=$S->[1]->Claim(IssueKey=>$R->{key},Now=>104);
    is($Current->{round_generation},2,'next owner starts catch-up round');
    $S->[1]->Progress(IssueKey=>$R->{key},Token=>$Current->{lease_token},RoundGeneration=>2,AfterTicketID=>20,Now=>105);
    ok(!$S->[0]->Fail(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,Error=>'late failure',Now=>106),'old round token cannot fail new round');
    is($S->[0]->GetIssue(SourceKey=>'source',IssueID=>7)->{after_ticket_id},20,'old round cannot erase new progress');
};

subtest 'outbox queue loss recovery and signature changes' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $Key=$R->{key};
    is(scalar @{$S->[0]->ReadyIssues(SourceKey=>'source',Now=>100)},1,'pending issue ready');
    ok($S->[0]->MarkQueued(IssueKey=>$Key,Now=>100),'queued once');
    ok(!$S->[1]->MarkQueued(IssueKey=>$Key,Now=>101),'duplicate enqueue fenced');
    is(scalar @{$S->[0]->ReadyIssues(SourceKey=>'source',Now=>129)},0,'queued task given grace period');
    is(scalar @{$S->[1]->ReadyIssues(SourceKey=>'source',Now=>130)},1,'lost task returns after grace');
    my $C=$S->[0]->Claim(IssueKey=>$Key,Now=>130);
    ok($S->[0]->CaptureSignature(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,Signature=>'sig-one',Now=>130),'first fingerprint captured');
    $S->[0]->Progress(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,AfterTicketID=>200,Now=>131);
    ok($S->[0]->CaptureSignature(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,Signature=>'sig-two',Now=>132),'mid-fanout change preserves owned captured delivery');
    my $N=$S->[1]->GetIssue(SourceKey=>'source',IssueID=>7);
    is($N->{generation},2,'signature change starts next generation');
    is($N->{after_ticket_id},200,'signature change preserves current fanout cursor');
    is($N->{delivery_signature},'sig-two','new fingerprint retained');
    is($N->{lease_token},$C->{lease_token},'changed signature keeps current round lease');
    $S->[0]->Release(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,Done=>1,Now=>133);
    my $Next=$S->[1]->Claim(IssueKey=>$Key,Now=>134);
    $S->[1]->Release(IssueKey=>$Key,Token=>$Next->{lease_token},RoundGeneration=>2,Done=>1,Now=>135);
    $S->[0]->MarkProbe(IssueKey=>$Key,Now=>200);
    is($S->[0]->GetIssue(SourceKey=>'source',IssueID=>7)->{probe_at},200,'idle probe recorded');
    my $Before=$S->[0]->GetIssue(SourceKey=>'source',IssueID=>7)->{generation};
    $S->[0]->ObserveSignature(IssueKey=>$Key,Signature=>'sig-two',Now=>201);
    is($S->[0]->GetIssue(SourceKey=>'source',IssueID=>7)->{generation},$Before,'same signature creates no work');
    $S->[0]->ObserveSignature(IssueKey=>$Key,Signature=>'sig-three',Now=>202);
    is($S->[0]->GetIssue(SourceKey=>'source',IssueID=>7)->{generation},3,'silent upstream changes retained');
};

subtest 'database lock CAS, expiry, token ownership and ticket transaction fence' => sub {
    my ($S,$DB)=store_fixture();
    my $Token=$S->[0]->LockAcquire(Key=>'cron',Now=>time(),LeaseSeconds=>10);
    ok($Token,'new lock acquired');
    ok(!$S->[1]->LockAcquire(Key=>'cron',Now=>time()),'independent connection cannot own same lock');
    ok($S->[0]->LockValid(Key=>'cron',Token=>$Token),'owner valid');
    ok(!$S->[1]->LockRelease(Key=>'cron',Token=>'other'),'wrong owner cannot release');
    my $Handle=$S->[0]->BeginTransaction(LockKey=>'cron',Token=>$Token);
    ok($Handle,'transaction begins with valid database lease');
    ok(!$Handle->{AutoCommit},'real DBI transaction');
    ok(!$S->[0]->BeginTransaction(LockKey=>'cron',Token=>$Token),'nested transaction rejected');
    ok(!$Handle->{AutoCommit},'nested rejection preserves existing transaction');
    $Handle->rollback();
    ok(!$S->[1]->BeginTransaction(LockKey=>'cron',Token=>'other'),'invalid token rolls back');
    ok($DB->[1]{AutoCommit},'invalid lease leaves no transaction open');
    ok($S->[0]->LockRelease(Key=>'cron',Token=>$Token),'owner releases');
    my $Old=$S->[0]->LockAcquire(Key=>'expire',Now=>100,LeaseSeconds=>5);
    my $New=$S->[1]->LockAcquire(Key=>'expire',Now=>105,LeaseSeconds=>5);
    ok($New && $New ne $Old,'expired lock gets new token');
    ok(!$S->[0]->LockRelease(Key=>'expire',Token=>$Old),'old token cannot release successor');
};
subtest 'Unicode source isolation, changed tuple reset and bounded readiness for 1000 issues' => sub {
    my ($S,$DB,$DML)=store_fixture();
    my $Row=observed($S->[0],Status=>'Проверка решения');
    is($S->[1]->GetIssue(SourceKey=>'source',IssueID=>7)->{issue_status},'Проверка решения','Unicode survives DBI round trip');
    my $Claim=$S->[0]->Claim(IssueKey=>$Row->{key},Now=>100);
    $S->[0]->CaptureSignature(IssueKey=>$Row->{key},Token=>$Claim->{lease_token},RoundGeneration=>1,Signature=>'old',Now=>101);
    $S->[0]->Progress(IssueKey=>$Row->{key},Token=>$Claim->{lease_token},RoundGeneration=>1,AfterTicketID=>500,Now=>102);
    my $Next=observed($S->[1],LinksHash=>'new-links',Status=>'Проверка решения',Now=>103);
    is($Next->{generation},2,'link set change creates durable work');
    is($Next->{after_ticket_id},500,'new pending version preserves current round cursor');
    is($Next->{delivery_signature},'','new snapshot clears previous fingerprint');
    is($Next->{lease_token},$Claim->{lease_token},'old worker retained only to release own lease');
    my $Before=$$DML;
    observed($S->[0],LinksHash=>'new-links',Status=>'Проверка решения',Existing=>$Next,Now=>104);
    is($$DML,$Before,'unchanged Existing snapshot writes nothing');
    my $Other=observed($S->[0],SourceKey=>'other-source');
    isnt($Other->{key},$Row->{key},'same issue ID isolated by source');
    is(scalar @{$S->[0]->ListIssues(SourceKey=>'other-source')},1,'source list contains only source members');
    for (1..1000) {
        $S->[0]->Observe(SourceKey=>'bulk',IssueID=>$_,UpdatedOn=>'one',Status=>'Open',LinksHash=>'links',Now=>100);
    }
    is(scalar @{$S->[0]->ListIssues(SourceKey=>'bulk')},1000,'1000 durable issues supported');
    is(scalar @{$S->[0]->ReadyIssues(SourceKey=>'bulk',Now=>100)},2,'default enqueue batch bounded');
    is(scalar @{$S->[0]->ReadyIssues(SourceKey=>'bulk',Limit=>10,Now=>100)},10,'explicit enqueue batch bounded');
    is(scalar @{$S->[0]->ListIssues(SourceKey=>'bulk',IssueIDs=>[1..1001])},1000,'active ID filtering chunks beyond Oracle IN limit');
    is($S->[0]->RetireMissing(SourceKey=>'bulk',IssueIDs=>[1..1001]),0,'large active projection retains all current rows');
};

subtest 'ticket side effect and checkpoint rollback on the same transaction' => sub {
    my ($S,$DB)=store_fixture();
    $DB->[0]->do('CREATE TABLE ticket_effect (ticket_id INTEGER PRIMARY KEY, note VARCHAR(100))');
    my $Now=time();
    my $Row=observed($S->[0],Now=>$Now);
    my $Issue=$S->[0]->Claim(IssueKey=>$Row->{key},Now=>$Now);
    my $Token=$S->[0]->LockAcquire(Key=>'ticket:42',Now=>$Now);
    my $Handle=$S->[0]->BeginTransaction(LockKey=>'ticket:42',Token=>$Token,Now=>$Now);
    $Handle->do("INSERT INTO ticket_effect (ticket_id,note) VALUES (42,'note')");
    ok($S->[0]->Progress(IssueKey=>$Row->{key},Token=>$Issue->{lease_token},RoundGeneration=>1,AfterTicketID=>42,Now=>$Now),'checkpoint shares connection');
    $Handle->rollback();
    is($DB->[1]->selectrow_array('SELECT count(*) FROM ticket_effect'),0,'ticket write rolled back');
    is($S->[1]->GetIssue(SourceKey=>'source',IssueID=>7)->{after_ticket_id},0,'checkpoint rolled back atomically');
    my $Committed=$S->[0]->BeginTransaction(LockKey=>'ticket:42',Token=>$Token,Now=>$Now);
    $Committed->do("INSERT INTO ticket_effect (ticket_id,note) VALUES (42,'note')");
    $S->[0]->Progress(IssueKey=>$Row->{key},Token=>$Issue->{lease_token},RoundGeneration=>1,AfterTicketID=>42,Now=>$Now);
    $Committed->commit();
    is($DB->[1]->selectrow_array('SELECT count(*) FROM ticket_effect'),1,'ticket write committed');
    is($S->[1]->GetIssue(SourceKey=>'source',IssueID=>7)->{after_ticket_id},42,'checkpoint committed atomically');
};

subtest 'lease renewal respects owner and expiry' => sub {
    my ($S)=store_fixture();
    my $R=observed($S->[0]); my $C=$S->[0]->Claim(IssueKey=>$R->{key},Now=>100,LeaseSeconds=>5);
    ok($S->[0]->RenewIssueLease(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,Now=>104,LeaseSeconds=>5),'owned live issue lease renewed');
    ok(!$S->[1]->Claim(IssueKey=>$R->{key},Now=>105),'renewed issue lease remains exclusive');
    ok(!$S->[0]->RenewIssueLease(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,Now=>109),'expired issue lease cannot be renewed');
    ok(!$S->[0]->Release(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,Done=>1,Now=>109),'expired worker cannot acknowledge issue');
    my $L=$S->[0]->LockAcquire(Key=>'renew',Now=>100,LeaseSeconds=>5);
    ok(!$S->[1]->RenewLock(Key=>'renew',Token=>'wrong',Now=>101),'wrong lock owner fenced');
    ok($S->[0]->RenewLock(Key=>'renew',Token=>$L,Now=>104,LeaseSeconds=>5),'owned live ticket lease renewed');
    ok(!$S->[1]->LockAcquire(Key=>'renew',Now=>105),'renewed ticket lease exclusive');
    ok(!$S->[0]->RenewLock(Key=>'renew',Token=>$L,Now=>109),'expired ticket lease cannot be renewed');
    ok(!$S->[0]->BeginTransaction(LockKey=>'renew',Token=>$L,Now=>109),'expired lock cannot begin ticket transaction');
};

subtest 'simultaneous independent workers race safely on initial insert and claim' => sub {
    my ($S,$DB,undef,$Dir)=store_fixture();
    require POSIX;
    pipe(my $StartRead,my $StartWrite) or die $!;
    pipe(my $ResultRead,my $ResultWrite) or die $!;
    my @Children;
    for (1..4) {
        my $PID=fork(); die 'fork failed' if !defined $PID;
        if (!$PID) {
            close $StartWrite; close $ResultRead;
            my $Byte; sysread($StartRead,$Byte,1);
            my $Result=eval {
                my $Handle=DBI->connect("dbi:SQLite:dbname=$Dir/store.sqlite",'','',
                    {RaiseError=>1,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
                $Handle->sqlite_busy_timeout(5000);
                my $Store=Kernel::System::Redmine::SyncStore->new(DBObject=>bless({dbh=>$Handle,Backend=>bless({},'StoreTest::Backend')},'StoreTest::DB'));
                my $Row=observed($Store);
                my $Lock=$Store->LockAcquire(Key=>'simultaneous',Now=>100);
                my $Issue=$Store->Claim(IssueKey=>$Row->{key},Now=>100);
                join(' ', $Row->{generation}, $Lock ? 1 : 0, $Issue ? 1 : 0);
            };
            $Result='ERROR '.$@ if $@;
            syswrite($ResultWrite,$Result."\n");
            POSIX::_exit(0);
        }
        push @Children,$PID;
    }
    close $StartRead; close $ResultWrite;
    syswrite($StartWrite,'xxxx'); close $StartWrite;
    my @Results=<$ResultRead>; close $ResultRead;
    waitpid($_,0) for @Children;
    is(scalar @Results,4,'all independent worker processes finished');
    my @Values=map { [/^(\d+) (\d+) (\d+)$/] } @Results;
    is(scalar(grep { @$_==3 && $_->[0]==1 } @Values),4,'duplicate initial observations converge on generation one');
    is(scalar(grep { @$_==3 && $_->[1] } @Values),1,'exactly one global lock owner');
    is(scalar(grep { @$_==3 && $_->[2] } @Values),1,'exactly one durable issue lease owner');
    diag(join('',@Results)) if grep { /^ERROR/ } @Results;
};

subtest 'core backend octet preprocessing and decoded facade reads' => sub {
    my ($S,$DB,$DML)=store_fixture(OctetBackend=>1);
    my $R=observed($S->[0],Status=>'Проверка решения');
    is($S->[1]->GetIssue(IssueKey=>$R->{key})->{issue_status},'Проверка решения','core octet backend preserves Russian status');
    my $Before=$$DML;
    observed($S->[0],Status=>'Проверка решения',Now=>101);
    is($$DML,$Before,'decoded status equality prevents spurious generation writes');
    my $C=$S->[0]->Claim(IssueKey=>$R->{key},Now=>100);
    $S->[0]->Fail(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,Error=>'Ошибка сети',Now=>102);
    is($S->[1]->GetIssue(IssueKey=>$R->{key})->{last_error},'Ошибка сети','error text preserves core octet round trip');
    ok($S->[0]{DBObject}{Backend}{BindCalls}>0,'core preprocessing called for writes');
    ok($S->[1]{DBObject}{Backend}{SQLCalls}>0,'core SQL preprocessing called for reads');
    $S->[0]->ReadyIssues(SourceKey=>'source',Limit=>1,Now=>200);
    is($S->[0]{DBObject}{LastLimit},1,'bounded readiness delegates Limit to core Prepare');
};

subtest 'explicit HTTP retry window and monotonic progress' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]);
    my $C=$S->[0]->Claim(IssueKey=>$R->{key},Now=>100);
    ok($S->[0]->Progress(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,AfterTicketID=>500,Now=>101),'forward cursor accepted');
    ok(!$S->[0]->Progress(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,AfterTicketID=>200,Now=>102),'late callback cannot regress cursor');
    is($S->[0]->GetIssue(IssueKey=>$R->{key})->{after_ticket_id},500,'cursor remains monotonic');
    $S->[0]->Fail(IssueKey=>$R->{key},Token=>$C->{lease_token},RoundGeneration=>1,RetryAfterSeconds=>3600,Error=>'rate limit',Now=>103);
    is($S->[1]->GetIssue(IssueKey=>$R->{key})->{retry_at},3703,'HTTP Retry-After up to an hour respected');
};

subtest 'filtered durable projection and retired rows preserve relink semantics' => sub {
    my ($S)=store_fixture(); my $A=observed($S->[0],IssueID=>1); my $B=observed($S->[0],IssueID=>2);
    my $C=$S->[0]->Claim(IssueKey=>$B->{key},Now=>100);
    $S->[0]->Fail(IssueKey=>$B->{key},Token=>$C->{lease_token},RoundGeneration=>1,Error=>'removed issue failed',Now=>101);
    is_deeply([map { $_->{issue_id} } @{$S->[0]->ListIssues(SourceKey=>'source',IssueIDs=>[1])}],[1],'only active issue IDs selected');
    is_deeply($S->[0]->ListIssues(SourceKey=>'source',IssueIDs=>[]),[],'empty active set selects nothing');
    ok($S->[0]->RetireMissing(SourceKey=>'source',IssueIDs=>[1]),'inactive issue retired');
    ok(!$S->[0]->Fail(IssueKey=>$B->{key},Token=>$C->{lease_token},RoundGeneration=>1,Error=>'late removed error',Now=>102),'retired lease fences stale failure');
    my $Retired=$S->[1]->GetIssue(IssueKey=>$B->{key});
    is($Retired->{done_generation},$Retired->{generation},'removed work acknowledged');
    is($Retired->{last_error},'','removed error cleared');
    is($Retired->{links_hash},'','link signature cleared for future relink');
    is($Retired->{retry_at},0,'removed retry cleared');
    is(scalar @{$S->[0]->ReadyIssues(SourceKey=>'source',Now=>200)},1,'only active issue queued');
    my $Relink=observed($S->[0],IssueID=>2,Now=>201);
    is($Relink->{generation},2,'identical issue and links relink wakes new generation');
    $S->[0]->RetireMissing(SourceKey=>'source',IssueIDs=>[]);
    is(scalar @{$S->[0]->ReadyIssues(SourceKey=>'source',Now=>202)},0,'empty active projection retires all work');
    my $Valid=eval { $S->[0]->RetireMissing(SourceKey=>'source',IssueIDs=>['1) OR 1=1']);1 };
    ok(!$Valid,'interpolated ID projection rejects nonnumeric values');
};


subtest 'continuous updates cannot starve tail tickets and require front catch-up' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $Key=$R->{key};
    my (@Cursors,@Rounds,%Delivered);
    for my $Batch (1..20) {
        my $Now=100+$Batch*5;
        my $Claim=$S->[0]->Claim(IssueKey=>$Key,Now=>$Now);
        my $After=$Claim->{after_ticket_id}+50;
        $Delivered{$_}=$Claim->{generation} for $Claim->{after_ticket_id}+1 .. $After;
        $S->[0]->Progress(IssueKey=>$Key,Token=>$Claim->{lease_token},RoundGeneration=>$Claim->{round_generation},AfterTicketID=>$After,Now=>$Now);
        my $New=observed($S->[1],UpdatedOn=>"ordinary-comment-$Batch",Now=>$Now+1);
        push @Cursors,$New->{after_ticket_id}; push @Rounds,$New->{round_generation};
        $S->[0]->Release(IssueKey=>$Key,Token=>$Claim->{lease_token},RoundGeneration=>$Claim->{round_generation},AfterTicketID=>$After,Now=>$Now+1);
    }
    is_deeply(\@Cursors,[map {$_*50} 1..20],'current round advances through all 1000 despite an update every batch');
    is_deeply(\@Rounds,[(1)x20],'new versions retain original active round identity');
    is(scalar keys %Delivered,1000,'tail tickets receive delivery in bounded 20 batches');
    my $Last=$S->[0]->Claim(IssueKey=>$Key,Now=>202);
    is($Last->{after_ticket_id},1000,'end of current round is durable');
    ok($S->[0]->Release(IssueKey=>$Key,Token=>$Last->{lease_token},RoundGeneration=>$Last->{round_generation},Done=>1,Now=>203),'current round closes');
    my $Catchup=$S->[1]->GetIssue(IssueKey=>$Key);
    is($Catchup->{done_generation},1,'completing old round never falsely acknowledges newest generation');
    is($Catchup->{round_generation},21,'next round targets newest observed generation');
    is($Catchup->{after_ticket_id},0,'mandatory catch-up starts at front');
    cmp_ok($Catchup->{generation},'>',$Catchup->{done_generation},'catch-up remains durably pending');
    my $Front=$S->[1]->Claim(IssueKey=>$Key,Now=>204);
    ok($Front,'next round can be claimed immediately');
    $S->[1]->Progress(IssueKey=>$Key,Token=>$Front->{lease_token},RoundGeneration=>$Front->{round_generation},AfterTicketID=>50,Now=>205);
    ok(!$S->[0]->Release(IssueKey=>$Key,Token=>$Last->{lease_token},RoundGeneration=>$Last->{round_generation},Done=>1,Now=>206),'old round token cannot finish new round');
    is($S->[1]->GetIssue(IssueKey=>$Key)->{after_ticket_id},50,'old round callback cannot erase catch-up progress');
    $Delivered{$_}=$Front->{generation} for 1..1000;
    $S->[1]->Progress(IssueKey=>$Key,Token=>$Front->{lease_token},RoundGeneration=>$Front->{round_generation},AfterTicketID=>1000,Now=>207);
    $S->[1]->Release(IssueKey=>$Key,Token=>$Front->{lease_token},RoundGeneration=>$Front->{round_generation},Done=>1,Now=>208);
    my $Done=$S->[0]->GetIssue(IssueKey=>$Key);
    is($Done->{done_generation},21,'stable newest round acknowledged only after full catch-up');
    is($Delivered{1},21,'front ticket catches latest version');
    is($Delivered{1000},21,'tail also retains newest version');
    ok(!$S->[0]->Claim(IssueKey=>$Key,Now=>209),'fully caught up issue stops scheduling');
};

subtest 'signature-only updates preserve current round then completed work starts fresh' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $Key=$R->{key};
    my $C=$S->[0]->Claim(IssueKey=>$Key,Now=>100);
    $S->[0]->Progress(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,AfterTicketID=>500,Now=>101);
    my $N=$S->[1]->ObserveSignature(IssueKey=>$Key,Signature=>'new-details',Now=>102);
    is($N->{after_ticket_id},500,'probe preserves current cursor');
    is($N->{round_generation},1,'probe preserves active round');
    ok($S->[0]->Release(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,Done=>1,Now=>103),'current round completes while new generation remains pending');
    my $Current=$S->[1]->Claim(IssueKey=>$Key,Now=>104);
    $S->[1]->Release(IssueKey=>$Key,Token=>$Current->{lease_token},RoundGeneration=>2,Done=>1,Now=>105);
    my $Fresh=observed($S->[0],UpdatedOn=>'after-completion',Now=>108);
    is($Fresh->{round_generation},3,'completed work starts fresh observed round');
    is($Fresh->{after_ticket_id},0,'fresh observed round starts at front');
    $S->[0]->RetireMissing(SourceKey=>'source',IssueIDs=>[]);
    my $Retired=$S->[1]->GetIssue(IssueKey=>$Key);
    is($Retired->{round_generation},$Retired->{generation},'retirement closes round identity');
};

subtest 'durable last-served fairness prevents hot issues starving quiet work' => sub {
    my ($S)=store_fixture();
    my %Rows=map { $_=>observed($S->[0],IssueID=>$_) } (7,8,9);
    my (@Claimed,%Cursors);
    $Cursors{7}=100000; $Cursors{8}=0;
    for my $Step (1..9) {
        my $Now=100+$Step;
        # Two hot issues keep changing and remain pending throughout.
        observed($S->[1],IssueID=>$_,UpdatedOn=>"hot-$_-$Step",Now=>$Now) for (7,8);
        my $Ready=$S->[0]->ReadyIssues(SourceKey=>'source',Limit=>1,Now=>$Now);
        my $Claim=$S->[0]->Claim(IssueKey=>$Ready->[0]{key},Now=>$Now);
        push @Claimed,$Claim->{issue_id};
        is($Claim->{served_at},$Now,'successful durable claim records last served time');
        if ($Claim->{issue_id}==9) {
            $S->[0]->Release(IssueKey=>$Claim->{key},Token=>$Claim->{lease_token},RoundGeneration=>$Claim->{round_generation},Done=>1,Now=>$Now);
        }
        else {
            my $ID=$Claim->{issue_id}; $Cursors{$ID}+=50;
            $S->[0]->Progress(IssueKey=>$Claim->{key},Token=>$Claim->{lease_token},RoundGeneration=>$Claim->{round_generation},AfterTicketID=>$Cursors{$ID},Now=>$Now);
            $S->[0]->Release(IssueKey=>$Claim->{key},Token=>$Claim->{lease_token},RoundGeneration=>$Claim->{round_generation},AfterTicketID=>$Cursors{$ID},Now=>$Now);
        }
    }
    is_deeply(\@Claimed,[7,8,9,7,8,7,8,7,8],'quiet third issue is served within three claims and hot issues alternate');
    my $A=$S->[0]->GetIssue(IssueKey=>$Rows{7}{key});
    my $B=$S->[0]->GetIssue(IssueKey=>$Rows{8}{key});
    cmp_ok($A->{after_ticket_id},'>',100000,'first hot issue has high independent ticket IDs');
    cmp_ok($B->{after_ticket_id},'<',1000,'second hot issue has low independent ticket IDs');
    my $Quiet=$S->[1]->GetIssue(IssueKey=>$Rows{9}{key});
    is($Quiet->{done_generation},$Quiet->{generation},'quiet work completes despite continuous hot issue updates');
    my $Current=$S->[0]->Claim(IssueKey=>$A->{key},Now=>200);
    ok(!$S->[1]->Claim(IssueKey=>$A->{key},Now=>201),'competing claim remains fenced');
    is($S->[1]->GetIssue(IssueKey=>$A->{key})->{served_at},200,'failed claim never moves durable fairness timestamp');
};

subtest 'eligible retries receive service ahead of recently served hot work' => sub {
    my ($S)=store_fixture();
    my $Hot=observed($S->[0],IssueID=>7); my $Quiet=observed($S->[0],IssueID=>8);
    my $Failed=$S->[0]->Claim(IssueKey=>$Quiet->{key},Now=>100);
    $S->[0]->Fail(IssueKey=>$Quiet->{key},Token=>$Failed->{lease_token},RoundGeneration=>1,Error=>'temporary',RetryAfterSeconds=>2,Now=>100);
    my $Busy=$S->[0]->Claim(IssueKey=>$Hot->{key},Now=>101);
    $S->[0]->Release(IssueKey=>$Hot->{key},Token=>$Busy->{lease_token},RoundGeneration=>1,AfterTicketID=>50,Now=>101);
    is($S->[0]->ReadyIssues(SourceKey=>'source',Limit=>1,Now=>101)->[0]{issue_id},7,'retry delay still controls eligibility');
    is($S->[0]->ReadyIssues(SourceKey=>'source',Limit=>1,Now=>102)->[0]{issue_id},8,'eligible retry with positive retry_at outranks recently served hot retry_at zero');
    my $Recovered=$S->[0]->Claim(IssueKey=>$Quiet->{key},Now=>102);
    ok($S->[0]->Release(IssueKey=>$Quiet->{key},Token=>$Recovered->{lease_token},RoundGeneration=>1,Done=>1,Now=>103),'quiet retry completes');
};

subtest 'slow owned ticket survives several latest-version changes' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $Key=$R->{key};
    my $C=$S->[0]->Claim(IssueKey=>$Key,Now=>100);
    for my $Now (105,110,115) {
        observed($S->[1],UpdatedOn=>"during-file-$Now",Now=>$Now);
    }
    ok($S->[0]->RenewIssueLease(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,Now=>116),'active round ownership renews after changes during slow file IO');
    ok($S->[0]->CaptureSignature(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,Signature=>'captured-details',Now=>117),'captured snapshot can finish in owned round');
    ok($S->[0]->CaptureSignature(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,Signature=>'next-captured-details',Now=>118),'different captured signature does not revoke active delivery');
    my $Updated=$S->[1]->GetIssue(IssueKey=>$Key);
    is($Updated->{generation},5,'new signature is independently retained as latest generation');
    is($Updated->{lease_token},$C->{lease_token},'slow worker keeps own round token');
    ok($S->[0]->Progress(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,AfterTicketID=>1,Now=>119),'slow ticket checkpoint succeeds after repeated source changes');
    ok(!$S->[0]->Progress(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>5,AfterTicketID=>2,Now=>120),'latest generation cannot impersonate active round');
    # A mismatched round must not keep an invalid lease alive. Reclaim the same
    # actual round after the previous invalid caller has released its own token.
    my $Valid=$S->[1]->Claim(IssueKey=>$Key,Now=>121);
    ok($S->[1]->Release(IssueKey=>$Key,Token=>$Valid->{lease_token},RoundGeneration=>1,Done=>1,Now=>122),'owned original round closes');
    my $Catchup=$S->[0]->GetIssue(IssueKey=>$Key);
    is($Catchup->{done_generation},1,'slow old round never acknowledges newest data');
    is($Catchup->{round_generation},5,'new data gets mandatory catch-up round');
    cmp_ok($Catchup->{generation},'>',$Catchup->{done_generation},'latest work survives original round completion');
};

subtest 'failed sibling does not block healthy delivery or falsely acknowledge round' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $Key=$R->{key};
    my $C=$S->[0]->Claim(IssueKey=>$Key,Now=>100);
    my %Work=(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1);
    ok($S->[0]->RecordTicketFailure(%Work,TicketID=>1,Error=>'file unavailable',Now=>101),'first sibling failure durably recorded without releasing lease');
    ok($S->[0]->Progress(%Work,AfterTicketID=>2,Now=>102),'healthy second sibling can commit after failed first');
    my $Scanned=$S->[1]->GetIssue(IssueKey=>$Key);
    is($Scanned->{after_ticket_id},2,'scan cursor passes failed sibling');
    is($Scanned->{first_failed_ticket_id},1,'earliest failed sibling retained');
    is($Scanned->{lease_token},$C->{lease_token},'same scan keeps its lease');
    is($Scanned->{retry_count},0,'per-ticket failure does not increment round retry count');
    ok($S->[0]->Release(%Work,Done=>1,Now=>103),'failed scan round releases cleanly');
    my $Waiting=$S->[1]->GetIssue(IssueKey=>$Key);
    is($Waiting->{done_generation},0,'healthy siblings never falsely acknowledge failed gap');
    is($Waiting->{round_generation},1,'failed round identity preserved');
    is($Waiting->{after_ticket_id},0,'full failed scan rewinds before earliest gap');
    is($Waiting->{first_failed_ticket_id},1,'gap marker survives retry wait');
    is($Waiting->{retry_at},105,'one exponential delay applied after full failed scan');
    is($Waiting->{retry_count},1,'one retry increment per failed full round');
    is($Waiting->{last_error},'file unavailable','error survives waiting');
    ok(!$S->[1]->Claim(IssueKey=>$Key,Now=>104),'rewound retry respects delay');
    my $Retry=$S->[1]->Claim(IssueKey=>$Key,Now=>105);
    is($Retry->{first_failed_ticket_id},0,'claim clears marker only at retry rewind');
    is($Retry->{last_error},'file unavailable','claim retains error until full success');
    is($Retry->{retry_count},1,'claim preserves retry history');
    $S->[1]->Progress(IssueKey=>$Key,Token=>$Retry->{lease_token},RoundGeneration=>1,AfterTicketID=>2,Now=>106);
    $S->[1]->Release(IssueKey=>$Key,Token=>$Retry->{lease_token},RoundGeneration=>1,Done=>1,Now=>107);
    my $Done=$S->[0]->GetIssue(IssueKey=>$Key);
    is($Done->{done_generation},1,'recovered full round can acknowledge');
    is($Done->{last_error},'','only successful full round clears error');
    is($Done->{retry_count},0,'successful full round clears retry count');
};

subtest 'crashed failure scan resumes past gap and rewinds durably at end' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $Key=$R->{key};
    my $C=$S->[0]->Claim(IssueKey=>$Key,Now=>100,LeaseSeconds=>10);
    $S->[0]->RecordTicketFailure(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,TicketID=>5,Error=>'gap five',Now=>101);
    $S->[0]->Progress(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,AfterTicketID=>10,Now=>102);
    my $Resume=$S->[1]->Claim(IssueKey=>$Key,Now=>110);
    is($Resume->{after_ticket_id},10,'crash resumes scan after committed healthy sibling');
    is($Resume->{first_failed_ticket_id},5,'past-gap claim preserves unresolved marker');
    $S->[1]->Progress(IssueKey=>$Key,Token=>$Resume->{lease_token},RoundGeneration=>1,AfterTicketID=>20,Now=>111);
    $S->[1]->Release(IssueKey=>$Key,Token=>$Resume->{lease_token},RoundGeneration=>1,Done=>1,Now=>112);
    my $Waiting=$S->[0]->GetIssue(IssueKey=>$Key);
    is($Waiting->{after_ticket_id},4,'crash-resumed full scan rewinds to gap minus one');
    is($Waiting->{retry_at},114,'resumed full scan gets retry delay');
    my $Retry=$S->[0]->Claim(IssueKey=>$Key,Now=>114);
    $S->[0]->RecordTicketFailure(IssueKey=>$Key,Token=>$Retry->{lease_token},RoundGeneration=>1,TicketID=>6,Error=>'gap six',Now=>115);
    $S->[0]->RecordTicketFailure(IssueKey=>$Key,Token=>$Retry->{lease_token},RoundGeneration=>1,TicketID=>5,Error=>'late gap five',Now=>116);
    my $Late=$S->[1]->GetIssue(IssueKey=>$Key);
    is($Late->{after_ticket_id},6,'late lower failure never regresses scan cursor');
    is($Late->{first_failed_ticket_id},5,'late lower failure retains earliest gap');
    $S->[0]->Release(IssueKey=>$Key,Token=>$Retry->{lease_token},RoundGeneration=>1,Done=>1,Now=>117);
    is($S->[1]->GetIssue(IssueKey=>$Key)->{retry_count},2,'second failed full round increments once');
    is($S->[1]->GetIssue(IssueKey=>$Key)->{retry_at},121,'second failed full round doubles delay');
};

subtest 'future header delay allows healthy scan continuation and protects retry rewind' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $Key=$R->{key};
    my $C=$S->[0]->Claim(IssueKey=>$Key,Now=>100);
    my %Work=(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1);
    ok(!$S->[0]->RecordTicketFailure(%Work,Token=>'other',TicketID=>1,Error=>'wrong owner',Now=>101),'wrong token cannot mark a gap');
    ok(!$S->[0]->RecordTicketFailure(%Work,RoundGeneration=>2,TicketID=>1,Error=>'wrong round',Now=>101),'wrong round cannot mark a gap');
    $S->[0]->RecordTicketFailure(%Work,TicketID=>1,Error=>'rate limit',RetryAfterSeconds=>9999,Now=>101);
    $S->[0]->Release(%Work,AfterTicketID=>1,Now=>102);
    is($S->[1]->ReadyIssues(SourceKey=>'source',Limit=>1,Now=>103)->[0]{key},$Key,'remaining healthy scan is ready despite header');
    ok($S->[1]->MarkQueued(IssueKey=>$Key,Now=>103),'partial failed scan can queue despite header');
    my $Next=$S->[1]->Claim(IssueKey=>$Key,Now=>104);
    is($Next->{first_failed_ticket_id},1,'partial continuation preserves failure marker');
    is($Next->{retry_at},3701,'header bound is retained while scanning');
    $S->[1]->RecordTicketFailure(IssueKey=>$Key,Token=>$Next->{lease_token},RoundGeneration=>1,TicketID=>2,Error=>'other gap',RetryAfterSeconds=>5,Now=>105);
    $S->[1]->Progress(IssueKey=>$Key,Token=>$Next->{lease_token},RoundGeneration=>1,AfterTicketID=>3,Now=>106);
    $S->[1]->Release(IssueKey=>$Key,Token=>$Next->{lease_token},RoundGeneration=>1,Done=>1,Now=>107);
    is($S->[0]->GetIssue(IssueKey=>$Key)->{retry_at},3701,'longest header survives smaller later header and exponential rewind');
    ok(!$S->[0]->Claim(IssueKey=>$Key,Now=>3700),'rewound retry waits for header');
    ok($S->[0]->Claim(IssueKey=>$Key,Now=>3701),'rewound retry wakes when header expires');
};

subtest 'new observations and signatures preserve unresolved delivery errors' => sub {
    my ($S)=store_fixture(); my $R=observed($S->[0]); my $Key=$R->{key};
    my $C=$S->[0]->Claim(IssueKey=>$Key,Now=>100);
    $S->[0]->RecordTicketFailure(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,TicketID=>1,Error=>'pending gap',Now=>101);
    $S->[0]->Release(IssueKey=>$Key,Token=>$C->{lease_token},RoundGeneration=>1,Done=>1,Now=>102);
    my $N=observed($S->[1],UpdatedOn=>'changed source',Now=>103);
    is($N->{last_error},'pending gap','changed source does not hide pending error');
    is($N->{retry_count},1,'changed source preserves retry count');
    $N=$S->[1]->ObserveSignature(IssueKey=>$Key,Signature=>'changed details',Now=>103);
    is($N->{last_error},'pending gap','probe does not hide pending error');
    is($N->{retry_count},1,'probe preserves retry count');
    my $Retry=$S->[0]->Claim(IssueKey=>$Key,Now=>103);
    $S->[0]->CaptureSignature(IssueKey=>$Key,Token=>$Retry->{lease_token},RoundGeneration=>1,Signature=>'captured different',Now=>104);
    is($S->[1]->GetIssue(IssueKey=>$Key)->{last_error},'pending gap','capturing healthy details does not clear unresolved delivery error');
    $S->[0]->RetireMissing(SourceKey=>'source',IssueIDs=>[]);
    is($S->[1]->GetIssue(IssueKey=>$Key)->{first_failed_ticket_id},0,'retirement clears failure marker');
};

done_testing;
