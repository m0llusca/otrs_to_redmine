use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
use Test::More;
use BridgeTest qw(fixture);

# Manual ticket-sync behavior; projection/queue/fairness is tested independently
# against the real SQLite coordinator in coordinator.t.
sub sync_group {
    my ($bridge,$services)=@_;
    my %cache;
    for my $id (sort {$a<=>$b} keys %{$services->{tickets}}) {
        $bridge->SyncTicketFromRedmine(TicketID=>$id,IssueCache=>\%cache);
    }
}

subtest 'one Redmine snapshot per issue, independent ticket state' => sub {
    my ($b,$s)=fixture(count=>10);
    sync_group($b,$s);
    is(scalar @{$s->{requests}},1,'ten unchanged sibling tickets use one compact GET');
    is(scalar @{$s->{gets}},10,'each selected ticket is read once');
    is(scalar @{$s->{notes}},0,'unchanged issues create no notes');
    is(scalar(grep {$_->[1] eq 'RedmineLastSyncAt'} @{$s->{writes}}),0,'successful checks do not mutate ticket metadata');
    is(scalar(grep {$_->[1] eq 'RedmineLastUpdatedOn'} @{$s->{writes}}),0,'unchanged updated_on is not written');
    unlike($s->{requests}[0]{Path},qr/include/,'unchanged issue does not fetch journals or attachments');
};



subtest 'mapped transition combines comment and binary attachment for siblings' => sub {
    my ($b,$s)=fixture(count=>2,settings=>{'Redmine::NotifyOnStatusNote'=>1});
    $s->{issues}{7}={id=>7,status=>{name=>'Проверка решения'},updated_on=>'2026-01-02T00:00:00Z',
        journals=>[{id=>11,user=>{name=>'Engineer'},notes=>'Решение готово',details=>[{property=>'attr',name=>'status_id'}]}],
        attachments=>[{id=>1,filename=>'data.bin',filesize=>4,content_type=>'application/octet-stream'}]};
    $s->{files}{1}="\x00\xff\x80A";
    sync_group($b,$s);
    is(scalar @{$s->{notes}},2,'one consolidated note per sibling');
    is(scalar @{$s->{states}},2,'state transition fans out');
    is(scalar(grep {$_->{Path}=~m{^/issues/}} @{$s->{requests}}),2,'compact plus shared detail GET');
    is(scalar(grep {$_->{Path}=~m{^/attachments/}} @{$s->{requests}}),1,'file downloaded once');
    for my $n (@{$s->{notes}}) {
        like($n->{Body},qr/Решение готово/,'transition comment retained');
        is($n->{Attachment}[0]{Content},"\x00\xff\x80A",'binary bytes preserved');
        is_deeply($n->{ForceNotificationToUserID},[2,3],'owner and responsible notified');
        is($n->{ObservedState},'open','state is applied before article notifications');
    }
    sync_group($b,$s);
    is(scalar @{$s->{notes}},2,'repeat check does not duplicate notes');
};

subtest 'ordinary comments and attachment-only changes stay out of OTRS' => sub {
    my ($b,$s)=fixture();
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[{id=>11,user=>{name=>'Engineer'},notes=>'Ordinary comment',details=>[]}];
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'a.bin',filesize=>3}];
    sync_group($b,$s);
    is(scalar @{$s->{notes}},0,'no unrelated note');
    is(scalar(grep {$_->{Path}=~m{^/attachments/}} @{$s->{requests}}),0,'no unnecessary binary download');
    is($s->{tickets}{1}{DynamicField_RedmineLastJournalID},11,'journal cursor advances');
    is($s->{tickets}{1}{DynamicField_RedmineLastAttachmentID},1,'attachment cursor advances');
};

