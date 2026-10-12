use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/..";
use Test::More;
use HTTP::Daemon;
use HTTP::Response;
use HTTP::Date qw(time2str);
use File::Temp;
use BridgeTest qw(fixture);

my $server=HTTP::Daemon->new(LocalAddr=>'127.0.0.1',LocalPort=>0,ReuseAddr=>1) or die $!;
my $url=$server->url;$url=~s{/$}{};
my $pid=fork();die $! if !defined $pid;
if (!$pid) {
    $SIG{TERM}=sub {exit 0};$SIG{PIPE}='IGNORE';
    my $connection=0;
    my $requests=0;
    while (my $c=$server->accept) {
        $connection++;
        while (my $r=$c->get_request) {
            $requests++;
            if ($r->uri->path =~ m{^/status/(\d+)$}) {
                my $code=$1;
                my $retry=$r->uri->query;
                my @headers=('Content-Type'=>'application/json');
                push @headers, 'Retry-After'=>($retry eq 'date' ? time2str(time()+30) : $retry)
                    if defined $retry;
                $c->send_response(HTTP::Response->new($code,'API error',\@headers,'{"error":"busy"}'));
                next;
            }
            if ($r->uri->path eq '/identity') {
                my $body=JSON::PP->new->encode({connection=>$connection,requests=>$requests,key=>$r->header('X-Redmine-API-Key')});
                $c->send_response(HTTP::Response->new(200,'OK',['Content-Type'=>'application/json'],$body));
                next;
            }
            if ($r->uri->path eq '/truncated') {
                print {$c} "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nABCD";
                last;
            }
            my $body=$r->uri->path eq '/binary' ? "\x00\xff\x80A" : ('X'x100000);
            $c->send_response(HTTP::Response->new(200,'OK',['Content-Type'=>'application/octet-stream'],$body));
        }
        $c->close;
    }
    exit 0;
}
close $server;
END { if ($pid) {kill 'TERM',$pid;waitpid($pid,0)} }
local $ENV{no_proxy}='127.0.0.1';
my (undef,$services)=fixture(settings=>{'Redmine::BaseURL'=>$url});
my $b=Kernel::System::Redmine->new();
subtest 'binary transport preserves octets' => sub {
    my %r=$b->_Request(Method=>'GET',Path=>'/binary',ExpectJSON=>0,MaxResponseBytes=>10);
    ok($r{Success},'download succeeds');is($r{Content},"\x00\xff\x80A",'binary bytes unchanged');
};
subtest 'streaming aborts oversized body even with HTTP 200' => sub {
    my $file=File::Temp->new();binmode $file;
    my %r=$b->_Request(Method=>'GET',Path=>'/large',ExpectJSON=>0,MaxResponseBytes=>1024,ContentFile=>$file);
    ok(!$r{Success},'partial response is not success');ok($r{TooLarge},'size error distinguished');
    cmp_ok(-s $file,'<=',1024,'spool never exceeds requested limit');
};
subtest 'streaming returns exact bytes to the spool' => sub {
    my $file=File::Temp->new();binmode $file;
    my %r=$b->_Request(Method=>'GET',Path=>'/binary',ExpectJSON=>0,MaxResponseBytes=>10,ContentFile=>$file);
    ok($r{Success},'bounded spool succeeds');seek $file,0,0;local $/;is(<$file>,"\x00\xff\x80A",'spool is binary intact');
};
subtest 'truncated HTTP 200 is a retryable download failure' => sub {
    my %r=$b->_Request(Method=>'GET',Path=>'/truncated',ExpectJSON=>0,MaxResponseBytes=>1000);
    ok(!$r{Success},'short body never becomes an attachment');
};
subtest 'operation-scoped client reuses connections and current authentication' => sub {
    my $last;
    {
        local $b->{_RequestScope}={};
        my %first=$b->_Request(Method=>'GET',Path=>'/identity');
        $services->{settings}{'Redmine::APIKey'}='rotated-test-only';
        my %second=$b->_Request(Method=>'GET',Path=>'/identity');
        is($second{Data}{connection},$first{Data}{connection},'same operation reuses TCP connection');
        is($second{Data}{key},'rotated-test-only','headers use current service key');
        $services->{settings}{'Redmine::Timeout'}=2;
        my %changed=$b->_Request(Method=>'GET',Path=>'/identity');
        isnt($changed{Data}{connection},$second{Data}{connection},'changed connection settings rebuild client');
        $last=$changed{Data}{connection};
    }
    my %outside=$b->_Request(Method=>'GET',Path=>'/identity');
    isnt($outside{Data}{connection},$last,'client does not survive operation scope');
};
subtest 'a binary response limit never leaks into a later JSON request' => sub {
    local $b->{_RequestScope}={};
    my %binary=$b->_Request(Method=>'GET',Path=>'/binary',ExpectJSON=>0,MaxResponseBytes=>4);
    ok($binary{Success},'bounded binary succeeds');
    my %json=$b->_Request(Method=>'GET',Path=>'/identity');
    ok($json{Success} && $json{Data}{connection},'complete JSON response follows bounded binary');
};

