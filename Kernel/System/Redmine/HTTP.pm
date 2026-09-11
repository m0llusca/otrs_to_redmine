# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Redmine::HTTP;

use strict;
use warnings;
use utf8;

# Methods are mixed into Kernel::System::Redmine via use parent.
# $Self is the Redmine object. Use Kernel::OM normally.
# NO sub new — facade owns construction.

use HTTP::Request;
use LWP::UserAgent;
use Encode qw();
use URI::Escape qw(uri_escape);

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
    'Kernel::System::Encode',
    'Kernel::System::JSON',
    'Kernel::System::Log',
);

# curl/openssl on Xenial often work (TLS1.2 + ECDHE-RSA-AES128-GCM-SHA256) while a naive
# IO::Socket::SSL ClientHello is rejected. Try TLS1.2+ opt sets by default; cache the winner.
sub _SSLOptStrategies {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Param{ConfigObject} || $Kernel::OM->Get('Kernel::Config');
    my $Host         = $Param{Host}         || '';
    my $Configured   = $ConfigObject->Get('Redmine::SSLVersion');
    $Configured = '' if !defined $Configured;

    # Cipher that curl reports on Redmine: ECDHE_RSA_AES_128_GCM_SHA256
    my $Ciphers
        = 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:'
        . 'ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:'
        . 'HIGH:!aNULL:!MD5:!RC4:!3DES';

    my @Strategies;

    # Explicit SysConfig override first (empty/auto = try list below)
    if ( length $Configured && $Configured ne 'auto' ) {
        push @Strategies, {
            Name => "config:$Configured",
            Opts => {
                SSL_version     => $Configured,
                SSL_cipher_list => $Ciphers,
            },
        };
    }

    # Default: TLS1.2+ only (no sslv23 / bare default).
    push @Strategies, (
        {
            Name => 'tls12+ecdhe',
            Opts => {
                SSL_version     => 'TLSv1_2',
                SSL_cipher_list => $Ciphers,
            },
        },
        {
            Name => 'tls12-only',
            Opts => { SSL_version => 'TLSv1_2' },
        },
    );

    if ( $ConfigObject->Get('Redmine::AllowLegacyTLS') ) {
        push @Strategies, (
            {
                Name => 'sslv23+ecdhe',
                Opts => {
                    SSL_version     => 'SSLv23:!SSLv2:!SSLv3',
                    SSL_cipher_list => $Ciphers,
                },
            },
            {
                Name => 'default+ecdhe',
                Opts => { SSL_cipher_list => $Ciphers },
            },
            {
                Name => 'default',
                Opts => {},
            },
        );
    }

    my $SkipVerify = $ConfigObject->Get('WebUserAgent::DisableSSLVerification') ? 1 : 0;

    for my $Strategy (@Strategies) {
        my %Opts = %{ $Strategy->{Opts} };
        if ($Host) {
            $Opts{SSL_hostname}        = $Host;
            $Opts{SSL_verifycn_name}   = $Host;
            $Opts{SSL_verifycn_scheme} = 'http';
        }
        if ($SkipVerify) {
            $Opts{verify_hostname} = 0;
            $Opts{SSL_verify_mode} = 0;
        }
        $Strategy->{Opts} = \%Opts;
    }

    return @Strategies;
}

sub _ApplySSLOpts {
    my ( $Self, %Param ) = @_;

    my $UserAgent    = $Param{UserAgent}    || return;
    my $ConfigObject = $Param{ConfigObject} || $Kernel::OM->Get('Kernel::Config');
    my $Host         = $Param{Host}         || '';

    $Self->_EnsureSSLStrategy(
        ConfigObject => $ConfigObject,
        Host         => $Host,
        Port         => $Param{Port} || 443,
        Timeout      => $Param{Timeout} || 10,
        AllowProbe   => $Param{AllowProbe} ? 1 : 0,
    );

    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $CacheKey    = 'SSLStrategy::' . ( $Host || 'default' );
    my $CachedName  = $CacheObject->Get(
        Type => 'RedmineBridgeTLS',
        Key  => $CacheKey,
    );

    my @Strategies = $Self->_SSLOptStrategies(
        ConfigObject => $ConfigObject,
        Host         => $Host,
    );

    my %Opts;
    if ($CachedName) {
        for my $Strategy (@Strategies) {
            if ( $Strategy->{Name} eq $CachedName ) {
                %Opts = %{ $Strategy->{Opts} };
                last;
            }
        }
    }
    if ( !%Opts ) {
        %Opts = %{ $Strategies[0]->{Opts} };
    }

    $UserAgent->ssl_opts(%Opts);
    return 1;
}

