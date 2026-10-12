use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
use Test::More;
use BridgeTest qw(fixture);

sub create_fixture {
    my ($b,$s)=fixture(settings=>{'Redmine::MaxAttachmentBytes'=>10,'Redmine::MaxAttachmentTotalBytes'=>10,'Redmine::MaxAttachmentCount'=>2});
    $s->{tickets}{1}{DynamicField_RedmineID}='';
    $s->{attachment_meta}=[
        {Key=>'1:1',ArticleID=>1,FileID=>1,Filename=>'one.bin',Size=>4},
        {Key=>'1:2',ArticleID=>1,FileID=>2,Filename=>'two.bin',Size=>4},
    ];
    $s->{article_files}={'1:1'=>{Filename=>'one.bin',Content=>'AAAA'},'1:2'=>{Filename=>'two.bin',Content=>'BBBB'}};
    return ($b,$s);
}
sub escalate {
    my ($b)=@_; return $b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'Test',Description=>'Description',AssignedToID=>2,DueDate=>'2026-12-01',IncludeAttachments=>1);
}

subtest 'outbound files read/upload sequentially, not preloaded together' => sub {
    my ($b,$s)=create_fixture(); my %r=escalate($b);
    ok($r{Success},'issue created');
    is_deeply($s->{file_events},[qw(read upload read upload)],'one file read then uploaded before reading next');
    is_deeply($s->{uploaded},['AAAA','BBBB'],'both original files delivered');
};
subtest 'aggregate limit fails before remote issue creation or file loading' => sub {
    my ($b,$s)=create_fixture();$s->{settings}{'Redmine::MaxAttachmentTotalBytes'}=7;
    my %r=escalate($b);
    ok(!$r{Success},'oversized operation rejected');
    is(scalar @{$s->{requests}},0,'no orphan issue or upload');
    is(scalar @{$s->{file_events} || []},0,'no file contents loaded');
};
subtest 'count limit covers ticket plus extra files' => sub {
    my ($b,$s)=create_fixture();
    $s->{uploads}{form}=[{FileID=>1,Filename=>'extra.bin',FilesizeRaw=>1,Content=>'X'}];
    my %r=$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,DueDate=>'2026-12-01',IncludeAttachments=>1,FormID=>'form');
    ok(!$r{Success},'combined count rejected');
    is(scalar @{$s->{requests}},0,'validation precedes network');
};
subtest 'OTRS 6 Filesize metadata enforces extra-file budget before reading data' => sub {
    my ($b,$s)=create_fixture();
    $s->{settings}{'Redmine::MaxAttachmentCount'}=5;
    $s->{uploads}{form}=[{FileID=>1,Filename=>'extra.bin',Filesize=>8,Content=>'XXXXXXXX'}];
    my %r=$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,DueDate=>'2026-12-01',IncludeAttachments=>1,FormID=>'form');
    ok(!$r{Success},'total 4+4+8 bytes rejected using upstream Filesize');
    is(scalar @{$s->{requests}},0,'rejection precedes network');
};
subtest 'extra UploadCache files remain supported with upstream Filesize metadata' => sub {
    my ($b,$s)=create_fixture();
    $s->{uploads}{form}=[{FileID=>1,Filename=>'extra.bin',Filesize=>4,Content=>"\x00\xffAB"}];
    my %r=$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,DueDate=>'2026-12-01',IncludeAttachments=>0,FormID=>'form');
    ok($r{Success},'extra upload without ticket attachments succeeds');
    is_deeply($s->{uploaded},["\x00\xffAB"],'exact extra-file bytes uploaded');
};
subtest 'unknown extra-file size is rejected before loading unbounded cache content' => sub {
    my ($b,$s)=create_fixture();
    $s->{uploads}{form}=[{FileID=>1,Filename=>'extra.bin',Content=>'huge'}];
    my %r=$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,DueDate=>'2026-12-01',IncludeAttachments=>0,FormID=>'form');
    ok(!$r{Success},'missing size cannot bypass preflight');
    is(scalar @{$s->{requests}},0,'no remote side effects');
};
subtest 'inbound aggregate cap is visible and bounded' => sub {
    my ($b,$s)=fixture(settings=>{'Redmine::MaxAttachmentBytes'=>10,'Redmine::MaxAttachmentTotalBytes'=>6,'Redmine::MaxAttachmentCount'=>2});
    $s->{issues}{7}{status}{name}='Проверка решения';$s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'one.bin',filesize=>4},{id=>2,filename=>'two.bin',filesize=>4}];
    $s->{files}{1}='AAAA';$s->{files}{2}='BBBB';
    my %r=$b->SyncTicketFromRedmine(TicketID=>1);
    ok($r{Success},'note delivered within budget');
    is(scalar @{$s->{notes}[0]{Attachment}},1,'only budgeted file retained');
    like($s->{notes}[0]{Body},qr/общий лимит/,'omission explained in note');
    is(scalar(grep {$_->{Path}=~m{^/attachments/}} @{$s->{requests}}),1,'over-budget file not downloaded');
};
subtest 'underreported inbound sizes cannot exceed total memory budget' => sub {
    my ($b,$s)=fixture(settings=>{'Redmine::MaxAttachmentBytes'=>10,'Redmine::MaxAttachmentTotalBytes'=>6,'Redmine::MaxAttachmentCount'=>2});
    $s->{issues}{7}{status}{name}='Проверка решения';$s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{attachments}=[{id=>1,filename=>'one.bin',filesize=>0},{id=>2,filename=>'two.bin',filesize=>0}];
    $s->{files}{1}='AAAA';$s->{files}{2}='BBBB';
    $b->SyncTicketFromRedmine(TicketID=>1);
    is(scalar @{$s->{notes}[0]{Attachment}},1,'actual received bytes enforce aggregate cap');
};
subtest 'rejected downloads also consume the per-note attempt budget' => sub {
    my ($b,$s)=fixture(settings=>{'Redmine::MaxAttachmentBytes'=>4,'Redmine::MaxAttachmentCount'=>2});
    $s->{issues}{7}{status}{name}='Проверка решения';$s->{issues}{7}{updated_on}='2026-01-02T00:00:00Z';
    $s->{issues}{7}{attachments}=[map {{id=>$_,filename=>"$_.bin",filesize=>0}} 1..8];
    $s->{files}{$_}='TOO-LARGE' for 1..8;
    $b->SyncTicketFromRedmine(TicketID=>1);
    is(scalar(grep {$_->{Path}=~m{^/attachments/}} @{$s->{requests}}),2,'over-limit attempts are bounded');
};

