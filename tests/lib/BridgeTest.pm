package BridgeTest;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use DBI;
use JSON::PP;
use StoreTest qw(store_fixture);
use Kernel::System::Redmine;
our @EXPORT_OK = qw(fixture);

sub fixture {
    my (%args) = @_;
    my $s = bless {
        settings => {
            'Redmine::Enabled' => 1, 'Redmine::InboundSync' => 1,
            'Redmine::SyncAttachments' => 1, 'Redmine::SyncBatchLimit' => 50,
            'Redmine::BaseURL' => 'http://redmine.test', 'Redmine::APIKey' => 'test-only',
            'Redmine::StatusSync' => { 'Проверка решения' => 'open|note' },
            'Redmine::MaxAttachmentBytes' => 5000000,
            'Redmine::MaxAttachmentTotalBytes' => 20000000,
            'Redmine::MaxAttachmentCount' => 20,
            'Redmine::ProjectID' => 1, 'Redmine::TrackerID' => 2,
            %{ $args{settings} || {} },
        },
        tickets => {}, cache => {}, requests => [], gets => [], writes => [],
        notes => [], states => [], logs => [], issues => {}, files => {},
        uploads => {}, uploaded => [], fail_article => 0,
    }, 'BridgeTest::Services';
    my ($stores,$dbs,$dml,$dir)=store_fixture();
    $s->{dbh}=$dbs->[0];$s->{store}=$stores->[0];$s->{store_support}=[$dbs,$dir];
    $s->{dbh}->do('CREATE TABLE ticket (id INTEGER PRIMARY KEY, archive_flag INTEGER DEFAULT 0)');
    $s->{dbh}->do('CREATE TABLE dynamic_field (id INTEGER PRIMARY KEY, name TEXT, object_type TEXT)');
    $s->{dbh}->do('CREATE TABLE dynamic_field_value (field_id INTEGER, object_id INTEGER, value_text TEXT)');
    $s->{dbh}->do("INSERT INTO dynamic_field VALUES (1, 'RedmineID', 'Ticket')");
    for my $id (1 .. ($args{count} || 1)) {
        my $issue = $args{unique} ? $id : 7;
        $s->{tickets}{$id} = {
            TicketID => $id, TicketNumber => "T$id", Title => "Ticket $id", OwnerID => 2, ResponsibleID => 3,
            DynamicField_RedmineID => "$issue", DynamicField_RedmineStatus => 'New',
            DynamicField_RedmineLastUpdatedOn => '2026-01-01T00:00:00Z',
            DynamicField_RedmineLastAttachmentSyncOn => '2026-01-01T00:00:00Z',
            DynamicField_RedmineLastJournalID => '10', DynamicField_RedmineLastAttachmentID => '0',
        };
        $s->{dbh}->do('INSERT INTO ticket (id) VALUES (?)', undef, $id);
        $s->{dbh}->do('INSERT INTO dynamic_field_value VALUES (1, ?, ?)', undef, $id, "$issue");
        $s->{issues}{$issue} = { id => $issue, status => { name => 'New' }, updated_on => '2026-01-01T00:00:00Z', journals => [], attachments => [] };
    }
    $Kernel::OM = $s;
    return (BridgeTest::Bridge->new(), $s);
}

