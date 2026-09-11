# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Redmine::Diagnostics;

use strict;
use warnings;
use utf8;

# Methods are mixed into Kernel::System::Redmine via use parent.
# $Self is the Redmine object. Use Kernel::OM normally.
# NO sub new — facade owns construction.

use LWP::UserAgent;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
    'Kernel::System::Log',
);

# Verify BaseURL + API key (optional overrides for Admin "Test connection" before save).
sub TestConnection {
    my ( $Self, %Param ) = @_;

    my ( $BaseURL, $APIKey, $Timeout, $Error ) = $Self->_AuthParams(%Param);
    return ( Success => 0, Error => $Error ) if $Error;

    my %Res = $Self->_Request(
        Method     => 'GET',
        Path       => '/users/current.json',
        BaseURL    => $BaseURL,
        APIKey     => $APIKey,
        Timeout    => $Timeout,
        ExpectJSON => 1,
    );
    return %Res if !$Res{Success};

    my $User  = $Res{Data}->{user} || {};
    my $Login = $User->{login} || $User->{mail} || $User->{id} || '?';
    my $Name  = join ' ', grep { length $_ } ( $User->{firstname}, $User->{lastname} );
    $Name ||= $Login;
    my $UID = $User->{id} // '?';

    my $RoleHint = '';
    if ( IsNumber( $User->{id} ) ) {
        my %Mem = $Self->_Request(
            Method     => 'GET',
            Path       => "/users/$User->{id}.json?include=memberships",
            BaseURL    => $BaseURL,
            APIKey     => $APIKey,
            Timeout    => $Timeout,
            ExpectJSON => 1,
        );
        if ( $Mem{Success} ) {
            my $ProjectID = $Param{ProjectID}
                // $Kernel::OM->Get('Kernel::Config')->Get('Redmine::ProjectID');
            my @Roles;
            for my $M ( @{ $Mem{Data}->{user}->{memberships} || [] } ) {
                next if IsNumber($ProjectID) && ( 0 + ( $M->{project}->{id} // 0 ) ) != ( 0 + $ProjectID );
                push @Roles, map { $_->{name} // '?' } @{ $M->{roles} || [] };
            }
            if (@Roles) {
                $RoleHint = ' Roles on project #'
                    . ( $ProjectID // '?' ) . ': '
                    . join( ', ', @Roles )
                    . '. For «Инцидент» the role must allow tracker #13 and CF 84.';
            }
            elsif ( IsNumber($ProjectID) ) {
                $RoleHint = " No membership on project #$ProjectID — cannot create issues there.";
            }
        }
    }

    return (
        Success => 1,
        Message => "API OK as $Name ($Login, #$UID).$RoleHint",
        User    => $User,
    );
}

# Admin "TLS diagnostics": SSL stack versions + handshake strategies (no API key).
sub TestTLSDiagnostics {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $CacheObject  = $Kernel::OM->Get('Kernel::System::Cache');
    my $Timeout      = $Param{Timeout} // $ConfigObject->Get('Redmine::Timeout') // 30;
    $Timeout = 15 if !length $Timeout || $Timeout > 30;

    my $BaseURL = $Param{BaseURL} // $ConfigObject->Get('Redmine::BaseURL') // '';
    $BaseURL =~ s{/\z}{};
    my $Host = $Self->_HostFromURL($BaseURL);
    my $Port = 443;
    if ( $BaseURL =~ m{\Ahttps?://[^/:]+:(\d+)}i ) {
        $Port = $1;
    }
    elsif ( $BaseURL =~ m{\Ahttp://}i ) {
        $Port = 80;
    }

    my $SSLVersion = $ConfigObject->Get('Redmine::SSLVersion');
    $SSLVersion = '(auto)' if !defined $SSLVersion || !length $SSLVersion || $SSLVersion eq 'auto';
    my $Proxy      = $ConfigObject->Get('WebUserAgent::Proxy') || '';
    my $ProxySafe  = $Self->_ScrubCredentials($Proxy);
    my $SkipVerify = $ConfigObject->Get('WebUserAgent::DisableSSLVerification') ? 1 : 0;
    my $AllowLegacy = $ConfigObject->Get('Redmine::AllowLegacyTLS') ? 1 : 0;

    my @Lines;
    push @Lines, '=== OTRS host SSL stack ===';
    push @Lines, 'Perl: ' . ( $] || '?' );
    push @Lines, 'LWP::UserAgent: ' . ( $LWP::UserAgent::VERSION // 'n/a' );

    my $IOSSLOk = eval { require IO::Socket::SSL; 1 };
    if ($IOSSLOk) {
        push @Lines, 'IO::Socket::SSL: ' . ( $IO::Socket::SSL::VERSION // '?' );
    }
    else {
        push @Lines, 'IO::Socket::SSL: NOT installed (' . ( $@ || '?' ) . ')';
    }

    my $SSLeayOk = eval { require Net::SSLeay; 1 };
    if ($SSLeayOk) {
        my $Ver = eval { Net::SSLeay::SSLeay_version(0) } || '?';
        push @Lines, "Net::SSLeay OpenSSL: $Ver";
    }
    else {
        push @Lines, 'Net::SSLeay: NOT installed';
    }

    if ( open my $FH, '-|', 'openssl', 'version' ) {
        local $/;
        my $Out = <$FH>;
        close $FH;
        $Out =~ s{\s+\z}{};
        $Out =~ s{\s+}{ }g;
        push @Lines, "openssl CLI: $Out" if length $Out;
    }
    else {
        push @Lines, 'openssl CLI: not runnable from web process';
    }

    # Compare with openssl CLI (same host often works while Perl fails).
    if ( length $Host ) {
        my $Out = '';
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 10;
            my $Pid = open my $FH, '-|';
            if ( !defined $Pid ) {
                die "fork failed\n";
            }
            if ( !$Pid ) {
                open STDIN, '<', '/dev/null' or exit 1;
                exec 'openssl', 's_client',
                    '-connect', "$Host:$Port",
                    '-tls1_2',
                    '-servername', $Host;
                exit 1;
            }
            local $/;
            $Out = <$FH> // '';
            close $FH;
            alarm 0;
            1;
        } or do {
            alarm 0;
            push @Lines, 'openssl s_client: ' . ( $@ =~ /timeout/ ? 'timeout' : 'failed' );
            $Out = '';
        };
        if ( length $Out ) {
            if ( $Out =~ m{Cipher\s*(?:is|=)\s*(\S+)}i ) {
                push @Lines, "openssl s_client -tls1_2: OK cipher=$1";
            }
            elsif ( $Out =~ m{Verify return code:\s*0} ) {
                push @Lines, 'openssl s_client -tls1_2: OK (verify 0)';
            }
            elsif ( $Out =~ m{handshake failure|alert handshake}i ) {
                push @Lines, 'openssl s_client -tls1_2: FAIL (handshake)';
            }
            else {
                push @Lines, 'openssl s_client -tls1_2: ran';
            }
        }
    }

    push @Lines, '';
    push @Lines, '=== Bridge TLS settings ===';
    push @Lines, 'BaseURL: ' . ( length $BaseURL ? $BaseURL : '(empty)' );
    push @Lines, 'Host:Port: ' . ( length $Host ? "$Host:$Port" : '(no host)' );
    push @Lines, "Redmine::SSLVersion: $SSLVersion";
    push @Lines, "Redmine::AllowLegacyTLS: $AllowLegacy";
    push @Lines, 'WebUserAgent::Proxy: ' . ( length $ProxySafe ? $ProxySafe : '(none)' );
    push @Lines, "WebUserAgent::DisableSSLVerification: $SkipVerify";

    push @Lines, '';
    push @Lines, '=== Perl handshake strategies ===';

    my $TLSOk     = 0;
    my $TLSDetail = '';
    my $Winner    = '';

    if ( !length $Host ) {
        $TLSDetail = 'No BaseURL/host to probe. Fill Redmine base URL first.';
        push @Lines, "RESULT: SKIP — $TLSDetail";
    }
    elsif ( !$IOSSLOk ) {
        $TLSDetail = 'IO::Socket::SSL missing; LWP HTTPS will not work.';
        push @Lines, "RESULT: FAIL — $TLSDetail";
    }
    else {
        my @Strategies = $Self->_SSLOptStrategies(
            ConfigObject => $ConfigObject,
            Host         => $Host,
        );

        STRATEGY:
        for my $Strategy (@Strategies) {
            my ( $Ok, $Detail ) = $Self->_ProbeSSLStrategy(
                Host    => $Host,
                Port    => $Port,
                Timeout => $Timeout,
                Opts    => $Strategy->{Opts},
            );
            if ($Ok) {
                push @Lines, "OK  [$Strategy->{Name}] $Detail";
                if ( !$TLSOk ) {
                    $TLSOk     = 1;
                    $TLSDetail = $Detail;
                    $Winner    = $Strategy->{Name};
                }
            }
            else {
                push @Lines, "FAIL[$Strategy->{Name}] $Detail";
            }
        }

        # Cache winner via shared TLS helper (AllowProbe + 1h TTL).
        $Self->_EnsureSSLStrategy(
            AllowProbe   => 1,
            ConfigObject => $ConfigObject,
            Host         => $Host,
            Port         => $Port,
            Timeout      => $Timeout,
        );

        my $Cached = $CacheObject->Get(
            Type => 'RedmineBridgeTLS',
            Key  => 'SSLStrategy::' . $Host,
        );
        if ( $Cached && length $Cached ) {
            $Winner = $Cached if !$Winner;
            push @Lines, '';
            push @Lines, "SELECTED strategy for LWP: $Winner (cached 1h)";
        }
        elsif ($TLSOk) {
            push @Lines, '';
            push @Lines, "SELECTED strategy for LWP: $Winner (report only; cache miss)";
        }
        else {
            $TLSDetail ||= 'all strategies failed';
            push @Lines, '';
            push @Lines,
                'HINT: openssl/curl OK but all Perl strategies fail → upgrade perl IO::Socket::SSL/Net::SSLeay, enable Redmine::AllowLegacyTLS, or use HTTPS proxy.';
        }
    }

    # LWP GET without API key — 401/403 still proves TLS+HTTP path.
    if ( $TLSOk && length $BaseURL && $BaseURL =~ m{\Ahttps?://}i ) {
        push @Lines, '';
        push @Lines, '=== LWP HTTP probe (no API key) ===';
        my $UA = LWP::UserAgent->new(
            timeout => $Timeout,
            agent   => 'OTRSRedmineBridge/1.0-diag',
        );
        $Self->_ApplySSLOpts(
            UserAgent    => $UA,
            ConfigObject => $ConfigObject,
            Host         => $Host,
            AllowProbe   => 1,
        );
        if ($Proxy) {
            $UA->proxy( [ 'http', 'https' ], $Proxy );
        }
        my $Resp = eval { $UA->get($BaseURL) };
        if ($Resp) {
            my $Body = $Resp->decoded_content( charset => 'none' ) // '';
            my $Snippet = substr( $Body, 0, 120 );
            $Snippet =~ s{\s+}{ }g;
            $Snippet = $Self->_ScrubCredentials($Snippet);
            push @Lines, 'HTTP ' . $Resp->code() . ' ' . ( $Resp->message() // '' );
            if ( $Resp->code() =~ m{\A50[0-9]\z} && $Snippet =~ m{handshake|Can.?t connect|SSL}i ) {
                push @Lines, "LWP still failing TLS: $Snippet";
                $TLSOk     = 0;
                $TLSDetail = $Snippet;
            }
            else {
                push @Lines, '(401/403/302 here is fine: TLS worked)';
            }
        }
        else {
            my $Detail = $@ || 'no response';
            $Detail =~ s{\s+}{ }g;
            $Detail = $Self->_ScrubCredentials($Detail);
            push @Lines, "LWP FAIL: $Detail";
            $TLSOk     = 0;
            $TLSDetail = $Detail;
        }
    }

    my $Report = join "\n", @Lines;
    if ($TLSOk) {
        return (
            Success => 1,
            Message => "TLS OK via [$Winner] to $Host:$Port ($TLSDetail).",
            Report  => $Report,
        );
    }
    return (
        Success => 0,
        Error   => 'TLS failed to ' . ( $Host || '?' ) . ":$Port ($TLSDetail).",
        Report  => $Report,
    );
}

sub TestProject {
    my ( $Self, %Param ) = @_;

    my ( $BaseURL, $APIKey, $Timeout, $Error ) = $Self->_AuthParams(%Param);
    return ( Success => 0, Error => $Error ) if $Error;

    my $ProjectID = $Param{ProjectID};
    return ( Success => 0, Error => 'Project ID is empty' ) if !IsNumber($ProjectID);

    my %Res = $Self->_Request(
        Method     => 'GET',
        Path       => "/projects/$ProjectID.json?include=trackers",
        BaseURL    => $BaseURL,
        APIKey     => $APIKey,
        Timeout    => $Timeout,
        ExpectJSON => 1,
    );
    return %Res if !$Res{Success};

    my $Project  = $Res{Data}->{project} || {};
    my $Name     = $Project->{name} // "Project #$ProjectID";
    my @Trackers = @{ $Project->{trackers} || [] };
    my $TrackerList
        = @Trackers
        ? join( ', ', map { ( $_->{name} // '?' ) . ' (#' . ( $_->{id} // '?' ) . ')' } @Trackers )
        : '(no trackers returned)';

    return (
        Success  => 1,
        Message  => "Project #$ProjectID «$Name» OK. Trackers: $TrackerList",
        Project  => $Project,
        Trackers => \@Trackers,
    );
}

sub TestTracker {
    my ( $Self, %Param ) = @_;

    my ( $BaseURL, $APIKey, $Timeout, $Error ) = $Self->_AuthParams(%Param);
    return ( Success => 0, Error => $Error ) if $Error;

    my $TrackerID = $Param{TrackerID};
    return ( Success => 0, Error => 'Tracker ID is empty' ) if !IsNumber($TrackerID);

    my $ProjectID = $Param{ProjectID};
    if ( IsNumber($ProjectID) ) {
        my %Res = $Self->_Request(
            Method     => 'GET',
            Path       => "/projects/$ProjectID.json?include=trackers",
            BaseURL    => $BaseURL,
            APIKey     => $APIKey,
            Timeout    => $Timeout,
            ExpectJSON => 1,
        );
        return %Res if !$Res{Success};

        my $ProjectName = $Res{Data}->{project}->{name} // "#$ProjectID";
        my @Trackers    = @{ $Res{Data}->{project}->{trackers} || [] };
        my ($Hit) = grep { ( $_->{id} // 0 ) == $TrackerID } @Trackers;
        if ($Hit) {
            return (
                Success => 1,
                Message => "Tracker #$TrackerID «"
                    . ( $Hit->{name} // '?' )
                    . "» is available in project «$ProjectName» (#$ProjectID).",
                Tracker => $Hit,
            );
        }

        my $Available
            = @Trackers
            ? join( ', ', map { ( $_->{name} // '?' ) . ' (#' . ( $_->{id} // '?' ) . ')' } @Trackers )
            : '(none)';
        return (
            Success => 0,
            Error   => "Tracker #$TrackerID is not enabled for project «$ProjectName» (#$ProjectID). Available: $Available",
        );
    }

    my %Res = $Self->_Request(
        Method     => 'GET',
        Path       => '/trackers.json',
        BaseURL    => $BaseURL,
        APIKey     => $APIKey,
        Timeout    => $Timeout,
        ExpectJSON => 1,
    );
    return %Res if !$Res{Success};

    my @Trackers = @{ $Res{Data}->{trackers} || [] };
    my ($Hit) = grep { ( $_->{id} // 0 ) == $TrackerID } @Trackers;
    if ($Hit) {
        return (
            Success => 1,
            Message => "Tracker #$TrackerID «"
                . ( $Hit->{name} // '?' )
                . '» exists in Redmine (set Project ID to verify it is enabled for that project).',
            Tracker => $Hit,
        );
    }
    return ( Success => 0, Error => "Tracker #$TrackerID not found in Redmine." );
}

1;