# Probe strategies once per host and cache the first that works.
# Probing only when AllowProbe (Admin TLS diagnostics). Frontend path: use first TLS1.2 strategy.
sub _EnsureSSLStrategy {
    my ( $Self, %Param ) = @_;

    my $Host = $Param{Host} || return;
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $CacheKey    = 'SSLStrategy::' . $Host;

    return 1 if $CacheObject->Get( Type => 'RedmineBridgeTLS', Key => $CacheKey );

    # Frontend-safe: no handshake probes — _ApplySSLOpts uses first TLS1.2 strategy.
    return 1 if !$Param{AllowProbe};

    return if !eval { require IO::Socket::SSL; 1 };

    my @Strategies = $Self->_SSLOptStrategies(
        ConfigObject => $Param{ConfigObject},
        Host         => $Host,
    );

    for my $Strategy (@Strategies) {
        my ( $Ok, undef ) = $Self->_ProbeSSLStrategy(
            Host    => $Host,
            Port    => $Param{Port} || 443,
            Timeout => $Param{Timeout} || 10,
            Opts    => $Strategy->{Opts},
        );
        if ($Ok) {
            $CacheObject->Set(
                Type  => 'RedmineBridgeTLS',
                Key   => $CacheKey,
                Value => $Strategy->{Name},
                TTL   => 60 * 60,    # 1 hour
            );
            return 1;
        }
    }
    return;
}

sub _ProbeSSLStrategy {
    my ( $Self, %Param ) = @_;

    my $Host    = $Param{Host}    || return;
    my $Port    = $Param{Port}    || 443;
    my $Timeout = $Param{Timeout} || 15;
    my $Opts    = $Param{Opts}    || {};

    return ( 0, 'IO::Socket::SSL missing' ) if !eval { require IO::Socket::SSL; 1 };

    my $Sock = IO::Socket::SSL->new(
        PeerHost => $Host,
        PeerPort => $Port,
        Timeout  => $Timeout,
        %{$Opts},
    );
    if ( !$Sock ) {
        my $Err = $IO::Socket::SSL::SSL_ERROR || $! || 'unknown';
        $Err =~ s{\s+}{ }g;
        $Err = $Self->_ScrubCredentials($Err);
        return ( 0, $Err );
    }

    my $Proto  = eval { $Sock->get_sslversion() } // '?';
    my $Cipher = eval { $Sock->get_cipher() }     // '?';
    close $Sock;
    return ( 1, "protocol=$Proto cipher=$Cipher" );
}