sub cooldown_state {
    my @states=map {$services->{cache}{$_}} grep {/^RedmineBridgeHTTP:/} keys %{$services->{cache}};
    is(scalar @states,1,'one shared cooldown cache entry');
    return $states[0];
}
sub clear_cooldown {
    delete $services->{cache}{$_} for grep {/^RedmineBridgeHTTP:/} keys %{$services->{cache}};
}
subtest 'numeric Retry-After is shared across instances and blocks all network requests' => sub {
    clear_cooldown();
    my %before=$b->_Request(Path=>'/identity');
    my %busy=$b->_Request(Path=>'/status/429?12');
    ok(!$busy{Success} && $busy{Retryable},'429 is a retryable error');
    is($busy{HTTPCode},429,'original status returned');
    cmp_ok($busy{RetryAfterSeconds},'>=',11,'numeric Retry-After used');
    cmp_ok($busy{RetryAfterSeconds},'<=',12,'numeric delay is bounded to its remaining time');
    my $other=Kernel::System::Redmine->new();
    my %blocked=$other->_Request(Path=>'/identity');
    ok(!$blocked{Success} && $blocked{Retryable},'another client is blocked by shared cooldown');
    is($blocked{HTTPCode},429,'blocked return retains retryable HTTP status');
    my $state=cooldown_state() || {};
    {
        $state->{OpenUntil}=time()+5;
        my %remaining=$other->_Request(Path=>'/identity');
        cmp_ok($remaining{RetryAfterSeconds},'>=',4,'returns remaining delay rather than original header');
        cmp_ok($remaining{RetryAfterSeconds},'<=',5,'remaining delay is current');
        $state->{OpenUntil}=time()-1;
        my %after=$other->_Request(Path=>'/identity');
        ok($after{Success},'expiry permits retry');
        is($after{Data}{requests},$before{Data}{requests}+2,'blocked calls made zero network requests');
        is(scalar(grep {/^RedmineBridgeHTTP:/} keys %{$services->{cache}}),0,'success clears cooldown and failure count');
    }
};
subtest 'HTTP-date Retry-After and oversized delays are bounded' => sub {
    clear_cooldown();
    my %date=$b->_Request(Path=>'/status/429?date');
    cmp_ok($date{RetryAfterSeconds},'>=',28,'HTTP-date delay is parsed');
    cmp_ok($date{RetryAfterSeconds},'<=',30,'HTTP-date delay is relative to current time');
    clear_cooldown();
    my %large=$b->_Request(Path=>'/status/429?9999999999999999999999999999999999');
    cmp_ok($large{RetryAfterSeconds},'>=',3599,'long Retry-After still waits');
    cmp_ok($large{RetryAfterSeconds},'<=',3600,'Retry-After never exceeds one hour');
};
subtest 'transient reachable errors use bounded exponential backoff and success resets it' => sub {
    local $SIG{__WARN__}=sub {die "unexpected warning: @_"};
    clear_cooldown();
    for my $delay (2,4,8,16,32,60,60) {
        my %busy=$b->_Request(Path=>'/status/503');
        ok(!$busy{Success} && $busy{Retryable},'503 is retryable');
        cmp_ok($busy{RetryAfterSeconds},'>=',$delay-1,'remaining backoff follows exponential delay');
        cmp_ok($busy{RetryAfterSeconds},'<=',$delay,'backoff is capped at its selected delay');
        my $state=cooldown_state();
        $state->{OpenUntil}=time()-1 if $state;
    }
    my %success=$b->_Request(Path=>'/identity');
    ok($success{Success},'success after expiry');
    my %reset=$b->_Request(Path=>'/status/503');
    cmp_ok($reset{RetryAfterSeconds},'>=',1,'success resets remaining delay to initial backoff');
    cmp_ok($reset{RetryAfterSeconds},'<=',2,'success resets failure count');
    clear_cooldown();
    for my $code (502,504) {
        my %busy=$b->_Request(Path=>"/status/$code?invalid");
        ok($busy{Retryable},"HTTP $code is retryable");
        cmp_ok($busy{RetryAfterSeconds},'>=',1,'invalid header retains initial backoff');
        cmp_ok($busy{RetryAfterSeconds},'<=',2,'invalid header uses initial backoff');
        clear_cooldown();
    }
};
subtest 'ordinary HTTP errors have no shared cooldown' => sub {
    clear_cooldown();
    for my $code (401,403,404) {
        my %error=$b->_Request(Path=>"/status/$code?60");
        ok(!$error{Success},"HTTP $code remains an error");
        ok(!$error{RetryAfterSeconds},"HTTP $code ignores Retry-After");
        my %next=$b->_Request(Path=>'/identity');
        ok($next{Success},"HTTP $code does not block another issue request");
    }
};
subtest 'cooldown scope separates credentials and base paths without caching secrets' => sub {
    clear_cooldown();
    my %busy=$b->_Request(Path=>'/status/503',APIKey=>'cooldown-test-secret');
    ok($busy{Retryable},'scoped error recorded');
    my %other_key=$b->_Request(Path=>'/identity',APIKey=>'other-test-secret');
    ok($other_key{Success},'different credential scope can request');
    my %other_base=$b->_Request(BaseURL=>"$url/other",Path=>'/binary',APIKey=>'cooldown-test-secret',ExpectJSON=>0,MaxResponseBytes=>200000);
    ok($other_base{Success},'different Redmine base path can request');
    unlike(join(' ',keys %{$services->{cache}}),qr/cooldown-test-secret/,'cache keys never contain API credentials');
    clear_cooldown();
};
subtest 'cooldown cache always reads and writes the shared backend' => sub {
    clear_cooldown();
    my @calls;
    my $get=\&BridgeTest::Services::Get;
    my $set=\&BridgeTest::Services::Set;
    no warnings 'redefine';
    local *BridgeTest::Services::Get=sub {
        if (@_ > 2) {
            my (undef,%p)=@_;
            push @calls,\%p if $p{Type} eq 'RedmineBridgeHTTP';
        }
        return $get->(@_);
    };
    local *BridgeTest::Services::Set=sub {
        my (undef,%p)=@_;
        push @calls,\%p if $p{Type} eq 'RedmineBridgeHTTP';
        return $set->(@_);
    };
    my %busy=$b->_Request(Path=>'/status/503');
    my %blocked=$b->_Request(Path=>'/identity');
    ok($busy{Retryable} && $blocked{Retryable},'initial and blocked calls covered');
    is(scalar @calls,4,'two initial reads, one state write and one blocked read');
    for my $call (@calls) {
        is($call->{CacheInMemory},0,'process-local cached state is bypassed');
        is($call->{CacheInBackend},1,'shared persistent cache is used');
    }
    clear_cooldown();
};
subtest 'a completed in-flight success preserves a newer shared cooldown' => sub {
    clear_cooldown();
    my $original=\&LWP::UserAgent::request;
    no warnings 'redefine';
    local *LWP::UserAgent::request=sub {
        my $response=$original->(@_);
        # Another worker receives a 429 while this successful request is in flight.
        $services->Set(Type=>'RedmineBridgeHTTP',
            Key=>$b->_HTTPCooldownKey(BaseURL=>$url,APIKey=>$services->{settings}{'Redmine::APIKey'}),
            Value=>{Count=>4,OpenUntil=>time()+60,HTTPCode=>429},TTL=>7200);
        return $response;
    };
    my %success=$b->_Request(Path=>'/identity');
    ok($success{Success},'in-flight successful response remains successful');
    my %next=$b->_Request(Path=>'/identity');
    ok(!$next{Success} && $next{Retryable},'newer failure still blocks following requests');
    is($next{HTTPCode},429,'newer failure status retained');
    cmp_ok($next{RetryAfterSeconds} || 0,'>=',59,'newer delay is retained');
    clear_cooldown();
};
subtest 'active ticket lease is checked before and after real HTTP' => sub {
    clear_cooldown();
    my @order;
    my $original=\&LWP::UserAgent::request;
    no warnings 'redefine';
    local *Kernel::System::Redmine::_CheckTicketSyncLease=sub {push @order,'lease';return 1};
    local *LWP::UserAgent::request=sub {push @order,'network';return $original->(@_)};
    local $b->{_TicketSyncLease}={};
    my %success=$b->_Request(Path=>'/identity');
    ok($success{Success},'valid active lease permits request');
    is_deeply(\@order,[qw(lease network lease)],'lease fenced on both sides of network IO');
    @order=();
    local *Kernel::System::Redmine::_CheckTicketSyncLease=sub {
        push @order,'lease';die "Controlled lease loss\n";
    };
    my $ok=eval {$b->_Request(Path=>'/identity');1};
    ok(!$ok && $@ =~ /Controlled lease loss/,'lost lease aborts before request');
    is_deeply(\@order,['lease'],'lost lease causes zero network calls');
    @order=();
    my $checks=0;
    local *Kernel::System::Redmine::_CheckTicketSyncLease=sub {
        push @order,'lease';die "Controlled lease loss\n" if ++$checks==2;return 1;
    };
    $ok=eval {$b->_Request(Path=>'/identity');1};
    ok(!$ok && $@ =~ /Controlled lease loss/,'lease lost during HTTP rejects its completed response');
    is_deeply(\@order,[qw(lease network lease)],'completed network response is fenced before returning');
};
done_testing();
