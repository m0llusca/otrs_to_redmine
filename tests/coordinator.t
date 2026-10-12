use strict;
use warnings;
use utf8;
use Test::More;
use lib '.', 'tests/lib';
use CoordinatorTest qw(coordinator_fixture coordinator_fair_fixture);

subtest 'detector reads projection, observes once and keeps work independent' => sub {
    my($B,$S,$W)=coordinator_fixture(count=>1001);
    ok($B->PollSync(),'poll succeeds');
    is(scalar @{$S->{requests}},1,'one list HTTP call for one linked issue');
    like($S->{requests}[0]{Path},qr/status_id=\*/,'closed issues included');
    ok($S->{requests}[0]{Scoped},'detector uses keepalive scope');
    is(scalar grep({$_->{Limit}&&$_->{Limit}==500} @{$S->{selects}}),3,'projection bounded in keyset pages');
    my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    is($Row->{generation},1,'new issue pending');
    my$Before=$$W;my$IssueWrites=$S->{issue_writes};
    $B->PollSync();
    is($$W-$Before,3,'unchanged pass only acquires/renews/releases distributed poll lock');
    is($S->{issue_writes},$IssueWrites,'unchanged pass performs no issue table writes');
    is(scalar @{$S->{processed}},0,'detector performs no ticket CRUD');
    $S->{dbh}->do('INSERT INTO ticket (id) VALUES (1002)');
    $S->{dbh}->do("INSERT INTO dynamic_field_value VALUES (1,1002,'7')");
    $B->PollSync();
    is($S->{store}->GetIssue(IssueKey=>$Row->{key})->{generation},2,'link changes enqueue a new generation');
};
subtest 'server pagination and unexpected issue protection' => sub {
    my($B,$S)=coordinator_fixture(count=>5,unique=>1);$S->{server_limit}=2;
    $B->PollSync();is(scalar @{$S->{requests}},3,'server smaller pages followed');
    $S->{foreign_issue}={id=>999,status=>{name=>'New'}};
    ok(!$B->PollSync(),'foreign issue rejected');
    ok(!$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>999),'foreign issue never observed');
};
subtest 'poll batch size, configuration fingerprint and global lock' => sub {
    my($B,$S)=coordinator_fixture(count=>101,unique=>1);
    $B->PollSync();is(scalar@{$S->{requests}},2,'HTTP batches contain at most 100 issue IDs');
    my$Source=$S->{store}->SourceKey();my$Row=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>1);
    $S->{settings}{'Redmine::SyncAttachments'}=0;$B->PollSync();
    is($S->{store}->GetIssue(IssueKey=>$Row->{key})->{generation},2,'settings change invalidates linked projection');
    my$Token=$S->{store}->LockAcquire(Key=>"poll:$Source",LeaseSeconds=>60,Now=>1000);
    my$Requests=@{$S->{requests}};ok($B->PollSync(),'competing poll safely skipped');
    is(scalar@{$S->{requests}},$Requests,'distributed poll lock prevents duplicate detector HTTP');
    $S->{store}->LockRelease(Key=>"poll:$Source",Token=>$Token);
};
subtest 'dispatch capacity includes running/queued task rows and CAS queues' => sub {
    my($B,$S)=coordinator_fixture(count=>5,unique=>1,settings=>{'Redmine::SyncWorkers'=>2});
    $B->PollSync();$B->DispatchSync();
    is(scalar @{$S->{tasks}},2,'bounded by available workers');
    $B->DispatchSync();is(scalar @{$S->{tasks}},2,'active scheduler tasks consume capacity');
    is($S->{tasks}[0]{Data}{Function},'ProcessSyncBatch','scheduler invokes worker batch');
};
subtest 'worker scans healthy siblings and retains a durable failed-ticket gap' => sub {
    my($B,$S)=coordinator_fixture();$B->PollSync();
    my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $S->{fail_ticket}=2;my$Failed=$B->ProcessSyncIssue(IssueKey=>$Row->{key});
    ok(!$Failed->{Success},'partial failure returned');is($Failed->{Processed},2,'failed attempt consumes slice budget');
    is($Failed->{Succeeded},1,'only successful ticket contributes to delivery count');
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});
    is($Row->{after_ticket_id},2,'scan cursor advances past durable gap');
    is($Row->{first_failed_ticket_id},2,'failed ticket is retained in durable ledger');
    is($Row->{retry_at},1033,'retry-after retained for eventual gap retry');
    $S->{processed}=[];my$Tail=$B->ProcessSyncIssue(IssueKey=>$Row->{key});
    ok($Tail->{Success},'healthy tail continues before retry deadline');
    is_deeply([map{$_->{TicketID}}@{$S->{processed}}],[3],'failure does not block later ticket');
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});is($Row->{after_ticket_id},1,'full scan rewinds to earliest failed ticket');
    is($B->ProcessSyncIssue(IssueKey=>$Row->{key})->{Processed},0,'gap backoff applies after full scan');
    $S->{now}=$Row->{retry_at}+1;delete$S->{fail_ticket};$S->{processed}=[];
    ok($B->ProcessSyncIssue(IssueKey=>$Row->{key})->{Success},'retry slice delivers saved gap');
    is_deeply([map{$_->{TicketID}}@{$S->{processed}}],[2,3],'gap retry begins at failed ticket');
    ok($S->{processed}[0]{ForceDetails},'forces journal details');
    is($S->{processed}[0]{ExpectedIssueID},7,'fences issue relink');
    ok(!exists$S->{processed}[0]{IssueCache}{Details}{Content},'raw HTTP content removed');
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});is($Row->{done_generation},$Row->{generation},'gap-free generation completed');
};
subtest 'delivery errors survive detector success, changed details preserve round progress' => sub {
    my($B,$S)=coordinator_fixture();$B->PollSync();my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $S->{fail_ticket}=1;$B->ProcessSyncIssue(IssueKey=>$Row->{key});$B->PollSync();
    is($S->{cache}{'RedmineBridgeHealth:LastSyncOK'},0,'poll does not hide delivery error');
    $S->{now}=1040;delete $S->{fail_ticket};$B->ProcessSyncIssue(IssueKey=>$Row->{key});
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});$S->{now}=$Row->{retry_at}+1;
    $B->ProcessSyncIssue(IssueKey=>$Row->{key});
    push @{$S->{issues}{7}{journals}},{id=>11};
    $B->ProcessSyncIssue(IssueKey=>$Row->{key});$Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});
    is($Row->{generation},2,'mid-fanout content signature creates new generation');is($Row->{after_ticket_id},0,'completed old round rewinds for new generation catchup');
    cmp_ok($Row->{done_generation},'<',$Row->{generation},'new snapshot remains pending after old round completes');
};
subtest 'missing list row preserves links and restoration retries' => sub {
    my($B,$S)=coordinator_fixture(count=>1);$B->PollSync();my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $B->ProcessSyncIssue(IssueKey=>$Row->{key});$S->{omitted}{7}=1;$B->PollSync();
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});is($Row->{generation},2,'omitted completed issue queued once');
    $B->PollSync();is($S->{store}->GetIssue(IssueKey=>$Row->{key})->{generation},2,'continued omission does not churn');
    delete $S->{omitted}{7};$B->PollSync();
    cmp_ok($S->{store}->GetIssue(IssueKey=>$Row->{key})->{generation},'>',2,'restored issue queued');
    is($S->{dbh}->selectrow_array('SELECT value_text FROM dynamic_field_value'),'7','link is preserved');
};
subtest 'detail probes are bounded and detect journals despite unchanged updated_on' => sub {
    my($B,$S)=coordinator_fixture(count=>4,unique=>1,settings=>{'Redmine::SyncBatchLimit'=>50});
    $B->PollSync();my@Rows=@{$S->{store}->ListIssues(SourceKey=>$S->{store}->SourceKey())};
    $B->ProcessSyncIssue(IssueKey=>$_->{key}) for @Rows;
    push @{$S->{issues}{1}{journals}},{id=>99};
    $S->{now}+=5;
    $S->{requests}=[];$B->PollSync();
    is(scalar @{$S->{requests}},3,'one list plus at most two detail probes');
    is($S->{store}->GetIssue(IssueKey=>$Rows[0]{key})->{generation},2,'journal-only change observed');
    $S->{requests}=[];$B->PollSync();
    is(scalar @{$S->{requests}},3,'next pass probes remaining issues');
    $S->{requests}=[];$B->PollSync();is(scalar @{$S->{requests}},1,'probe cooldown avoids repeated details');
};
subtest 'worker respects archive, source fencing, and generation replacement' => sub {
    my($B,$S)=coordinator_fixture(settings=>{'Ticket::ArchiveSystem'=>1});
    $S->{dbh}->do('UPDATE ticket SET archive_flag=1 WHERE id=2');$B->PollSync();
    my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $S->{on_ticket}=sub {my($P)=@_;$S->{store}->ObserveSignature(IssueKey=>$Row->{key},Signature=>'newer',Now=>1000) if $P->{TicketID}==1};
    ok($B->ProcessSyncIssue(IssueKey=>$Row->{key})->{Success},'active round continues despite a newer observation');
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});is($Row->{generation},2,'new generation retained');
    is($Row->{after_ticket_id},0,'stale worker cannot advance new cursor');
    is_deeply([map{$_->{TicketID}}@{$S->{processed}}],[1,3],'active round reaches archived-filtered late ticket');
    delete$S->{on_ticket};$S->{settings}{'Redmine::APIKey'}='different-source';$S->{requests}=[];
    $B->ProcessSyncIssue(IssueKey=>$Row->{key});is(scalar@{$S->{requests}},0,'old source performs no HTTP');
};
subtest 'scheduler failure recovers after queue grace and disabled daemon is safe' => sub {
    my($B,$S)=coordinator_fixture();$B->PollSync();$S->{fail_queue}=1;
    ok(!$B->DispatchSync(),'scheduler failure visible');delete$S->{fail_queue};
    $B->DispatchSync();is(scalar@{$S->{tasks}},0,'queued grace prevents duplicate immediate enqueue');
    $S->{now}+=31;$B->DispatchSync();is(scalar@{$S->{tasks}},1,'queue grace recovers failed enqueue');
    $S->{settings}{'Redmine::Enabled'}=0;my$N=@{$S->{requests}};
    ok($B->PollSync(),'disabled poll safe');is(scalar@{$S->{requests}},$N,'disabled poll no HTTP');
};
subtest 'slice deadline and atomic progress preserve resumable cursor' => sub {
    my($B,$S)=coordinator_fixture(count=>4,settings=>{'Redmine::SyncBatchLimit'=>4});
    $B->PollSync();my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $S->{on_ticket}=sub {my($P)=@_;$S->{now}+=11};
    ok($B->ProcessSyncIssue(IssueKey=>$Row->{key})->{Success},'deadline slice succeeds');
    is(scalar@{$S->{processed}},1,'at least one ticket processed then stops at deadline');
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});is($Row->{after_ticket_id},1,'deadline retains last completed ticket');
    is($Row->{done_generation},0,'deadline leaves generation pending');
    delete$S->{on_ticket};$S->{processed}=[];$S->{atomic_progress}=1;
    ok($B->ProcessSyncIssue(IssueKey=>$Row->{key})->{Success},'atomic ticket progress accepted');
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});is($Row->{done_generation},$Row->{generation},'atomic progress completes generation');
};
subtest 'successful worker cannot hide a different issue delivery error' => sub {
    my($B,$S)=coordinator_fixture(count=>3,unique=>1);$B->PollSync();my@Rows=@{$S->{store}->ListIssues(SourceKey=>$S->{store}->SourceKey())};
    $S->{fail_ticket}=2;$B->ProcessSyncIssue(IssueKey=>$Rows[1]{key});
    $B->ProcessSyncIssue(IssueKey=>$Rows[2]{key});
    is($S->{cache}{'RedmineBridgeHealth:LastSyncOK'},0,'other successful issue does not clear aggregate failure');
};
subtest 'one warm worker batch processes fifty distinct issues with bounded total work' => sub {
    my($B,$S)=coordinator_fixture(count=>101,unique=>1,settings=>{'Redmine::SyncBatchLimit'=>50});
    $B->PollSync();$B->DispatchSync();is(scalar@{$S->{tasks}},1,'only one scheduler task for default worker count');
    my$Task=$S->{tasks}[0];my$Result=$B->ProcessSyncBatch(%{$Task->{Data}{Params}});
    ok($Result->{Success},'warm batch succeeds');is($Result->{Processed},50,'one worker handles fifty distinct issues');
    is(scalar@{$S->{processed}},50,'batch total work limited to fifty tickets');
    my$Rows=$S->{store}->ListIssues(SourceKey=>$S->{store}->SourceKey());
    is(scalar grep({$_->{done_generation}==$_->{generation}}@$Rows),50,'fifty independent durable generations completed');
    is(scalar@{$S->{tasks}},1,'batch does not create a task per issue');
};
subtest 'both thousand-link shapes drain in twenty warm bounded batches' => sub {
    for my$Unique (0,1) {
        my($B,$S)=coordinator_fixture(count=>1000,unique=>$Unique,settings=>{'Redmine::SyncBatchLimit'=>50});
        $B->PollSync();my$Total=0;
        for(1..20) {my$Result=$B->ProcessSyncBatch(SourceKey=>$S->{store}->SourceKey());$Total+=$Result->{Processed};}
        is($Total,1000,$Unique?'thousand distinct issues delivered in twenty contexts':'thousand shared links delivered in twenty contexts');
        my$Ready=$S->{store}->ReadyIssues(SourceKey=>$S->{store}->SourceKey(),Limit=>1000,Now=>$S->{now});
        is(scalar@$Ready,0,'no empty completion worker remains');
    }
};
subtest 'expired detector lease fences observations after slow HTTP' => sub {
    my($B,$S)=coordinator_fixture();$S->{on_request}=sub {$S->{now}+=61};
    ok(!$B->PollSync(),'expired detector refuses success');
    is(scalar@{$S->{store}->ListIssues(SourceKey=>$S->{store}->SourceKey())},0,'expired detector does not observe issue rows');
};
subtest 'successful worker marks detail probe and avoids immediate duplicate HTTP' => sub {
    my($B,$S)=coordinator_fixture(count=>1);$B->PollSync();
    my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $B->ProcessSyncIssue(IssueKey=>$Row->{key});
    is($S->{store}->GetIssue(IssueKey=>$Row->{key})->{probe_at},1000,'successful worker detail fetch records probe timestamp');
    $S->{requests}=[];$B->PollSync();is(scalar@{$S->{requests}},1,'immediate detector uses list only');
};
subtest 'unlink retires durable failure once and identical relink schedules fresh generation' => sub {
    my($B,$S)=coordinator_fixture(count=>1);$B->PollSync();
    my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $S->{fail_ticket}=1;$B->ProcessSyncIssue(IssueKey=>$Row->{key});
    $S->{dbh}->do('DELETE FROM dynamic_field_value');$B->PollSync();
    my$Retired=$S->{store}->GetIssue(IssueKey=>$Row->{key});
    is($Retired->{done_generation},$Retired->{generation},'inactive issue retired');
    is($Retired->{last_error},'','inactive durable failure cleared');
    is($Retired->{links_hash},'','retired projection invalidates identical relink');
    is($S->{cache}{'RedmineBridgeHealth:LastSyncOK'},1,'retirement clears aggregate delivery failure');
    my$Writes=$S->{issue_writes};$B->PollSync();is($S->{issue_writes},$Writes,'unchanged empty projection does not repeat retirement DML');
    $S->{dbh}->do("INSERT INTO dynamic_field_value VALUES (1,1,'7')");$B->PollSync();
    my$Relinked=$S->{store}->GetIssue(IssueKey=>$Row->{key});
    cmp_ok($Relinked->{generation},'>',$Retired->{generation},'identical ticket and issue relink creates new generation');
    is($Relinked->{after_ticket_id},0,'relink starts fanout from beginning');
};
subtest 'retirement fences running worker without resurrecting aggregate failure' => sub {
    my($B,$S)=coordinator_fixture(count=>1);$B->PollSync();
    my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $S->{on_ticket}=sub {$S->{dbh}->do('DELETE FROM dynamic_field_value');$B->PollSync()};
    my$Result=$B->ProcessSyncIssue(IssueKey=>$Row->{key});
    ok(!$Result->{Success},'retired live worker loses generation lease');
    $Row=$S->{store}->GetIssue(IssueKey=>$Row->{key});
    is($Row->{done_generation},$Row->{generation},'stale worker cannot revive retired work');
    is($Row->{last_error},'','stale worker cannot persist retired failure');
    is($S->{cache}{'RedmineBridgeHealth:LastSyncOK'},1,'stale worker cannot poison aggregate health after unlink');
};
subtest 'continuously changing thousand-ticket issue reaches late tickets then catches up every journal once' => sub {
    my($B,$S)=coordinator_fair_fixture();ok($B->PollSync(),'initial real-sync fixture poll');
    my$Source=$S->{store}->SourceKey();my@FirstPass;my$AllSlicesOK=1;
    for my$Slice (1..20) {
        my$Before=@{$S->{gets}};
        my$Result=$B->ProcessSyncBatch(SourceKey=>$Source);$AllSlicesOK&&=$Result->{Success}&&$Result->{Processed}==50;
        # Real SyncTicketFromRedmine reads once per delivery. Its additional
        # commit link check uses SQL, so TicketGet IDs identify the full round.
        push @FirstPass,@{$S->{gets}}[$Before..$#{$S->{gets}}];
        if($Slice<20) {
            my$JID=11+$Slice;
            $S->{issues}{7}{updated_on}=sprintf('2026-01-02T00:00:%02dZ',$Slice);
            push @{$S->{issues}{7}{journals}},{id=>$JID,notes=>"FAIR-JID-$JID",user=>{name=>'Fixture'},
                details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]};
            $S->{now}+=5;$AllSlicesOK&&=$B->PollSync()?1:0;
        }
    }
    ok($AllSlicesOK,'all hot slices commit fifty tickets despite every-slice observation changes');
    is_deeply(\@FirstPass,[1..1000],'active round reaches ticket1000 without restarting early tickets');
    my$Mid=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>7);
    cmp_ok($Mid->{generation},'>',$Mid->{done_generation},'newer updates remain pending for front catchup');
    is($Mid->{after_ticket_id},0,'completed round rewinds once for catchup');
    my$Catchup=0;
    for(1..20) {my$Result=$B->ProcessSyncBatch(SourceKey=>$Source);$Catchup+=$Result->{Processed};}
    is($Catchup,1000,'quiet catchup sweeps all ticket checkpoints');
    my$Final=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>7);
    is($Final->{done_generation},$Final->{generation},'quiet issue becomes fully acknowledged');
    my(%Markers,%NotesPerTicket);
    for my$Note(@{$S->{notes}}) {
        $NotesPerTicket{$Note->{TicketID}}++;
        $Markers{$Note->{TicketID}}{$1}++ while ($Note->{Body}||'')=~/FAIR-JID-(\d+)\b/g;
    }
    my($Missing,$Duplicate,$BadCheckpoint)=(0,0,0);
    for my$TicketID(1..1000) {
        for my$JID(11..30) {my$Count=$Markers{$TicketID}{$JID}||0;$Missing++ if !$Count;$Duplicate++ if $Count>1;}
        $BadCheckpoint++ if $S->{tickets}{$TicketID}{DynamicField_RedmineLastJournalID}!=30;
    }
    is($Missing,0,'every status journal reaches every linked ticket');
    is($Duplicate,0,'each journal appears once per ticket across consolidated notes');
    is($BadCheckpoint,0,'all thousand final journal checkpoints equal latest journal');
    cmp_ok((sort{$b<=>$a}values%NotesPerTicket)[0],'<=',2,'each ticket receives at most first-round and catchup consolidated note');
};
subtest 'observation during detail GET completes active round then immediately exposes catchup' => sub {
    my($B,$S)=coordinator_fixture(count=>3);$B->PollSync();
    my$Row=$S->{store}->GetIssue(SourceKey=>$S->{store}->SourceKey(),IssueID=>7);
    $B->ProcessSyncIssue(IssueKey=>$Row->{key});
    $S->{on_request}=sub {my($P)=@_;return if$P->{Path}!~/include=/;
        $S->{store}->ObserveSignature(IssueKey=>$Row->{key},Signature=>'new-during-get',Now=>$S->{now});};
    my$Result=$B->ProcessSyncIssue(IssueKey=>$Row->{key});
    is($Result->{Processed},1,'captured snapshot completes remaining active round despite concurrent observation');
    my$Latest=$S->{store}->GetIssue(IssueKey=>$Row->{key});
    is($Latest->{after_ticket_id},0,'completed active round rewinds once for current generation catchup');
    is($Latest->{lease_until},0,'completed round releases its own lease promptly');
    my$Claim=$S->{store}->Claim(IssueKey=>$Row->{key},Now=>$S->{now});
    ok($Claim&&$Claim->{generation}==$Latest->{generation},'new generation is immediately claimable');
};
subtest 'two frequently updated low issues cannot starve a quiet issue' => sub {
    my($B,$S)=coordinator_fixture(count=>3,unique=>1,settings=>{'Redmine::SyncBatchLimit'=>1});
    $B->PollSync();my$Source=$S->{store}->SourceKey();
    for my$Loop(1..3) {
        $B->ProcessSyncBatch(SourceKey=>$Source);
        $S->{issues}{$_}{updated_on}="hot-update-$Loop" for(1,2);
        $S->{now}++;$B->PollSync();
    }
    is_deeply([map{$_->{TicketID}}@{$S->{processed}}],[1,2,3],'quiet third issue receives worker slot after two hot issues');
    my$Quiet=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>3);
    is($Quiet->{done_generation},$Quiet->{generation},'quiet issue completes without waiting for hot issues to settle');
};
subtest 'slow attachment downloads and concurrent observations cannot starve active round' => sub {
    my($B,$S)=coordinator_fair_fixture(count=>3,batch=>2,attachments=>1);
    $S->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $S->{issues}{7}{attachments}=[{id=>1,filename=>'fair.bin',filesize=>4,content_type=>'application/octet-stream',
        content_url=>'http://redmine.test/attachments/download/1'}];
    $S->{files}{1}="data";
    my$Downloads=0;
    $S->{on_request}=sub {my($P)=@_;return if$P->{Path}!~m{^/attachments/download/};
        $Downloads++;$S->{now}+=6;my$JID=11+$Downloads;
        $S->{issues}{7}{updated_on}=sprintf('2026-01-02T00:01:%02dZ',$Downloads);
        push @{$S->{issues}{7}{journals}},{id=>$JID,notes=>"FAIR-JID-$JID",user=>{name=>'Fixture'},
            details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]};
        $B->PollSync();
    };
    $B->PollSync();my$Source=$S->{store}->SourceKey();
    my$First=$B->ProcessSyncBatch(SourceKey=>$Source);
    ok($First->{Success}&&$First->{Processed}==2,'first slow download still commits both active-round tickets');
    my$Second=$B->ProcessSyncBatch(SourceKey=>$Source);
    ok($Second->{Success}&&$Second->{Processed}==1,'late ticket commits despite another in-flight update');
    cmp_ok($Downloads,'>=',2,'HTTP boundary advances clock six seconds and observes updates on repeated downloads');
    delete$S->{on_request};
    for(1..4) {$B->ProcessSyncBatch(SourceKey=>$Source)}
    my$Row=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>7);
    is($Row->{done_generation},$Row->{generation},'quiet followup acknowledges all newer observations');
    my(%Markers,$Attachments);
    for my$Note(@{$S->{notes}}) {my$Body=$Note->{Body}||'';
        $Markers{$Note->{TicketID}}{$1}++ while$Body=~/FAIR-JID-(\d+)\b/g;
        $Attachments+=scalar@{$Note->{Attachment}||[]};
    }
    is($Attachments,3,'each real ticket note stores its attachment once');
    my$Bad=0;for my$Ticket(1..3) {for my$JID(11..11+$Downloads) {$Bad++ if($Markers{$Ticket}{$JID}||0)!=1}}
    is($Bad,0,'every resulting status journal appears exactly once in each ticket across snapshots');
};
subtest 'missing first attachment cannot block already-imported healthy sibling status notes' => sub {
    for my$Count(2,1000) {
        my($B,$S)=coordinator_fair_fixture(count=>$Count,attachments=>1);
        $S->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
        $S->{issues}{7}{attachments}=[{id=>1,filename=>'missing-first.bin',filesize=>4,content_type=>'application/octet-stream',
            content_url=>'http://redmine.test/attachments/download/1'}];
        $S->{missing_file_http404}=1;
        $S->{tickets}{$_}{DynamicField_RedmineLastAttachmentID}=1 for(2..$Count);
        $B->PollSync();my$Source=$S->{store}->SourceKey();my($Attempted,$Succeeded)=(0,0);my$First;
        for(1..int(($Count+49)/50)) {my$Result=$B->ProcessSyncBatch(SourceKey=>$Source);
            $First||=$Result;$Attempted+=$Result->{Processed};$Succeeded+=$Result->{Succeeded};}
        is($Attempted,$Count,"$Count heterogeneous links all visited during first scan");
        is($Succeeded,$Count-1,'only first missing-file ticket fails');
        ok(!$First->{Success}&&length$First->{Error},'partial batch exposes first delivery error');
        is(scalar@{$S->{notes}},$Count-1,'healthy status comments are delivered despite first file failure');
        is_deeply($S->{gets},[1..$Count],'scan reaches every healthy sibling in ascending order');
        my$BadStates=grep{($S->{tickets}{$_}{State}||'')ne'open'}2..$Count;
        is($BadStates,0,'all healthy siblings map state before first file recovery');
        my$Row=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>7);
        is($Row->{first_failed_ticket_id},1,'missing first ticket remains durable pending gap');
        is($Row->{after_ticket_id},0,'finished scan rewinds to first gap');
        is($S->{cache}{'RedmineBridgeHealth:LastSyncOK'},0,'gap remains visible after successful tail batches');
        delete$S->{missing_file_http404};$S->{files}{1}='data';$S->{now}=$Row->{retry_at}+1;
        for(1..int(($Count+49)/50)) {$B->ProcessSyncBatch(SourceKey=>$Source)}
        $Row=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>7);
        is($Row->{done_generation},$Row->{generation},'recovered gap acknowledges whole round');
        is(scalar@{$S->{notes}},$Count,'recovery creates one missing note and no healthy duplicates');
        my%PerTicket; $PerTicket{$_->{TicketID}}++ for@{$S->{notes}};
        is(scalar(grep{$_!=1}values%PerTicket),0,'each ticket has exactly one consolidated status note');
        is($S->{cache}{'RedmineBridgeHealth:LastSyncOK'},1,'successful gap recovery clears aggregate failure');
    }
};
subtest 'daemon catches errors and dispatches each stable loop' => sub {
    BEGIN {package Kernel::System::Daemon::BaseDaemon; sub PreRun {1}; $INC{'Kernel/System/Daemon/BaseDaemon.pm'}=1;}
    require Kernel::System::Daemon::DaemonModules::RedmineBridgePoller;
    my($B,$S)=coordinator_fixture();
    {no warnings 'redefine';local *CoordinatorTest::Services::Get= sub {
        my($Self,@A)=@_;return $B if @A==1&&$A[0]eq'Kernel::System::Redmine';
        return $Self->{store} if @A==1&&$A[0]eq'Kernel::System::Redmine::SyncStore';
        return $Self if @A==1&&$A[0]=~/^Kernel::/;return $Self->{settings}{$A[0]} if @A==1;
        my%P=@A;return$Self->{cache}{"$P{Type}:$P{Key}"};};
        my$D=Kernel::System::Daemon::DaemonModules::RedmineBridgePoller->new();
        is($S->{configured}{CacheInMemory},0,'daemon memory cache disabled');
        $S->{fail_select}=1;ok($D->Run(),'daemon stays alive after detector/dispatcher failure');
        delete$S->{fail_select};$D->{NextPoll}=0;ok($D->Run(),'next iteration recovers');
        is(scalar@{$S->{tasks}},1,'daemon dispatches recovered work');
        {
            no warnings qw(redefine once);
            local *Kernel::System::Daemon::DaemonModules::RedmineBridgePoller::sleep=sub {};
            my$KeptAlive=0;$KeptAlive++ for grep {$D->PostRun()} 1..59;
            is($KeptAlive,59,'daemon remains active through first fifty-nine loop sleeps');
            ok(!$D->PostRun(),'sixtieth sleep requests core recycle to reload configuration');
            my$Slow=Kernel::System::Daemon::DaemonModules::RedmineBridgePoller->new();
            $Slow->{DiscardAt}=time()-1;
            ok(!$Slow->PostRun(),'slow sweeps recycle by elapsed wall time before sixty loops');
        }
    }
};
subtest 'shared HTTP cooldown prevents scheduler and sibling retry storms' => sub {
    my ($B,$S)=coordinator_fixture(count=>3,unique=>1,settings=>{'Redmine::SyncBatchLimit'=>50});
    $B->PollSync();
    my $Key='Cooldown::'.Digest::SHA::sha256_hex(Encode::encode_utf8("http://redmine.test\0fixture"));
    $S->{cache}{"RedmineBridgeHTTP:$Key"}={OpenUntil=>time()+60};
    ok($B->DispatchSync(),'paused source does not fail dispatcher');
    is(scalar @{$S->{tasks}},0,'no cold workers queued while source is cooling down');
    delete $S->{cache}{"RedmineBridgeHTTP:$Key"};
    $S->{fail_ticket}=1;
    $S->{on_ticket}=sub {$S->{cache}{"RedmineBridgeHTTP:$Key"}={OpenUntil=>time()+60}};
    my $Source=$S->{store}->SourceKey();
    my $Row=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>1);
    my $Result=$B->ProcessSyncBatch(SourceKey=>$Source,SeedIssueKey=>$Row->{key});
    ok(!$Result->{Success},'first source error remains visible');
    is(scalar @{$S->{processed}},1,'batch stops before failing every sibling issue');
    my $Untouched=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>2);
    is($Untouched->{retry_count},0,'other pending work retains retry budget');
};
subtest 'batch delivery publishes aggregate health once for many distinct issues' => sub {
    my ($B,$S)=coordinator_fixture(count=>50,unique=>1,settings=>{'Redmine::SyncBatchLimit'=>50});
    $B->PollSync();
    my $Source=$S->{store}->SourceKey();
    my $Row=$S->{store}->GetIssue(SourceKey=>$Source,IssueID=>1);
    my $Calls=0;my $Original=$B->can('_SyncHealth');
    no warnings 'redefine';
    local *CoordinatorTest::Bridge::_SyncHealth=sub {$Calls++;return $Original->(@_)};
    my $Result=$B->ProcessSyncBatch(SourceKey=>$Source,SeedIssueKey=>$Row->{key});
    ok($Result->{Success},'all issue deliveries succeed');
    is($Result->{Processed},50,'one bounded batch serves fifty distinct issues');
    is($Calls,1,'one durable-error health scan and publication per batch');
    is($S->{cache}{'RedmineBridgeHealth:LastSyncOK'},1,'aggregate status remains available');
};
subtest 'fixture teardown finishes statements and disconnects before DBI global cleanup' => sub {
    my $Cleanup=StoreTest->can('cleanup_fixtures');
    ok($Cleanup,'explicit fixture cleanup is available');
    return if !$Cleanup;
    my(undef,$Services)=coordinator_fixture();
    $Services->Prepare(SQL=>'SELECT id FROM ticket');
    my $Statement=$Services->{sth};
    my $DB=$Services->{dbh};
    ok($Statement->{Active} && $DB->{Active},'retained service statement starts active');
    $DB->begin_work();
    my(@Warnings,$Cleaned);
    {local $SIG{__WARN__}=sub {push @Warnings,@_};$Cleaned=StoreTest::cleanup_fixtures();}
    ok($Cleaned,'fixtures clean up without suppressed errors');
    is_deeply(\@Warnings,[],'no active-statement or implicit-rollback disconnect warnings');
    ok(!$DB->{Active},'database disconnected before global destruction');
    ok(!exists $Services->{sth},'service no longer retains a statement handle');
    ok(!exists $Services->{store}{DBObject}{Cursor},'store adapter no longer retains a statement handle');
    ok(StoreTest::cleanup_fixtures(),'cleanup is safe when called again from END');
};
subtest 'disabled daemon avoids loading the bridge and transport objects' => sub {
    my ($B,$S)=coordinator_fixture(settings=>{'Redmine::Enabled'=>0});
    require Kernel::System::Daemon::DaemonModules::RedmineBridgePoller;
    my $Loads=0;my $Original=CoordinatorTest::Services->can('Get');
    no warnings 'redefine';
    local *CoordinatorTest::Services::Get=sub {
        $Loads++ if @_==2 && $_[1] eq 'Kernel::System::Redmine';
        return $Original->(@_);
    };
    my $Daemon=Kernel::System::Daemon::DaemonModules::RedmineBridgePoller->new();
    ok($Daemon->Run(),'disabled daemon remains healthy');
    is($Loads,0,'no heavy bridge/HTTP initialization when disabled');
};
done_testing();