subtest 'relink during a batch never applies another issue snapshot' => sub {
    my ($b,$s)=fixture(count=>2);
    $s->{tickets}{2}{DynamicField_RedmineID}='8';
    $s->{dbh}->do("UPDATE dynamic_field_value SET value_text='8' WHERE field_id=1 AND object_id=2");
    $s->{issues}{8}={id=>8,status=>{name=>'Проверка решения'},updated_on=>'2026-01-02T00:00:00Z',journals=>[],attachments=>[]};
    sync_group($b,$s);
    is(scalar @{$s->{notes}},1,'new link is synchronized using its own snapshot');
    is($s->{notes}[0]{TicketID},2,'correct ticket receives note');
    like($s->{notes}[0]{Subject},qr/Redmine #8/,'note belongs to actual linked issue');
};


subtest 'overlapping sync never regresses a newer journal checkpoint' => sub {
    my ($b,$s)=fixture();
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[{id=>11,notes=>'Comment',details=>[]}];
    $s->{on_request}=sub {
        my ($p)=@_;$s->{tickets}{1}{DynamicField_RedmineLastJournalID}=12 if $p->{Path}=~/include/;
    };
    $b->SyncTicketFromRedmine(TicketID=>1);
    delete $s->{on_request};
    is($s->{tickets}{1}{DynamicField_RedmineLastJournalID},12,'newer cursor survives slower run');
};

subtest 'failed note creation does not consume transition or attachment cursors' => sub {
    my ($b,$s)=fixture();
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[{id=>11,notes=>'Fix',details=>[{property=>'attr',name=>'status_id'}]}];
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'retry.bin',filesize=>4}];
    $s->{files}{1}='DATA';
    $s->{fail_article}=1;
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok(!$r{Success},'failure is visible');
    is($s->{tickets}{1}{DynamicField_RedmineLastJournalID},10,'journal retry remains possible');
    is($s->{tickets}{1}{DynamicField_RedmineLastAttachmentID},0,'file retry remains possible');
    is($s->{tickets}{1}{DynamicField_RedmineStatus},'New','status checkpoint remains retryable');
    $s->{fail_article}=0;
    %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'retry succeeds');
    is(scalar @{$s->{notes}},1,'note delivered once on retry');
    is($s->{notes}[0]{Attachment}[0]{Content},'DATA','file delivered with retried note');
};

subtest 'sibling cursors are independent and selective sync modes are retained' => sub {
    for my $rule ('open','note','open|note') {
        my ($b,$s)=fixture(count=>2,settings=>{'Redmine::StatusSync'=>{'Проверка решения'=>$rule},'Redmine::SyncAttachments'=>0});
        $s->{issues}{7}{status}{name}='Проверка решения';$s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
        $s->{issues}{7}{journals}=[{id=>11,user=>{name=>'Agent'},notes=>'Transition comment',details=>[{property=>'attr',name=>'status_id'}]}];
        $s->{tickets}{1}{DynamicField_RedmineStatus}='Проверка решения';
        $s->{tickets}{1}{DynamicField_RedmineLastUpdatedOn}='2026-01-02T00:00:00Z';
        $s->{tickets}{1}{DynamicField_RedmineLastJournalID}=11;
        sync_group($b,$s);
        is(scalar @{$s->{notes}},$rule eq 'open'?0:1,"$rule note behavior");
        is(scalar @{$s->{states}},$rule eq 'note'?0:1,"$rule state behavior");
        is($s->{notes}[0]{TicketID},2,"$rule does not replay to up-to-date sibling") if $rule ne 'open';
        is(scalar(grep {$_->{Path}=~/attachments/} @{$s->{requests}}),0,'disabled attachments not requested');
    }
};

subtest 'optional downloads cannot block mapped state and remain retryable' => sub {
    my ($b,$s)=fixture();
    $s->{tickets}{1}{State}='closed successful';
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'retry.bin',filesize=>4}];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok(!$r{Success},'download failure visible');
    is($s->{tickets}{1}{State},'open','mapped state applies despite file failure');
    is($s->{tickets}{1}{DynamicField_RedmineStatus},'New','note transition checkpoint not consumed');
    is($s->{tickets}{1}{DynamicField_RedmineLastAttachmentID},0,'attachment remains retryable');
    $s->{files}{1}='DATA';
    %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'retry succeeds');
    is(scalar @{$s->{notes}},1,'single note created after successful download');
    is($s->{notes}[0]{Attachment}[0]{Content},'DATA','retry includes bytes');
};
subtest 'journals failure preserves snapshot state mapping without consuming cursors' => sub {
    my ($b,$s)=fixture(settings=>{'Redmine::SyncAttachments'=>0});
    $s->{tickets}{1}{State}='closed successful';
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';$s->{fail_details}=1;
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok(!$r{Success},'details failure visible');
    is($s->{tickets}{1}{State},'open','compact snapshot still applies mapped state');
    is($s->{tickets}{1}{DynamicField_RedmineStatus},'New','note transition can retry');
    is($s->{tickets}{1}{DynamicField_RedmineLastJournalID},10,'journal checkpoint retained');
};
subtest 'enabling attachments catches up file-only cursor without importing old files' => sub {
    my ($b,$s)=fixture(settings=>{'Redmine::SyncAttachments'=>0});
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'old.bin',filesize=>4}];$s->{files}{1}='OLD!';
    $b->SyncTicketFromRedmine(TicketID=>1);
    $s->{settings}{'Redmine::SyncAttachments'}=1;
    $b->SyncTicketFromRedmine(TicketID=>1);
    is($s->{tickets}{1}{DynamicField_RedmineLastAttachmentID},1,'old file marked seen after enabling');
    is(scalar @{$s->{notes}},0,'catch-up alone creates no note');
    my $requests=@{$s->{requests}};
    $b->SyncTicketFromRedmine(TicketID=>1);
    is(scalar @{$s->{requests}},$requests+1,'caught-up unchanged ticket uses compact GET');
    $s->{issues}{7}{status}{name}='Проверка решения';$s->{issues}{7}{updated_on}='2026-01-03T00:00:00Z';
    $b->SyncTicketFromRedmine(TicketID=>1);
    is(scalar @{$s->{notes}},1,'later transition creates one note');
    ok(!$s->{notes}[0]{Attachment},'historical attachment not copied at later transition');
};