sub _HostFromURL {
    my ( $Self, $URL ) = @_;
    return '' if !defined $URL || !length $URL;
    if ( $URL =~ m{\Ahttps?://([^/:]+)}i ) {
        return $1;
    }
    return '';
}

# Strip user:pass from URLs that may appear in errors / proxy config display.
sub _ScrubCredentials {
    my ( $Self, $Text ) = @_;
    return '' if !defined $Text;
    $Text =~ s{://[^/\s:@]+:[^/\s@]+@}{://***:***@}g;
    return $Text;
}

sub _UnreachableError {
    my ( $Self, %Param ) = @_;

    my $BaseURL = $Self->_ScrubCredentials( $Param{BaseURL} || '' );
    my $Detail  = $Self->_ScrubCredentials( $Param{Detail}  || '' );

    if ( $Detail =~ m{handshake\s+failure|SSL23_GET_SERVER_HELLO|sslv3\s+alert|SSL[_ ]connect}i ) {
        return
            "TLS handshake with Redmine failed at $BaseURL ($Detail). "
            . "curl/openssl may still work — Perl SSL opts differ. "
            . "Use Admin → TLS diagnostics (tries several strategies). "
            . "Optional SysConfig: Redmine::SSLVersion=auto|TLSv1_2; Redmine::AllowLegacyTLS for older stacks.";
    }

    return
        "Cannot reach Redmine at $BaseURL ($Detail). "
        . "Check DNS/firewall/proxy from the OTRS host (SysConfig WebUserAgent::Proxy if needed).";
}

# Return relative path starting with / if URL host matches BaseURL host, or if already relative.
sub _SafeRelativePath {
    my ( $Self, $URLOrPath, $BaseURL ) = @_;

    return if !defined $URLOrPath || !IsStringWithData($URLOrPath);

    # Already relative (no scheme)
    if ( $URLOrPath !~ m{\Ahttps?://}i ) {
        my $Path = $URLOrPath;
        $Path =~ s{\A\s+}{};
        $Path =~ s{\s+\z}{};
        return if !length $Path;
        $Path = '/' . $Path if $Path !~ m{\A/};
        return $Path;
    }

    my $Base = defined $BaseURL ? $BaseURL : '';
    $Base =~ s{/\z}{};
    return if !length $Base;

    my $BaseHost = $Self->_HostFromURL($Base);
    my $URLHost  = $Self->_HostFromURL($URLOrPath);
    return if !length $BaseHost || !length $URLHost;
    return if lc($BaseHost) ne lc($URLHost);

    my $Path = $URLOrPath;
    $Path =~ s{\A\Q$Base\E}{};
    $Path = '/' . $Path if !length $Path || $Path !~ m{\A/};
    return $Path;
}

sub _CircuitKey {
    my ( $Self, $Host ) = @_;
    return 'Circuit::' . ( $Host || 'default' );
}

sub _CircuitIsOpen {
    my ( $Self, %Param ) = @_;

    my $Host        = $Param{Host} || '';
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $Circuit     = $CacheObject->Get(
        Type => 'RedmineBridgeTLS',
        Key  => $Self->_CircuitKey($Host),
    );
    return if !IsHashRefWithData($Circuit);

    my $OpenUntil = $Circuit->{OpenUntil} || 0;
    return if !$OpenUntil || time() >= $OpenUntil;

    my $Wait = $OpenUntil - time();
    $Wait = 1 if $Wait < 1;
    return "Redmine temporarily unreachable ($Host): circuit open after repeated failures; retry in ${Wait}s.";
}

sub _CircuitRecordFailure {
    my ( $Self, %Param ) = @_;

    my $Host        = $Param{Host} || '';
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $Key         = $Self->_CircuitKey($Host);
    my $Circuit     = $CacheObject->Get( Type => 'RedmineBridgeTLS', Key => $Key );
    $Circuit = {} if !IsHashRefWithData($Circuit);

    my $Count = ( $Circuit->{Count} || 0 ) + 1;
    my %New   = ( Count => $Count );
    if ( $Count >= 3 ) {
        $New{OpenUntil} = time() + 60;
        $New{Count}     = 0;
    }

    $CacheObject->Set(
        Type  => 'RedmineBridgeTLS',
        Key   => $Key,
        Value => \%New,
        TTL   => 120,
    );
    return 1;
}

sub _CircuitClear {
    my ( $Self, %Param ) = @_;

    my $Host        = $Param{Host} || '';
    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    $CacheObject->Delete(
        Type => 'RedmineBridgeTLS',
        Key  => $Self->_CircuitKey($Host),
    );
    return 1;
}

sub _Request {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');
    my $JSONObject   = $Kernel::OM->Get('Kernel::System::JSON');

    my $BaseURL = $Param{BaseURL} // $ConfigObject->Get('Redmine::BaseURL') // '';
    $BaseURL =~ s{/\z}{};
    my $APIKey  = $Param{APIKey}  // $ConfigObject->Get('Redmine::APIKey')  // '';
    my $Timeout = $Param{Timeout} // $ConfigObject->Get('Redmine::Timeout') // 30;

    if ( !$BaseURL || !$APIKey ) {
        return ( Success => 0, Error => 'Redmine::BaseURL or Redmine::APIKey is not configured' );
    }

    my $Method = $Param{Method} || 'GET';
    my $Path   = $Param{Path}   || '';
    if ( !length $Path ) {
        $Path = '/';
    }
    elsif ( $Path !~ m{\A/} ) {
        return ( Success => 0, Error => 'Redmine request path must start with /' );
    }

    my $Host = $Self->_HostFromURL($BaseURL);
    my $CircuitError = $Self->_CircuitIsOpen( Host => $Host );
    if ($CircuitError) {
        $LogObject->Log(
            Priority => 'error',
            Message  => "Redmine $Method $Path blocked: $CircuitError",
        );
        return ( Success => 0, Error => $CircuitError );
    }

    my $URL = $BaseURL . $Path;

    my $UserAgent = LWP::UserAgent->new(
        timeout => $Timeout,
        agent   => 'OTRSRedmineBridge/1.0',
    );
    $Self->_ApplySSLOpts(
        UserAgent    => $UserAgent,
        ConfigObject => $ConfigObject,
        Host         => $Host,
        Timeout      => $Timeout,
    );
    my $Proxy = $ConfigObject->Get('WebUserAgent::Proxy') || '';
    if ($Proxy) {
        $UserAgent->proxy( [ 'http', 'https' ], $Proxy );
    }

    my $Request = HTTP::Request->new( $Method, $URL );
    $Request->header( 'X-Redmine-API-Key' => $APIKey );

    if ( defined $Param{RawContent} ) {
        $Request->header( 'Content-Type' => $Param{ContentType} || 'application/octet-stream' );
        my $Raw = $Param{RawContent};
        if ( utf8::is_utf8($Raw) ) {
            $Raw = Encode::encode_utf8($Raw);
        }
        $Request->content($Raw);
    }
    elsif ( defined $Param{JSON} ) {
        $Request->header( 'Content-Type' => 'application/json; charset=utf-8' );
        my $Payload = $JSONObject->Encode( Data => $Param{JSON} );
        $Payload = Encode::encode_utf8($Payload) if utf8::is_utf8($Payload);
        $Request->content($Payload);
    }

    my $Response = eval { $UserAgent->request($Request) };
    if ( !$Response || $@ ) {
        my $Detail = $@ || 'no response';
        $Detail =~ s{\s+at\s+/.*}{}s;
        $Detail =~ s{\s+}{ }g;
        $Detail = $Self->_ScrubCredentials($Detail);
        $Self->_CircuitRecordFailure( Host => $Host );
        $LogObject->Log(
            Priority => 'error',
            Message  => "Redmine $Method $Path connect failed: $Detail",
        );
        return (
            Success => 0,
            Error   => $Self->_UnreachableError( BaseURL => $BaseURL, Detail => $Detail ),
        );
    }

    my $Code = $Response->code();

    # charset=>'none': keep raw octets (Redmine often omits charset → Latin-1 mojibake).
    # Decode as UTF-8 with replacement — never EncodeInput/_utf8_on on invalid octets
    # (that causes "Malformed UTF-8 character (fatal)" later in regex/TT).
    my $Content = $Response->decoded_content( charset => 'none' );
    $Content = '' if !defined $Content;
    $Content = $Self->_DecodeUTF8($Content);

    if ( $Code !~ m{\A20[0-9]\z} ) {
        my $Message = $Response->message() // '';
        my $Snippet = substr( $Content, 0, 200 );
        $Snippet =~ s{\s+}{ }g;
        $Snippet = $Self->_ScrubCredentials($Snippet);

        # LWP uses synthetic HTTP 500 for client connect/TLS failures — not a Redmine status.
        my $ConnectHint = "$Message $Snippet";
        if (
            $ConnectHint =~ m{Can.?t\s+connect|Connection\s+timed\s+out|timed?\s*out|Name\s+or\s+service\s+not\s+known|SSL\s+connect|certificate\s+verify|Network\s+is\s+unreachable}i
            )
        {
            my $Detail = $Snippet || $Message;
            $Detail =~ s{\s+at\s+/.*}{}s;
            $Detail = $Self->_ScrubCredentials($Detail);
            $Self->_CircuitRecordFailure( Host => $Host );
            $LogObject->Log(
                Priority => 'error',
                Message  => "Redmine $Method $Path unreachable: $Detail",
            );
            return (
                Success  => 0,
                HTTPCode => $Code,
                Error    => $Self->_UnreachableError( BaseURL => $BaseURL, Detail => $Detail ),
                Content  => $Content,
            );
        }

        # HTTP API errors (4xx etc.) do not trip the circuit — Redmine was reachable.
        $LogObject->Log(
            Priority => 'error',
            Message  => "Redmine $Method $Path failed HTTP=$Code body=$Snippet",
        );
        return (
            Success  => 0,
            HTTPCode => $Code,
            Error    => "HTTP $Code: $Snippet",
            Content  => $Content,
        );
    }

    $Self->_CircuitClear( Host => $Host );

    my $Data;
    if ( length $Content && ( $Param{ExpectJSON} // 1 ) ) {
        $Data = $JSONObject->Decode( Data => $Content );
    }

    return (
        Success  => 1,
        HTTPCode => $Code,
        Data     => $Data,
        Content  => $Content,
        BaseURL  => $BaseURL,
    );
}

sub _AuthParams {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    my $BaseURL = $Param{BaseURL};
    $BaseURL = $ConfigObject->Get('Redmine::BaseURL') if !defined $BaseURL || !length $BaseURL;
    $BaseURL = '' if !defined $BaseURL;

    my $APIKey = $Param{APIKey};
    $APIKey = $ConfigObject->Get('Redmine::APIKey') if !defined $APIKey || !length $APIKey;
    $APIKey = '' if !defined $APIKey;

    my $Timeout = $Param{Timeout};
    $Timeout = $ConfigObject->Get('Redmine::Timeout') if !defined $Timeout || !length $Timeout;
    $Timeout = 30 if !defined $Timeout || !length $Timeout;

    $BaseURL =~ s{\A\s+}{};
    $BaseURL =~ s{\s+\z}{};
    $BaseURL =~ s{/\z}{};
    $APIKey =~ s{\A\s+}{};
    $APIKey =~ s{\s+\z}{};

    return ( $BaseURL, $APIKey, $Timeout, 'Base URL is empty' ) if !length $BaseURL;
    return ( $BaseURL, $APIKey, $Timeout, 'API key is empty' )  if !length $APIKey;
    return ( $BaseURL, $APIKey, $Timeout, undef );
}

# Turn octets (or loosely flagged strings) into clean Perl UTF-8 characters.
# Invalid sequences become U+FFFD — never leave a string that can fatal later.
sub _DecodeUTF8 {
    my ( $Self, $Value ) = @_;
    return '' if !defined $Value;
    return $Value if ref $Value;

    if ( utf8::is_utf8($Value) ) {
        my $Bytes = eval { Encode::encode( 'UTF-8', $Value, Encode::FB_DEFAULT ) };
        return $Value if !defined $Bytes;
        return Encode::decode( 'UTF-8', $Bytes, Encode::FB_DEFAULT );
    }
    return Encode::decode( 'UTF-8', $Value, Encode::FB_DEFAULT );
}

sub _FormatRedmineAPIError {
    my ( $Self, %Param ) = @_;

    my $Error   = $Param{Error}   // '';
    my $Content = $Param{Content} // '';
    return $Error if !length $Content;

    my $Data = eval { $Kernel::OM->Get('Kernel::System::JSON')->Decode( Data => $Content ) };
    if ( IsHashRefWithData($Data) && IsArrayRefWithData( $Data->{errors} ) ) {
        return join( '; ', @{ $Data->{errors} } );
    }
    return $Error;
}

sub UploadFile {
    my ( $Self, %Param ) = @_;

    return ( Success => 0, Error => 'Need Filename and Content' )
        if !$Param{Filename} || !defined $Param{Content};

    my $Name = $Param{Filename};
    $Name =~ s{[^A-Za-z0-9._-]+}{_}g;
    $Name = 'file' if !length $Name;

    my %Res = $Self->_Request(
        Method      => 'POST',
        Path        => '/uploads.json?filename=' . uri_escape($Name),
        RawContent  => $Param{Content},
        ContentType => 'application/octet-stream',
        ExpectJSON  => 1,
    );
    return ( Success => 0, Error => $Res{Error} ) if !$Res{Success};
    my $Token = $Res{Data}->{upload}->{token};
    return ( Success => 0, Error => 'No upload token' ) if !$Token;
    return ( Success => 1, Token => $Token );
}

1;