subtest 'form contents are fixed before network calls and not selected by later positional IDs' => sub {
    my ($b,$s)=create_fixture();
    $s->{uploads}{form}=[{FileID=>1,Filename=>'extra.bin',Filesize=>4,Content=>'AAAA'}];
    $s->{on_request}=sub {$s->{uploads}{form}=[{FileID=>1,Filename=>'replacement.bin',Filesize=>4,Content=>'CCCC'}]};
    my %r=$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,
        DueDate=>'2026-12-01',IncludeAttachments=>0,FormID=>'form');
    ok($r{Success},'creation succeeds with fixed file snapshot');
    is_deeply($s->{uploaded},['AAAA'],'original file uploaded despite later form mutation');
};
subtest 'changed form snapshot is rejected before remote side effects' => sub {
    my ($b,$s)=create_fixture();
    $s->{uploads}{form}=[{FileID=>1,Filename=>'extra.bin',Filesize=>4,Content=>'AAAA'}];
    $s->{on_form_data}=sub {$s->{uploads}{form}=[{FileID=>1,Filename=>'new.bin',Filesize=>4,Content=>'CCCC'}]};
    my %r=$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,
        DueDate=>'2026-12-01',IncludeAttachments=>0,FormID=>'form');
    ok(!$r{Success},'changed snapshot rejected');
    is(scalar @{$s->{requests}},0,'no create or network request');
    is(scalar @{$s->{uploaded}},0,'unplanned file not sent');
};
subtest 'attachment backend exception after create preserves remote identity and prevents retry duplicates' => sub {
    my ($b,$s)=create_fixture();$s->{fail_file_read}=1;
    my %r=escalate($b);
    ok($r{Success},'created issue retained as partial success');
    is($r{IssueID},9,'remote issue ID returned');
    is($s->{tickets}{1}{DynamicField_RedmineID},9,'created issue remains linked');
    ok($r{Warning},'attachment failure visible to agent');
    ok(!$s->{cache}{'RedmineBridge:EscalateLock::1'},'lock released');
    my $posts=scalar grep {$_->{Method} eq 'POST' && $_->{Path} eq '/issues.json'} @{$s->{requests}};
    %r=escalate($b);
    is($r{Status},'linked','repeat resolves existing link');
    is(scalar(grep {$_->{Method} eq 'POST' && $_->{Path} eq '/issues.json'} @{$s->{requests}}),$posts,'no duplicate create');
};
subtest 'preflight exception returns an error and releases operation lock' => sub {
    my ($b,$s)=create_fixture();$s->{fail_form_meta}=1;
    my %r=eval {$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,
        DueDate=>'2026-12-01',IncludeAttachments=>0,FormID=>'form')};
    is($@,'','exception contained');
    ok(!$r{Success},'error result returned');
    ok(!$s->{cache}{'RedmineBridge:EscalateLock::1'},'preflight lock released');
    is(scalar @{$s->{requests}},0,'no network side effects');
};
subtest 'selected ticket attachments remain selective' => sub {
    my ($b,$s)=create_fixture();
    my %r=$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,
        DueDate=>'2026-12-01',IncludeAttachments=>1,AttachmentKeys=>['1:2']);
    ok($r{Success},'selected-file create succeeds');
    is_deeply($s->{uploaded},['BBBB'],'only selected file uploaded');
};

subtest 'FS UploadCache reported sizes do not replace actual byte checks' => sub {
    for my $limit (100,90) {
        my ($b,$s)=create_fixture();
        $s->{settings}{'Redmine::MaxAttachmentBytes'}=$limit;
        $s->{settings}{'Redmine::MaxAttachmentTotalBytes'}=$limit;
        $s->{uploads}{form}=[{FileID=>1,Filename=>'fs.bin',Filesize=>70,Content=>'F'x100}];
        my %r=$b->EscalateTicket(TicketID=>1,UserID=>2,Subject=>'T',Description=>'D',AssignedToID=>2,
            DueDate=>'2026-12-01',IncludeAttachments=>0,FormID=>'form');
        if ($limit==100) {
            ok($r{Success},'underreported FS metadata is accepted within actual budget');
            is_deeply($s->{uploaded},['F'x100],'all raw bytes uploaded');
        } else {
            ok(!$r{Success},'actual size still enforces budget');
            is(scalar @{$s->{requests}},0,'actual-size rejection before create');
        }
    }
};
done_testing();