subtest 'new attachment stream timestamp is monotonic and cleared on unlink' => sub {
    my ($b,$s)=fixture();
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{on_request}=sub {
        my ($p)=@_;
        $s->{tickets}{1}{DynamicField_RedmineLastAttachmentSyncOn}='2026-01-03T00:00:00Z' if $p->{Path}=~/include/;
    };
    $b->SyncTicketFromRedmine(TicketID=>1);delete $s->{on_request};
    is($s->{tickets}{1}{DynamicField_RedmineLastAttachmentSyncOn},'2026-01-03T00:00:00Z','newer stream timestamp retained');
    my %r=$b->UnlinkTicketFromIssue(TicketID=>1,UserID=>1);
    ok($r{Success},'unlink succeeds');
    is($s->{tickets}{1}{DynamicField_RedmineLastAttachmentSyncOn},'','unlink clears optional stream cursor');
};

subtest 'successful unchanged checks are operational metadata, not ticket writes' => sub {
    my ($b,$s)=fixture();
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'check successful');
    is(scalar @{$s->{writes}},0,'no dynamic field changes at all');
    ok($s->{cache}{'RedmineBridgeHealth:TicketCheck::1'}{At},'successful check recorded in operational cache');
};
subtest 'ordinary HTML journals never invoke text conversion' => sub {
    my ($b,$s)=fixture();$s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[map{{id=>10+$_,notes=>'<p>Unrelated</p>',details=>[]}}1..1000];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'ordinary changes checked');
    is($s->{ascii_calls}||0,0,'irrelevant journals not normalized');
    is($s->{tickets}{1}{DynamicField_RedmineLastJournalID},1010,'ignored journals checkpointed');
    is(scalar @{$s->{notes}},0,'ordinary comments stay out');
};
subtest 'short-lived eligible transition is delivered even if final status returns' => sub {
    my ($b,$s)=fixture();$s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[
      {id=>11,user=>{name=>'Agent'},notes=>'Eligible fix',details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]},
      {id=>12,user=>{name=>'Agent'},notes=>'Ordinary final',details=>[{property=>'attr',name=>'status_id',old_value=>'2',new_value=>'1'}]},
    ];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'transition sequence delivered');
    is(scalar @{$s->{notes}},1,'one consolidated note for the sequence');
    like($s->{notes}[0]{Body},qr/Проверка решения/,'actual intermediate status identified');
    like($s->{notes}[0]{Body},qr/Eligible fix/,'eligible comment delivered');
    unlike($s->{notes}[0]{Body},qr/Ordinary final/,'unmapped final comment excluded');
    is($s->{tickets}{1}{DynamicField_RedmineStatus},'New','current status stays final source status');
    is($s->{tickets}{1}{DynamicField_RedmineLastJournalID},12,'whole sequence checkpointed');
};
subtest 'eligible HTML is normalized once across linked siblings' => sub {
    my ($b,$s)=fixture(count=>2);$s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{journals}=[{id=>11,user=>{name=>'Agent'},notes=>'<p>Fix</p>',details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]}];
    my %cache;
    $b->SyncTicketFromRedmine(TicketID=>$_,IssueCache=>\%cache) for 1..2;
    is(scalar @{$s->{notes}},2,'each sibling receives own note');
    is($s->{ascii_calls},1,'shared content conversion once');
};
subtest 'failed shared download is attempted once, without consuming cursors' => sub {
    my ($b,$s)=fixture(count=>2);$s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'unavailable.bin',filesize=>4}];
    my %cache;
    my @r=map{{ $b->SyncTicketFromRedmine(TicketID=>$_,IssueCache=>\%cache) }}1..2;
    ok(!$r[0]{Success}&&!$r[1]{Success},'both remain retryable');
    is(scalar(grep{$_->{Path}=~m{^/attachments/}}@{$s->{requests}}),1,'only one failed download per group');
    is($s->{tickets}{2}{DynamicField_RedmineLastAttachmentID},0,'file cursor retained');
    $s->{files}{1}='DATA';my %fresh;
    my %r=$b->SyncTicketFromRedmine(TicketID=>2,IssueCache=>\%fresh);
    ok($r{Success},'next operation retries normally');
};

