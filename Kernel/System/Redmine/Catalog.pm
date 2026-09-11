# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Redmine::Catalog;

use strict;
use warnings;
use utf8;

use Digest::MD5 qw(md5_hex);

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
    'Kernel::System::Ticket',
    'Kernel::System::User',
);

# Cache type for catalogs only (never share with TLS / RedmineBridge).
sub _CatalogCacheType {
    return 'RedmineBridgeCatalog';
}

# Short BaseURL fingerprint so switching Redmine does not serve stale lists.
sub _CatalogBaseScope {
    my ( $Self, %Param ) = @_;

    my $BaseURL = $Param{BaseURL};
    if ( !defined $BaseURL || !length $BaseURL ) {
        $BaseURL = $Kernel::OM->Get('Kernel::Config')->Get('Redmine::BaseURL') // '';
    }
    $BaseURL =~ s{\A\s+}{};
    $BaseURL =~ s{\s+\z}{};
    $BaseURL =~ s{/\z}{};

    return 'nobase' if !length $BaseURL;

    return substr( md5_hex($BaseURL), 0, 12 );
}

sub _CatalogTTL {
    my ($Self) = @_;
    return 0 + ( $Kernel::OM->Get('Kernel::Config')->Get('Redmine::CatalogCacheTTL') // 900 );
}

sub _CatalogUITimeout {
    my ( $Self, %Param ) = @_;

    return $Param{Timeout}
        if defined $Param{Timeout} && length $Param{Timeout};

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $UI           = $ConfigObject->Get('Redmine::UITimeout');
    return 0 + $UI if defined $UI && length $UI;

    return 5;
}

sub _CatalogFailMessage {
    my ( $Self, %Param ) = @_;
    my $Detail = $Param{Detail} // '';
    $Detail =~ s{\s+\z}{};
    return length $Detail
        ? "Каталог Redmine временно недоступен: $Detail"
        : 'Каталог Redmine временно недоступен. Повторите позже.';
}

sub _CatalogEmptySuccess {
    my ( $Self, %Param ) = @_;
    my $Message = $Param{Warning} // $Param{Error} // $Self->_CatalogFailMessage();
    return (
        Success    => 1,
        Projects   => $Param{Projects}   || [],
        Trackers   => $Param{Trackers}   || [],
        Priorities => $Param{Priorities} || [],
        Assignees  => $Param{Assignees}  || [],
        Warning    => $Message,
        Error      => $Message,
        FromFailCache => $Param{FromFailCache} ? 1 : 0,
    );
}

sub ListProjects {
    my ( $Self, %Param ) = @_;

    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $TTL         = $Self->_CatalogTTL();
    my $CacheType   = $Self->_CatalogCacheType();
    my $Scope       = $Self->_CatalogBaseScope(%Param);
    my $CacheKey    = "${Scope}::Projects";
    my $Timeout     = $Param{Timeout};

    if ( !$Param{NoCache} && $TTL > 0 ) {
        my $Cached = $CacheObject->Get( Type => $CacheType, Key => $CacheKey );
        if ( IsArrayRefWithData($Cached) ) {
            return ( Success => 1, Projects => $Cached, FromCache => 1 );
        }
    }

    my @Projects;
    my $Offset = 0;
    while (1) {
        my %Res = $Self->_Request(
            Method  => 'GET',
            Path    => "/projects.json?limit=100&offset=$Offset",
            Timeout => $Timeout,
            BaseURL => $Param{BaseURL},
            APIKey  => $Param{APIKey},
        );
        return %Res if !$Res{Success};
        my $Page = $Res{Data}->{projects} || [];
        last if !IsArrayRefWithData($Page);
        push @Projects, @{$Page};
        $Offset += scalar @{$Page};
        last if $Offset >= ( $Res{Data}->{total_count} // $Offset );
        last if scalar @{$Page} < 100;
    }

    if ( $TTL > 0 ) {
        $CacheObject->Set(
            Type  => $CacheType,
            Key   => $CacheKey,
            Value => \@Projects,
            TTL   => $TTL,
        );
    }
    return ( Success => 1, Projects => \@Projects );
}

sub ListTrackers {
    my ( $Self, %Param ) = @_;

    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $TTL         = $Self->_CatalogTTL();
    my $CacheType   = $Self->_CatalogCacheType();
    my $Scope       = $Self->_CatalogBaseScope(%Param);
    my $Timeout     = $Param{Timeout};

    # Project-scoped path: require a numeric id (S5). No ProjectID → all trackers.
    if ( defined $Param{ProjectID} && length $Param{ProjectID} ) {
        return ( Success => 1, Trackers => [] ) if !IsNumber( $Param{ProjectID} );
    }

    my $CacheKey
        = IsNumber( $Param{ProjectID} )
        ? "${Scope}::Trackers::Project::$Param{ProjectID}"
        : "${Scope}::Trackers::All";

    if ( !$Param{NoCache} && $TTL > 0 ) {
        my $Cached = $CacheObject->Get( Type => $CacheType, Key => $CacheKey );
        if ( IsArrayRefWithData($Cached) ) {
            return ( Success => 1, Trackers => $Cached, FromCache => 1 );
        }
    }

    my $Trackers;
    if ( IsNumber( $Param{ProjectID} ) ) {
        my %Res = $Self->_Request(
            Method  => 'GET',
            Path    => "/projects/$Param{ProjectID}.json?include=trackers",
            Timeout => $Timeout,
            BaseURL => $Param{BaseURL},
            APIKey  => $Param{APIKey},
        );
        return %Res if !$Res{Success};
        $Trackers = $Res{Data}->{project}->{trackers} || [];
    }
    else {
        my %Res = $Self->_Request(
            Method  => 'GET',
            Path    => '/trackers.json',
            Timeout => $Timeout,
            BaseURL => $Param{BaseURL},
            APIKey  => $Param{APIKey},
        );
        return %Res if !$Res{Success};
        $Trackers = $Res{Data}->{trackers} || [];
    }

    if ( $TTL > 0 ) {
        $CacheObject->Set(
            Type  => $CacheType,
            Key   => $CacheKey,
            Value => $Trackers,
            TTL   => $TTL,
        );
    }
    return ( Success => 1, Trackers => $Trackers );
}

# Fast catalog for escalate popup: project(+trackers) + priorities + assignees.
sub EscalateFormCatalog {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $CacheObject  = $Kernel::OM->Get('Kernel::System::Cache');
    my $ProjectID    = $Param{ProjectID} // $ConfigObject->Get('Redmine::ProjectID');
    my $Timeout      = $Self->_CatalogUITimeout(%Param);
    my $TTL          = $Self->_CatalogTTL();
    my $CacheType    = $Self->_CatalogCacheType();
    my $Scope        = $Self->_CatalogBaseScope(%Param);
    my $Full         = $Param{Full} ? 1 : 0;

    # Fail-circuit: never block the agent UI on a known-down Redmine (S1).
    my $FailKey;
    if ( IsNumber($ProjectID) ) {
        $FailKey = "${Scope}::CatalogFail::$ProjectID";
        my $Failed = $CacheObject->Get( Type => $CacheType, Key => $FailKey );
        if ( defined $Failed && length $Failed ) {
            return $Self->_CatalogEmptySuccess(
                Warning       => $Self->_CatalogFailMessage( Detail => $Failed ),
                FromFailCache => 1,
            );
        }
    }

    # Prefer cache; NoCache only when explicit and not on fail-circuit.
    my $UseCache = ( !$Param{NoCache} && $TTL > 0 ) ? 1 : 0;

    my %PriorityRes = $Self->ListPriorities(
        Timeout => $Timeout,
        NoCache => $UseCache ? 0 : 1,
    );
    my @Priorities = @{ $PriorityRes{Priorities} || [] };

    if ( $ConfigObject->Get('Redmine::FormLoadAllProjects') ) {
        my %ProjectsRes = $Self->ListProjects(
            Timeout => $Timeout,
            NoCache => $UseCache ? 0 : 1,
        );
        if ( !$ProjectsRes{Success} ) {
            my $Detail = $ProjectsRes{Error} // 'ListProjects failed';
            if ($FailKey) {
                $CacheObject->Set(
                    Type  => $CacheType,
                    Key   => $FailKey,
                    Value => $Detail,
                    TTL   => 60,
                );
            }
            return $Self->_CatalogEmptySuccess(
                Priorities => \@Priorities,
                Warning    => $Self->_CatalogFailMessage( Detail => $Detail ),
            );
        }

        my %TrackersRes = ( Success => 1, Trackers => [] );
        my @Assignees;
        if ( IsNumber($ProjectID) ) {
            %TrackersRes = $Self->ListTrackers(
                ProjectID => $ProjectID,
                Timeout   => $Timeout,
                NoCache   => $UseCache ? 0 : 1,
            );
            if ( !$TrackersRes{Success} ) {
                my $Detail = $TrackersRes{Error} // 'ListTrackers failed';
                $CacheObject->Set(
                    Type  => $CacheType,
                    Key   => $FailKey,
                    Value => $Detail,
                    TTL   => 60,
                );
                return $Self->_CatalogEmptySuccess(
                    Projects   => $ProjectsRes{Projects},
                    Priorities => \@Priorities,
                    Warning    => $Self->_CatalogFailMessage( Detail => $Detail ),
                );
            }
            my %A = $Self->ListProjectAssignees(
                ProjectID => $ProjectID,
                Timeout   => $Timeout,
                Full      => $Full,
                MaxPages  => $Full ? undef : 2,
                NoCache   => $UseCache ? 0 : 1,
            );
            @Assignees = @{ $A{Assignees} || [] } if $A{Success};
        }

        return (
            Success    => 1,
            Projects   => $ProjectsRes{Projects},
            Trackers   => $TrackersRes{Trackers},
            Priorities => \@Priorities,
            Assignees  => \@Assignees,
            FromCache  => ( $ProjectsRes{FromCache} && $TrackersRes{FromCache} ) ? 1 : 0,
        );
    }

    if ( !IsNumber($ProjectID) ) {
        return (
            Success => 0,
            Error   => 'Redmine::ProjectID is not configured',
        );
    }

    $FailKey ||= "${Scope}::CatalogFail::$ProjectID";
    my $CacheKey = "${Scope}::FormCatalog::v4::$ProjectID" . ( $Full ? '::full' : '' );

    if ($UseCache) {
        my $Cached = $CacheObject->Get( Type => $CacheType, Key => $CacheKey );
        if ( IsHashRefWithData($Cached) ) {
            return ( Success => 1, %{$Cached}, FromCache => 1 );
        }
    }

    my %Res = $Self->_Request(
        Method  => 'GET',
        Path    => "/projects/$ProjectID.json?include=trackers",
        Timeout => $Timeout,
    );
    if ( !$Res{Success} ) {
        my $Detail = $Res{Error} // 'project fetch failed';
        $CacheObject->Set(
            Type  => $CacheType,
            Key   => $FailKey,
            Value => $Detail,
            TTL   => 60,
        );
        return $Self->_CatalogEmptySuccess(
            Priorities => \@Priorities,
            Warning    => $Self->_CatalogFailMessage( Detail => $Detail ),
        );
    }

    my $Project = $Res{Data}->{project} || {};
    my %AssigneesRes = $Self->ListProjectAssignees(
        ProjectID => $ProjectID,
        Timeout   => $Timeout,
        Full      => $Full,
        MaxPages  => $Full ? undef : 2,
        NoCache   => $UseCache ? 0 : 1,
    );
    my @Assignees = $AssigneesRes{Success} ? @{ $AssigneesRes{Assignees} || [] } : ();

    my %Catalog = (
        Projects => [
            {
                id   => $Project->{id} // $ProjectID,
                name => $Project->{name} // "Project #$ProjectID",
            },
        ],
        Trackers   => $Project->{trackers} || [],
        Priorities => \@Priorities,
        Assignees  => \@Assignees,
    );

    if ( $TTL > 0 ) {
        $CacheObject->Set(
            Type  => $CacheType,
            Key   => $CacheKey,
            Value => \%Catalog,
            TTL   => $TTL,
        );
        $CacheObject->Set(
            Type  => $CacheType,
            Key   => "${Scope}::Trackers::Project::$ProjectID",
            Value => $Catalog{Trackers},
            TTL   => $TTL,
        );
    }

    return ( Success => 1, %Catalog );
}

sub ListPriorities {
    my ( $Self, %Param ) = @_;

    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $TTL         = $Self->_CatalogTTL();
    my $CacheType   = $Self->_CatalogCacheType();
    my $Scope       = $Self->_CatalogBaseScope(%Param);
    my $CacheKey    = "${Scope}::Priorities";
    my $Timeout     = $Param{Timeout};

    if ( !$Param{NoCache} && $TTL > 0 ) {
        my $Cached = $CacheObject->Get( Type => $CacheType, Key => $CacheKey );
        return ( Success => 1, Priorities => $Cached, FromCache => 1 )
            if IsArrayRefWithData($Cached);
    }

    my %Res = $Self->_Request(
        Method  => 'GET',
        Path    => '/enumerations/issue_priorities.json',
        Timeout => $Timeout,
        BaseURL => $Param{BaseURL},
        APIKey  => $Param{APIKey},
    );
    return ( Success => 0, Error => $Res{Error}, Priorities => [] ) if !$Res{Success};

    my @List;
    for my $P ( @{ $Res{Data}->{issue_priorities} || [] } ) {
        next if !IsNumber( $P->{id} );
        push @List, {
            id         => $P->{id},
            name       => $P->{name} // "Priority #$P->{id}",
            is_default => $P->{is_default} ? 1 : 0,
        };
    }

    if ( $TTL > 0 ) {
        $CacheObject->Set(
            Type  => $CacheType,
            Key   => $CacheKey,
            Value => \@List,
            TTL   => $TTL,
        );
    }

    return ( Success => 1, Priorities => \@List );
}

sub ListProjectAssignees {
    my ( $Self, %Param ) = @_;

    my $ProjectID = $Param{ProjectID};
    return ( Success => 1, Assignees => [] ) if !IsNumber($ProjectID);

    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $TTL         = $Self->_CatalogTTL();
    my $CacheType   = $Self->_CatalogCacheType();
    my $Scope       = $Self->_CatalogBaseScope(%Param);
    my $Timeout     = $Param{Timeout};
    my $Full        = $Param{Full} ? 1 : 0;
    my $MaxPages    = $Full ? 20 : ( 0 + ( $Param{MaxPages} // 2 ) );
    $MaxPages = 1 if $MaxPages < 1;

    my $CacheKey = "${Scope}::Assignees::Project::$ProjectID" . ( $Full ? '::full' : "::p$MaxPages" );

    if ( !$Param{NoCache} && $TTL > 0 ) {
        my $Cached = $CacheObject->Get( Type => $CacheType, Key => $CacheKey );
        return ( Success => 1, Assignees => $Cached, FromCache => 1 )
            if IsArrayRefWithData($Cached) || ( ref $Cached eq 'ARRAY' );
    }

    my @Assignees;
    my %Seen;
    my $Offset = 0;
    my $Limit  = 100;

    PAGE:
    for ( 1 .. $MaxPages ) {
        my %Res = $Self->_Request(
            Method  => 'GET',
            Path    => "/projects/$ProjectID/memberships.json?limit=$Limit&offset=$Offset",
            Timeout => $Timeout,
        );
        last PAGE if !$Res{Success};

        my $Memberships = $Res{Data}->{memberships} || [];
        last PAGE if !IsArrayRefWithData($Memberships);

        for my $M ( @{$Memberships} ) {
            my $User = $M->{user};
            next if !IsHashRefWithData($User) || !IsNumber( $User->{id} );
            next if $Seen{ $User->{id} }++;
            my $Name = $User->{name} || $User->{login} || "User #$User->{id}";
            push @Assignees, { id => $User->{id}, name => $Name };
        }

        my $Total = 0 + ( $Res{Data}->{total_count} // 0 );
        $Offset += $Limit;
        last PAGE if $Offset >= $Total || @{$Memberships} < $Limit;
    }

    @Assignees = sort { lc( $a->{name} ) cmp lc( $b->{name} ) } @Assignees;

    if ( $TTL > 0 ) {
        $CacheObject->Set(
            Type  => $CacheType,
            Key   => $CacheKey,
            Value => \@Assignees,
            TTL   => $TTL,
        );
    }

    return ( Success => 1, Assignees => \@Assignees );
}

# Prefetch catalog for CronSync / Daemon (full assignees, batch timeout).
sub WarmCatalog {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ProjectID    = $Param{ProjectID} // $ConfigObject->Get('Redmine::ProjectID');
    return ( Success => 0, Error => 'Need ProjectID' ) if !IsNumber($ProjectID);

    my $Timeout = $Param{Timeout} // $ConfigObject->Get('Redmine::Timeout') // 30;

    return $Self->EscalateFormCatalog(
        ProjectID => $ProjectID,
        Timeout   => $Timeout,
        Full      => 1,
        NoCache   => $Param{NoCache} ? 1 : 0,
    );
}

sub EscalateDefaults {
    my ( $Self, %Param ) = @_;

    return () if !$Param{TicketID};
    my $UserID       = $Param{UserID} || 1;
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my %Ticket       = $TicketObject->TicketGet(
        TicketID      => $Param{TicketID},
        DynamicFields => 0,
        UserID        => $UserID,
        Silent        => 1,
    );
    return () if !%Ticket;

    my %User = $Kernel::OM->Get('Kernel::System::User')->GetUserData( UserID => $UserID );
    my $AgentLabel = $User{UserLogin} || $UserID;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $Prefix       = $ConfigObject->Get('Redmine::SubjectPrefix') || '';
    $Prefix =~ s{\s+\z}{};
    my $Subject = '';
    $Subject .= "$Prefix " if length $Prefix;
    $Subject .= "[OTRS#$Ticket{TicketNumber}] $Ticket{Title}";
    $Subject = substr( $Subject, 0, 250 );

    return (
        Subject     => $Subject,
        Description => $Self->_BuildDescription( %Ticket, AgentLabel => $AgentLabel ),
    );
}

1;