package BridgeTest::Services;
use strict;
use warnings;
sub Get {
    my ($s, @a) = @_;
    return $s->{store} if @a == 1 && $a[0] eq 'Kernel::System::Redmine::SyncStore';
    return $s if @a == 1 && $a[0] =~ /^Kernel::/;
    return $s->{settings}{$a[0]} if @a == 1;
    my %p = @a;
    return $s->{cache}{"$p{Type}:$p{Key}"};
}
sub Set { my ($s,%p)=@_; $s->{cache}{"$p{Type}:$p{Key}"}=$p{Value}; return 1 }
sub Delete { my ($s,%p)=@_; delete $s->{cache}{"$p{Type}:$p{Key}"}; return 1 }
sub Connect { return $_[0]{dbh} }
sub _TicketCacheClear { return 1 }
sub TicketGet { my ($s,%p)=@_; push @{$s->{gets}},$p{TicketID}; return %{$s->{tickets}{$p{TicketID}} || {}} }
sub TicketSearch {
    my ($s,%p)=@_; my @ids=sort {$a<=>$b} keys %{$s->{tickets}};
    @ids=grep { length($s->{tickets}{$_}{DynamicField_RedmineID} || '') } @ids;
    splice @ids,$p{Limit} if $p{Limit} && @ids>$p{Limit}; return @ids;
}
sub DynamicFieldGet { my ($s,%p)=@_; return { ID => 1, Name => $p{Name}, ObjectType => 'Ticket' } }
sub ValueSet {
    my ($s,%p)=@_; my $name=$p{DynamicFieldConfig}{Name};
    push @{$s->{writes}},[$p{ObjectID},$name,$p{Value}];
    $s->{tickets}{$p{ObjectID}}{"DynamicField_$name"}=$p{Value}; return 1;
}
sub ValueGet { my ($s,%p)=@_; return $s->{tickets}{$p{ObjectID}}{'DynamicField_'.$p{DynamicFieldConfig}{Name}} }
sub TicketStateSet { my ($s,%p)=@_; push @{$s->{states}},\%p; $s->{tickets}{$p{TicketID}}{State}=$p{State}; return 1 }
sub BackendForChannel { return $_[0] }
sub ArticleCreate { my ($s,%p)=@_; return if $s->{fail_article}; $p{ObservedState}=$s->{tickets}{$p{TicketID}}{State}; push @{$s->{notes}},\%p; return scalar @{$s->{notes}} }
sub ArticleWriteAttachment { my ($s,%p)=@_; return if $s->{fail_attachment_write}; push @{$s->{notes}[$p{ArticleID}-1]{Attachment}}, {map {$_=>$p{$_}} qw(Content ContentType Filename)}; return 1 }
sub Encode { my ($s,%p)=@_; return JSON::PP->new->encode($p{Data}) }
sub Decode { my ($s,%p)=@_; return eval { JSON::PP->new->decode($p{Data}) } }
sub Log { my ($s,%p)=@_; push @{$s->{logs}},\%p; return 1 }
sub ToAscii { my ($s,%p)=@_; $s->{ascii_calls}++; (my $v=$p{String}) =~ s/<[^>]*>//g; return $v }
sub Prepare {
    my ($s,%p)=@_; return if $s->{fail_select}; my $sql=$p{SQL}; $sql.=' LIMIT '.int($p{Limit}) if $p{Limit};
    $s->{sth}=$s->{dbh}->prepare($sql); $s->{sth}->execute(map { $$_ } @{$p{Bind} || []}); return 1;
}
sub FetchrowArray { return $_[0]{sth}->fetchrow_array() }
sub FormIDGetAllFilesMeta {
    my ($s,%p)=@_; die 'metadata unavailable' if $s->{fail_form_meta}; return map { my %f=%$_; delete $f{Content}; \%f } @{$s->{uploads}{$p{FormID}} || []};
}
sub FormIDGetAllFilesData { my ($s,%p)=@_; $s->{on_form_data}->() if $s->{on_form_data}; return @{$s->{uploads}{$p{FormID}} || []} }
sub ArticleList { return () }
sub BackendForArticle { return $_[0] }
sub ArticleAttachment { my ($s,%p)=@_; push @{$s->{file_events}},'read'; die 'backend unavailable' if $s->{fail_file_read}; return %{$s->{article_files}{"$p{ArticleID}:$p{FileID}"} || {}} }
sub GetUserData { return (UserLogin => 'agent') }
sub HistoryAdd { return 1 }

package BridgeTest::Bridge;
use strict;
use warnings;
use parent 'Kernel::System::Redmine';
sub WarmCatalog { return (Success => 1) }
sub _Request {
    my ($self,%p)=@_; my $s=$Kernel::OM; push @{$s->{requests}},\%p;
    $s->{on_request}->(\%p) if $s->{on_request};
    if ($p{Path} eq '/issue_statuses.json') {
        return (Success=>0,Error=>'status catalog unavailable') if $s->{fail_statuses};
        return (Success=>1,Data=>{issue_statuses=>[{id=>1,name=>'New'},{id=>2,name=>'Проверка решения'},{id=>3,name=>'Closed'}]});
    }
    if ($p{Path} =~ m{^/issues/(\d+)\.json}) {
        return (Success => 0, Error => 'unavailable') if $s->{fail_issue} || ($s->{fail_details} && $p{Path}=~/include/);
        my $issue=$s->{issues}{$1};
        return (Success => 0, Error => 'not found') if !$issue;
        my %copy=%$issue;
        delete $copy{journals} if $p{Path}!~/include=.*journals/;
        delete $copy{attachments} if $p{Path}!~/include=.*attachments/;
        return (Success => 1, Data => { issue => \%copy }, BaseURL => 'http://redmine.test');
    }
    if ($p{Path} =~ m{^/attachments/download/(\d+)}) {
        my $bytes=$s->{files}{$1};
        return (Success => 0, Error => 'download failed') if !defined $bytes;
        if (defined $p{MaxResponseBytes} && length($bytes)>$p{MaxResponseBytes}) {
            return (Success=>0,TooLarge=>1,Error=>'too large');
        }
        if ($p{ContentFile}) { print {$p{ContentFile}} $bytes; return (Success=>1,ContentLength=>length($bytes)) }
        return (Success=>1,Content=>$bytes);
    }
    if ($p{Path}=~m{^/projects/}) {
        return (Success=>1,Data=>{project=>{trackers=>[{id=>2,name=>'Task'}]}});
    }
    if ($p{Path} eq '/enumerations/issue_priorities.json') {
        return (Success=>1,Data=>{issue_priorities=>[{id=>2,name=>'Normal',is_default=>1}]});
    }
    if ($p{Path} eq '/issues.json'  && $p{Method} eq 'POST') {
        $s->{issues}{9}={ id=>9,tracker=>{id=>2,name=>'Task'},journals=>[],attachments=>[] };
        return (Success=>1,Data=>{issue=>$s->{issues}{9}},BaseURL=>'http://redmine.test');
    }
    if ($p{Path}=~m{^/uploads.json}) {
        push @{$s->{file_events}},'upload'; push @{$s->{uploaded}},$p{RawContent};
        return (Success=>1,Data=>{upload=>{token=>'token'.scalar(@{$s->{uploaded}})}});
    }
    die "Unexpected test HTTP path: $p{Path}";
}
sub ListEscalateAttachments { return @{ $Kernel::OM->{attachment_meta} || [] } }
1;