subtest 'same-ticket concurrent delivery is fenced before network work' => sub {
    my ($b,$s)=fixture();
    my $token=$s->{store}->LockAcquire(Key=>'Ticket::1');
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok(!$r{Success} && $r{Status} eq 'Busy','second owner rejected');
    is(scalar @{$s->{requests}},0,'no redundant network work');
    $s->{store}->LockRelease(Key=>'Ticket::1',Token=>$token);
    %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'released lock allows delivery');
};
subtest 'expired ownership cannot commit a prepared note' => sub {
    my ($b,$s)=fixture();$s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{on_request}=sub {
        $s->{dbh}->do("UPDATE redmine_sync_lock SET lease_until=0, lease_token='stolen'");
    };
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok(!$r{Success},'lost lease is a retryable failure');
    is(scalar @{$s->{notes}},0,'no note written without current lease');
    is(scalar @{$s->{states}},0,'lost owner cannot change ticket state');
    is($s->{tickets}{1}{DynamicField_RedmineStatus},'New','transition checkpoint retained');
};
subtest 'worker can recheck journals with identical source timestamp' => sub {
    my ($b,$s)=fixture();
    $s->{issues}{7}{journals}=[{id=>11,user=>{name=>'Agent'},notes=>'Same timestamp fix',details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]}];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1,ForceDetails=>1);
    ok($r{Success},'forced journal check succeeds');
    is(scalar @{$s->{notes}},1,'same-second transition delivered');
};
subtest 'long file groups renew ownership at download boundaries' => sub {
    my ($b,$s)=fixture();
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'one.bin',filesize=>4}];
    $s->{files}{1}='DATA';
    my $Source=$s->{store}->SourceKey();
    my $Row=$s->{store}->Observe(SourceKey=>$Source,IssueID=>7,UpdatedOn=>'2026-01-02T00:00:00Z',Status=>'Проверка решения',LinksHash=>'one');
    my $Claim=$s->{store}->Claim(IssueKey=>$Row->{key});
    my %Work=(IssueKey=>$Row->{key},Token=>$Claim->{lease_token},RoundGeneration=>$Claim->{round_generation});
    $s->{on_request}=sub {
        my ($p)=@_;
        return if $p->{ExpectJSON}//1;
        $b->{_TicketSyncLease}->{RenewedAt}=time()-40;
        $s->{dbh}->do('UPDATE redmine_sync_lock SET lease_until=?',undef,time()+5);
        $s->{dbh}->do('UPDATE redmine_sync_issue SET lease_until=?',undef,time()+5);
    };
    my %r=$b->SyncTicketFromRedmine(TicketID=>1,Work=>\%Work);
    ok($r{Success},'slow file still commits while lease valid');
    is(scalar @{$s->{notes}},1,'one status note with file');
    cmp_ok($s->{store}->GetIssue(IssueKey=>$Row->{key})->{lease_until},'>=',time()+110,'issue ownership renewed together with ticket');
};
subtest 'current mapped state wins when return journal is hidden' => sub {
    my ($b,$s)=fixture(settings=>{'Redmine::StatusSync'=>{'Проверка решения'=>'open|note','New'=>'closed successful'}});
    $s->{tickets}{1}{State}='open';
    $s->{tickets}{1}{DynamicField_RedmineStatus}='Проверка решения';
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[{id=>11,details=>[{property=>'attr',name=>'status_id',old_value=>'2',new_value=>'1'}]}];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'visible partial journal can be checkpointed');
    is($s->{tickets}{1}{State},'open','final API status overrides intermediate state');
};
subtest 'cached worker snapshot cannot downgrade a newer manual checkpoint' => sub {
    my ($b,$s)=fixture();
    $s->{tickets}{1}{State}='open';
    $s->{tickets}{1}{DynamicField_RedmineStatus}='Проверка решения';
    $s->{tickets}{1}{DynamicField_RedmineLastUpdatedOn}='2026-01-03T00:00:00Z';
    $s->{tickets}{1}{DynamicField_RedmineLastJournalID}='12';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[{id=>11,details=>[{property=>'attr',name=>'status_id',old_value=>'2',new_value=>'1'}]}];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1,ForceDetails=>1);
    ok($r{Success} && $r{Status} eq 'Skip','older grouped data skipped');
    is($s->{tickets}{1}{DynamicField_RedmineStatus},'Проверка решения','newer status retained');
    is($s->{tickets}{1}{DynamicField_RedmineLastJournalID},12,'newer journal retained');
    is(scalar @{$s->{notes}},0,'no duplicate fallback note');
};
subtest 'ordinary comment preserves an agent state override under a mapped Redmine status' => sub {
    my ($b,$s)=fixture();
    $s->{tickets}{1}{State}='closed successful';
    $s->{tickets}{1}{DynamicField_RedmineStatus}='Проверка решения';
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[{id=>11,notes=>'ordinary discussion',details=>[]}];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1,ForceDetails=>1);
    ok($r{Success},'ordinary activity checkpointed');
    is($s->{tickets}{1}{State},'closed successful','agent state remains unchanged');
    is(scalar @{$s->{notes}},0,'no ordinary comment note');
};
subtest 'same-second cached empty journals refresh before overwriting a manual result' => sub {
    my ($b,$s)=fixture();
    $s->{tickets}{1}{State}='open';
    $s->{tickets}{1}{DynamicField_RedmineStatus}='Проверка решения';
    $s->{tickets}{1}{DynamicField_RedmineLastUpdatedOn}='2026-01-02T00:00:00Z';
    $s->{tickets}{1}{DynamicField_RedmineLastJournalID}='12';
    $s->{issues}{7}{status}{name}='Проверка решения';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[{id=>12,details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]}];
    my $Row=$s->{store}->Observe(SourceKey=>$s->{store}->SourceKey(),IssueID=>7,UpdatedOn=>'2026-01-02T00:00:00Z',Status=>'New',LinksHash=>'one');
    my $Claim=$s->{store}->Claim(IssueKey=>$Row->{key});
    my %Work=(IssueKey=>$Row->{key},Token=>$Claim->{lease_token},RoundGeneration=>$Claim->{round_generation});
    my $Old={Success=>1,Data=>{issue=>{id=>7,status=>{name=>'New'},updated_on=>'2026-01-02T00:00:00Z',journals=>[],attachments=>[]}}};
    my %Cache=(Snapshot=>$Old,Details=>$Old,IssueID=>7);
    my %r=$b->SyncTicketFromRedmine(TicketID=>1,ForceDetails=>1,IssueCache=>\%Cache,Work=>\%Work);
    ok($r{Success},'worker safely checks uncertain empty history');
    is($s->{tickets}{1}{DynamicField_RedmineStatus},'Проверка решения','fresh manual status is preserved');
    is(scalar @{$s->{notes}},0,'already delivered journal does not produce fallback duplicate');
    is(scalar @{$s->{requests}},1,'one fresh detail request under the ticket lease');
};
subtest 'live current status name takes precedence over a cached catalog rename' => sub {
    my ($b,$s)=fixture(settings=>{'Redmine::StatusSync'=>{'Review'=>'open|note'}});
    $s->{issues}{7}{status}={id=>2,name=>'Review'};
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[{id=>11,notes=>'review comment retained',details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]}];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'renamed current status is delivered');
    like($s->{notes}[0]{Body},qr/review comment retained/,'eligible comment survives stale catalog label');
};
subtest 'failed note does not replay obsolete intermediate state toggles' => sub {
    my ($b,$s)=fixture(settings=>{'Redmine::StatusSync'=>{'Проверка решения'=>'open|note','New'=>'closed successful'}});
    $s->{tickets}{1}{State}='closed successful';
    $s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{journals}=[
        {id=>11,details=>[{property=>'attr',name=>'status_id',old_value=>'1',new_value=>'2'}]},
        {id=>12,details=>[{property=>'attr',name=>'status_id',old_value=>'2',new_value=>'1'}]},
    ];
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'missing.bin',filesize=>4}];
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok(!$r{Success},'missing file leaves note retryable');
    is(scalar @{$s->{states}},0,'already-correct current state receives no obsolete open/close history');
    $s->{files}{1}='DATA';%r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'retry imports the status note');
    is(scalar @{$s->{notes}},1,'intermediate check transition is still recorded');
    is($s->{tickets}{1}{State},'closed successful','current mapped status remains authoritative');
};
done_testing();
