# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
package Kernel::Modules::AdminRedmineBridge;

use strict;
use warnings;
use utf8;

use Kernel::System::VariableCheck qw(:all);
use Kernel::Language qw(Translatable);

our $ObjectManagerDisabled = 1;

sub new {
    my ( $Type, %Param ) = @_;
    my $Self = {%Param};
    bless( $Self, $Type );
    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');

    # Prefer request param: submit buttons with name=Subaction can be dropped by
    # PreventMultipleSubmits; hidden field is the reliable source.
    my $Subaction = $ParamObject->GetParam( Param => 'Subaction' )
        || $Self->{Subaction}
        || '';

    if ( $Subaction eq 'AJAXCatalog' ) {
        $LayoutObject->ChallengeTokenCheck();
        return $Self->_AJAXCatalog();
    }

    if (
           $Subaction eq 'TestConnection'
        || $Subaction eq 'TestProject'
        || $Subaction eq 'TestTracker'
        || $Subaction eq 'TestTLS'
        || $Subaction eq 'EnableZoomFields'
        || $Subaction eq 'ReloadCatalog'
        )
    {
        $LayoutObject->ChallengeTokenCheck();
        if ( $Subaction eq 'EnableZoomFields' ) {
            my %Res = $Kernel::OM->Get('Kernel::System::Redmine')->EnsureZoomDynamicFields();
            return $Self->_Screen(
                LayoutObject => $LayoutObject,
                Form         => { $Self->_CurrentForm() },
                Notify       => $Res{Success}
                    ? ( $Res{Message} || Translatable('TicketZoom dynamic fields updated.') )
                    : undef,
                Error => $Res{Success}
                    ? undef
                    : ( $Res{Error} || Translatable('Could not update TicketZoom dynamic fields.') ),
            );
        }
        if ( $Subaction eq 'ReloadCatalog' ) {
            # Clear catalog cache then re-render form with fresh Redmine lists.
            $Kernel::OM->Get('Kernel::System::Cache')->CleanUp( Type => 'RedmineBridgeCatalog' );
            my %Form = $Self->_FormFromRequest();
            my %Cat  = $Self->_FetchRedmineCatalog( Form => \%Form, NoCache => 1 );
            return $Self->_Screen(
                LayoutObject => $LayoutObject,
                Form         => \%Form,
                Catalog      => \%Cat,
                Notify       => $Cat{Success}
                    ? Translatable('Lists reloaded from Redmine.')
                    : undef,
                Error => $Cat{Success}
                    ? undef
                    : ( $Cat{Error} || Translatable('Could not load lists from Redmine.') ),
            );
        }
        return $Self->_HandleTest(
            LayoutObject => $LayoutObject,
            ConfigObject => $ConfigObject,
            ParamObject  => $ParamObject,
            Kind         => $Subaction,
        );
    }

    if ( $Subaction eq 'RunSyncNow' ) {
        $LayoutObject->ChallengeTokenCheck();
        my $Ok = eval {
            $Kernel::OM->Get('Kernel::System::Redmine')->CronSync();
            1;
        };
        my $Die = $@ || '';
        if ($Die) {
            # Avoid second fatal when rendering a malformed UTF-8 $@ string.
            $Die =~ s{[^\x09\x0A\x0D\x20-\x7E\x{A0}-\x{FFFF}]}{?}g;
            $Die =~ s{\s+at\s+\S+.*}{}s;
            $Die =~ s{\s+}{ }g;
            $Die =~ s{\A\s+|\s+\z}{}g;
        }
        return $Self->_Screen(
            LayoutObject => $LayoutObject,
            Form         => { $Self->_CurrentForm() },
            Notify       => $Ok
                ? Translatable('Inbound sync finished.')
                : undef,
            Error => $Ok
                ? undef
                : ( $Die || Translatable('Inbound sync failed.') ),
        );
    }

    if ( $Subaction eq 'Save' ) {
        $LayoutObject->ChallengeTokenCheck();

        my $BaseURL = $Self->_Trim( $ParamObject->GetParam( Param => 'BaseURL' ) );

        # S12 / O1: reject non-http(s) BaseURL on save.
        if ( length $BaseURL && $BaseURL !~ m{\Ahttps?://}i ) {
            return $Self->_Screen(
                LayoutObject => $LayoutObject,
                Error        => Translatable('Redmine base URL must start with http:// or https://'),
                Form         => { $Self->_FormFromRequest() },
            );
        }

        my %Values = (
            'Redmine::Enabled'             => $ParamObject->GetParam( Param => 'Enabled' )             ? 1 : 0,
            'Redmine::BaseURL'             => $BaseURL,
            'Redmine::OTRSBaseURL'         => $Self->_NormalizeOTRSBaseURL(
                $ParamObject->GetParam( Param => 'OTRSBaseURL' )
            ),
            'Redmine::ProjectID'           => $Self->_Trim( $ParamObject->GetParam( Param => 'ProjectID' ) ),
            'Redmine::TrackerID'           => $Self->_Trim( $ParamObject->GetParam( Param => 'TrackerID' ) ),
            'Redmine::PriorityID'          => $Self->_Trim( $ParamObject->GetParam( Param => 'PriorityID' ) ),
            'Redmine::DefaultDueDateDays'  => $Self->_Trim( $ParamObject->GetParam( Param => 'DefaultDueDateDays' ) ) || '0',
            'Redmine::DefaultCustomFields' => $ParamObject->GetParam( Param => 'DefaultCustomFields' ) // '',
            'Redmine::SubjectPrefix'       => $Self->_Trim( $ParamObject->GetParam( Param => 'SubjectPrefix' ) ),
            'Redmine::Timeout'             => $Self->_Trim( $ParamObject->GetParam( Param => 'Timeout' ) ) || '30',
            'Redmine::UITimeout'           => $Self->_Trim( $ParamObject->GetParam( Param => 'UITimeout' ) ) || '5',
            'Redmine::CatalogCacheTTL'     => $Self->_Trim( $ParamObject->GetParam( Param => 'CatalogCacheTTL' ) ) || '900',
            'Redmine::SyncComments'        => $ParamObject->GetParam( Param => 'SyncComments' )        ? 1 : 0,
            'Redmine::SyncAttachments'     => $ParamObject->GetParam( Param => 'SyncAttachments' )     ? 1 : 0,
            'Redmine::InboundSync'         => $ParamObject->GetParam( Param => 'InboundSync' )         ? 1 : 0,
            'Redmine::NotifyOnStatusNote'  => $ParamObject->GetParam( Param => 'NotifyOnStatusNote' )  ? 1 : 0,
            'Redmine::AutoRetry'           => $ParamObject->GetParam( Param => 'AutoRetry' )           ? 1 : 0,
            'Redmine::FormLoadAllProjects' => $ParamObject->GetParam( Param => 'FormLoadAllProjects' ) ? 1 : 0,
            'Redmine::AllowLegacyTLS'      => $ParamObject->GetParam( Param => 'AllowLegacyTLS' )      ? 1 : 0,
            'Redmine::IncidentTrackerID'   => $Self->_Trim( $ParamObject->GetParam( Param => 'IncidentTrackerID' ) ),
            'Redmine::SSLVersion'          => $Self->_Trim( $ParamObject->GetParam( Param => 'SSLVersion' ) ),
            'Redmine::MaxAttachmentBytes'  => $Self->_Trim( $ParamObject->GetParam( Param => 'MaxAttachmentBytes' ) ) || '5000000',
            'Redmine::SyncBatchLimit'      => $Self->_Trim( $ParamObject->GetParam( Param => 'SyncBatchLimit' ) ) || '50',
            'Redmine::RetryBatchLimit'     => $Self->_Trim( $ParamObject->GetParam( Param => 'RetryBatchLimit' ) ) || '20',
            'Redmine::AllowedProjectIDs'   => $Self->_JoinIDs(
                $ParamObject->GetArray( Param => 'AllowedProjectIDs' )
            ),
            'Redmine::AgentGroup'          => $Self->_Trim( $ParamObject->GetParam( Param => 'AgentGroup' ) ),
            'Redmine::StatusSync'          => $Self->_ParseStatusSync(
                $ParamObject->GetParam( Param => 'StatusSync' )
            ),
        );

        my $APIKey = $ParamObject->GetParam( Param => 'APIKey' );
        if ( defined $APIKey && length $Self->_Trim($APIKey) ) {
            $Values{'Redmine::APIKey'} = $Self->_Trim($APIKey);
        }

        my ( $Ok, $Error ) = $Self->_SaveSettings(%Values);
        if ($Ok) {
            return $LayoutObject->Redirect(
                OP => "Action=$Self->{Action};Saved=1",
            );
        }
        return $Self->_Screen(
            LayoutObject => $LayoutObject,
            Error        => $Error || Translatable('Could not save settings.'),
            Form         => {
                Enabled             => $Values{'Redmine::Enabled'},
                BaseURL             => $Values{'Redmine::BaseURL'},
                OTRSBaseURL         => $Values{'Redmine::OTRSBaseURL'},
                ProjectID           => $Values{'Redmine::ProjectID'},
                TrackerID           => $Values{'Redmine::TrackerID'},
                PriorityID          => $Values{'Redmine::PriorityID'},
                DefaultDueDateDays  => $Values{'Redmine::DefaultDueDateDays'},
                DefaultCustomFields => $Values{'Redmine::DefaultCustomFields'},
                SubjectPrefix       => $Values{'Redmine::SubjectPrefix'},
                Timeout             => $Values{'Redmine::Timeout'},
                UITimeout           => $Values{'Redmine::UITimeout'},
                CatalogCacheTTL     => $Values{'Redmine::CatalogCacheTTL'},
                SyncComments        => $Values{'Redmine::SyncComments'},
                SyncAttachments     => $Values{'Redmine::SyncAttachments'},
                InboundSync         => $Values{'Redmine::InboundSync'},
                NotifyOnStatusNote  => $Values{'Redmine::NotifyOnStatusNote'},
                AutoRetry           => $Values{'Redmine::AutoRetry'},
                FormLoadAllProjects => $Values{'Redmine::FormLoadAllProjects'},
                AllowLegacyTLS      => $Values{'Redmine::AllowLegacyTLS'},
                IncidentTrackerID   => $Values{'Redmine::IncidentTrackerID'},
                SSLVersion          => $Values{'Redmine::SSLVersion'},
                MaxAttachmentBytes  => $Values{'Redmine::MaxAttachmentBytes'},
                SyncBatchLimit      => $Values{'Redmine::SyncBatchLimit'},
                RetryBatchLimit     => $Values{'Redmine::RetryBatchLimit'},
                AllowedProjectIDs   => $Values{'Redmine::AllowedProjectIDs'},
                AgentGroup          => $Values{'Redmine::AgentGroup'},
                StatusSync          => $ParamObject->GetParam( Param => 'StatusSync' ) // '',
                APIKeySet           => IsStringWithData( $ConfigObject->Get('Redmine::APIKey') ) ? 1 : 0,
            },
        );
    }

    my %Form = $Self->_CurrentForm();
    my $Saved = $ParamObject->GetParam( Param => 'Saved' );
    return $Self->_Screen(
        LayoutObject => $LayoutObject,
        Form         => \%Form,
        Notify       => $Saved
        ? Translatable('Settings saved and deployed.')
        : undef,
    );
}

sub _HandleTest {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Param{LayoutObject};
    my $ConfigObject = $Param{ConfigObject};
    my $ParamObject  = $Param{ParamObject};
    my $Kind         = $Param{Kind} || '';

    my %Form   = $Self->_FormFromRequest();
    my $APIKey = $Self->_Trim( $ParamObject->GetParam( Param => 'APIKey' ) );
    if ( !length $APIKey ) {
        $APIKey = $ConfigObject->Get('Redmine::APIKey') // '';
    }
    $Form{APIKeySet} = IsStringWithData( $ConfigObject->Get('Redmine::APIKey') ) ? 1 : 0;

    # Prefer form BaseURL; fall back to saved config so project/tracker tests work with empty form after reload
    my $BaseURL = $Form{BaseURL};
    if ( !length $BaseURL ) {
        $BaseURL = $ConfigObject->Get('Redmine::BaseURL') // '';
        $Form{BaseURL} = $BaseURL;
    }

    my $Redmine = $Kernel::OM->Get('Kernel::System::Redmine');
    my %Test;
    if ( $Kind eq 'TestTLS' ) {
        %Test = $Redmine->TestTLSDiagnostics(
            BaseURL => $BaseURL,
            Timeout => $Form{Timeout},
        );
    }
    elsif ( $Kind eq 'TestProject' ) {
        %Test = $Redmine->TestProject(
            BaseURL   => $BaseURL,
            APIKey    => $APIKey,
            Timeout   => $Form{Timeout},
            ProjectID => $Form{ProjectID},
        );
    }
    elsif ( $Kind eq 'TestTracker' ) {
        %Test = $Redmine->TestTracker(
            BaseURL   => $BaseURL,
            APIKey    => $APIKey,
            Timeout   => $Form{Timeout},
            ProjectID => $Form{ProjectID},
            TrackerID => $Form{TrackerID},
        );
    }
    else {
        %Test = $Redmine->TestConnection(
            BaseURL   => $BaseURL,
            APIKey    => $APIKey,
            Timeout   => $Form{Timeout},
            ProjectID => $Form{ProjectID},
        );
    }

    if ( $Test{Success} ) {
        return $Self->_Screen(
            LayoutObject     => $LayoutObject,
            Form             => \%Form,
            Notify           => $Test{Message} || Translatable('Check successful.'),
            DiagnosticReport => $Test{Report},
        );
    }
    return $Self->_Screen(
        LayoutObject     => $LayoutObject,
        Form             => \%Form,
        Error            => $Test{Error} || Translatable('Check failed.'),
        DiagnosticReport => $Test{Report},
    );
}

sub _DaemonHealth {
    my ( $Self, %Param ) = @_;

    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $LastSyncAt  = $CacheObject->Get( Type => 'RedmineBridgeHealth', Key => 'LastSyncAt' );
    my $LastError   = $CacheObject->Get( Type => 'RedmineBridgeHealth', Key => 'LastSyncError' );
    my $SyncedCount = $CacheObject->Get( Type => 'RedmineBridgeHealth', Key => 'SyncedCount' );
    my $LastSyncOK  = $CacheObject->Get( Type => 'RedmineBridgeHealth', Key => 'LastSyncOK' );

    my $AgeSec;
    my $Stale = 0;
    my $AgeLabel = '';
    if ( IsNumber($LastSyncAt) && $LastSyncAt > 0 ) {
        $AgeSec = time() - ( 0 + $LastSyncAt );
        $AgeSec = 0 if $AgeSec < 0;
        $Stale  = ( $AgeSec > 15 * 60 ) ? 1 : 0;
        if ( $AgeSec < 60 ) {
            $AgeLabel = sprintf( '%ds', $AgeSec );
        }
        elsif ( $AgeSec < 3600 ) {
            $AgeLabel = sprintf( '%dm', int( $AgeSec / 60 ) );
        }
        else {
            $AgeLabel = sprintf( '%dh %dm', int( $AgeSec / 3600 ), int( ( $AgeSec % 3600 ) / 60 ) );
        }
    }

    return (
        HealthHasData   => ( defined $LastSyncAt || defined $LastError || defined $SyncedCount ) ? 1 : 0,
        LastSyncAt      => $LastSyncAt // '',
        LastSyncError   => $LastError  // '',
        SyncedCount     => defined $SyncedCount ? ( 0 + $SyncedCount ) : '',
        LastSyncOK      => defined $LastSyncOK ? ( $LastSyncOK ? 1 : 0 ) : '',
        SyncAgeLabel    => $AgeLabel,
        SyncStale       => $Stale,
    );
}

sub _Screen {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Param{LayoutObject};
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my %Form         = %{ $Param{Form} || {} };
    my %Health       = $Self->_DaemonHealth();

    my $SSLVerifyDisabled = $ConfigObject->Get('WebUserAgent::DisableSSLVerification') ? 1 : 0;

    my %Catalog = %{ $Param{Catalog} || {} };
    if ( !%Catalog ) {
        %Catalog = $Self->_FetchRedmineCatalog( Form => \%Form );
    }

    my %Selections = $Self->_BuildCatalogSelections(
        LayoutObject => $LayoutObject,
        Form         => \%Form,
        Catalog      => \%Catalog,
    );

    my $Output = $LayoutObject->Header();
    $Output .= $LayoutObject->NavigationBar();
    $Output .= $LayoutObject->Notify(
        Info => $Param{Notify},
    ) if $Param{Notify};
    $Output .= $LayoutObject->Notify(
        Priority => 'Error',
        Info     => $Param{Error},
    ) if $Param{Error};
    if ( $Catalog{Error} && !$Param{Error} ) {
        $Output .= $LayoutObject->Notify(
            Priority => 'Error',
            Info     => $Catalog{Error},
        );
    }
    elsif ( $Catalog{Warning} ) {
        $Output .= $LayoutObject->Notify(
            Info => $Catalog{Warning},
        );
    }
    if ($SSLVerifyDisabled) {
        $Output .= $LayoutObject->Notify(
            Priority => 'Error',
            Info     => Translatable(
                'Warning: WebUserAgent::DisableSSLVerification is enabled — TLS certificate checks are off.'
            ),
        );
    }

    my $JSONObject = $Kernel::OM->Get('Kernel::System::JSON');

    $Output .= $LayoutObject->Output(
        TemplateFile => 'AdminRedmineBridge',
        Data         => {
            %Form,
            %Health,
            %Selections,
            CatalogLoaded     => $Catalog{Success} ? 1 : 0,
            APIKeySet         => $Form{APIKeySet} ? 1 : 0,
            DiagnosticReport  => $Param{DiagnosticReport} // '',
            SSLVerifyDisabled => $SSLVerifyDisabled,
            # OTRS 6 has no TT |js filter — pass JSON-encoded literals for script block.
            ChallengeTokenJSON => $JSONObject->Encode(
                Data => $LayoutObject->{UserChallengeToken} || '',
            ),
            BaselinkJSON => $JSONObject->Encode(
                Data => $LayoutObject->{Baselink} || '',
            ),
        },
    );
    $Output .= $LayoutObject->Footer();
    return $Output;
}

sub _AJAXCatalog {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');

    my %Form = (
        BaseURL   => $Self->_Trim( $ParamObject->GetParam( Param => 'BaseURL' ) ),
        Timeout   => $Self->_Trim( $ParamObject->GetParam( Param => 'Timeout' ) ),
        UITimeout => $Self->_Trim( $ParamObject->GetParam( Param => 'UITimeout' ) ),
        ProjectID => $Self->_Trim( $ParamObject->GetParam( Param => 'ProjectID' ) ),
        APIKeySet => 1,
    );
    my $APIKey = $Self->_Trim( $ParamObject->GetParam( Param => 'APIKey' ) );

    my %Cat = $Self->_FetchRedmineCatalog(
        Form     => \%Form,
        APIKey   => $APIKey,
        NoCache  => $ParamObject->GetParam( Param => 'NoCache' ) ? 1 : 0,
    );

    my $JSON = $Kernel::OM->Get('Kernel::System::JSON')->Encode(
        Data => {
            Success    => $Cat{Success} ? 1 : 0,
            Error      => $Cat{Error}   || '',
            Warning    => $Cat{Warning} || '',
            Projects   => $Cat{Projects}   || [],
            Trackers   => $Cat{Trackers}   || [],
            Priorities => $Cat{Priorities} || [],
            AllTrackers => $Cat{AllTrackers} || [],
        },
    );
    return $LayoutObject->Attachment(
        ContentType => 'application/json; charset=utf-8',
        Content     => $JSON,
        Type        => 'inline',
        NoCache     => 1,
    );
}

sub _FetchRedmineCatalog {
    my ( $Self, %Param ) = @_;

    my $Form         = $Param{Form} || {};
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $Redmine      = $Kernel::OM->Get('Kernel::System::Redmine');

    my $BaseURL = $Form->{BaseURL};
    if ( !length( $BaseURL // '' ) ) {
        $BaseURL = $ConfigObject->Get('Redmine::BaseURL') // '';
    }
    my $APIKey = $Param{APIKey};
    if ( !defined $APIKey || !length $APIKey ) {
        $APIKey = $ConfigObject->Get('Redmine::APIKey') // '';
    }
    my $Timeout = $Form->{UITimeout} || $Form->{Timeout}
        || $ConfigObject->Get('Redmine::UITimeout')
        || 5;

    if ( !length $BaseURL || !length $APIKey ) {
        return (
            Success => 0,
            Error   => Translatable(
                'Save Base URL and API key first (or enter them above), then reload lists from Redmine.'
            ),
            Projects    => [],
            Trackers    => [],
            AllTrackers => [],
            Priorities  => [],
        );
    }

    my %ProjectsRes = $Redmine->ListProjects(
        BaseURL => $BaseURL,
        APIKey  => $APIKey,
        Timeout => $Timeout,
        NoCache => $Param{NoCache} ? 1 : 0,
    );
    if ( !$ProjectsRes{Success} ) {
        return (
            Success => 0,
            Error   => $ProjectsRes{Error}
                || Translatable('Could not load Redmine projects.'),
            Projects    => [],
            Trackers    => [],
            AllTrackers => [],
            Priorities  => [],
        );
    }

    my @Projects = map {
        {
            Key   => 0 + ( $_->{id} // 0 ),
            Value => sprintf( '%s (#%s)', $_->{name} // '', $_->{id} // '' ),
        }
        }
        grep { IsNumber( $_->{id} ) } @{ $ProjectsRes{Projects} || [] };

    my %PriRes = $Redmine->ListPriorities(
        BaseURL => $BaseURL,
        APIKey  => $APIKey,
        Timeout => $Timeout,
        NoCache => $Param{NoCache} ? 1 : 0,
    );
    my @Priorities;
    if ( $PriRes{Success} ) {
        @Priorities = map {
            {
                Key   => 0 + ( $_->{id} // 0 ),
                Value => sprintf( '%s (#%s)', $_->{name} // '', $_->{id} // '' ),
            }
            }
            grep { IsNumber( $_->{id} ) } @{ $PriRes{Priorities} || [] };
    }

    my %AllTr = $Redmine->ListTrackers(
        BaseURL => $BaseURL,
        APIKey  => $APIKey,
        Timeout => $Timeout,
        NoCache => $Param{NoCache} ? 1 : 0,
    );
    my @AllTrackers;
    if ( $AllTr{Success} ) {
        @AllTrackers = map {
            {
                Key   => 0 + ( $_->{id} // 0 ),
                Value => sprintf( '%s (#%s)', $_->{name} // '', $_->{id} // '' ),
            }
            }
            grep { IsNumber( $_->{id} ) } @{ $AllTr{Trackers} || [] };
    }

    my $ProjectID = $Form->{ProjectID};
    my @Trackers  = @AllTrackers;
    if ( IsNumber($ProjectID) ) {
        my %Tr = $Redmine->ListTrackers(
            BaseURL   => $BaseURL,
            APIKey    => $APIKey,
            Timeout   => $Timeout,
            ProjectID => $ProjectID,
            NoCache   => $Param{NoCache} ? 1 : 0,
        );
        if ( $Tr{Success} && IsArrayRefWithData( $Tr{Trackers} ) ) {
            @Trackers = map {
                {
                    Key   => 0 + ( $_->{id} // 0 ),
                    Value => sprintf( '%s (#%s)', $_->{name} // '', $_->{id} // '' ),
                }
                }
                grep { IsNumber( $_->{id} ) } @{ $Tr{Trackers} };
        }
    }

    return (
        Success     => 1,
        Projects    => \@Projects,
        Trackers    => \@Trackers,
        AllTrackers => \@AllTrackers,
        Priorities  => \@Priorities,
        Warning     => scalar @Projects
        ? undef
        : Translatable('Redmine returned an empty project list for this API key.'),
    );
}

sub _BuildCatalogSelections {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Param{LayoutObject};
    my $Form         = $Param{Form}    || {};
    my $Catalog      = $Param{Catalog} || {};

    my @Projects    = @{ $Catalog->{Projects}    || [] };
    my @Trackers    = @{ $Catalog->{Trackers}    || [] };
    my @AllTrackers = @{ $Catalog->{AllTrackers} || [] };
    my @Priorities  = @{ $Catalog->{Priorities}  || [] };

    # Keep currently saved IDs selectable even if catalog failed/missing them.
    @Projects = $Self->_EnsureOption(
        \@Projects,
        $Form->{ProjectID},
    );
    @Trackers = $Self->_EnsureOption(
        \@Trackers,
        $Form->{TrackerID},
    );
    @AllTrackers = $Self->_EnsureOption(
        \@AllTrackers,
        $Form->{IncidentTrackerID},
    );
    @Priorities = $Self->_EnsureOption(
        \@Priorities,
        $Form->{PriorityID},
    );

    my @AllowedSelected = $Self->_SplitIDs( $Form->{AllowedProjectIDs} );
    for my $ID (@AllowedSelected) {
        @Projects = $Self->_EnsureOption( \@Projects, $ID );
    }

    my %GroupList = $Kernel::OM->Get('Kernel::System::Group')->GroupList( Valid => 1 );
    my @Groups    = map { { Key => $GroupList{$_}, Value => $GroupList{$_} } }
        sort { lc( $GroupList{$a} ) cmp lc( $GroupList{$b} ) } keys %GroupList;

    return (
        ProjectIDStrg => $LayoutObject->BuildSelection(
            Data         => \@Projects,
            Name         => 'ProjectID',
            ID           => 'ProjectID',
            SelectedID   => $Form->{ProjectID},
            PossibleNone => 1,
            Translation  => 0,
            Class        => 'W75pc',
        ),
        TrackerIDStrg => $LayoutObject->BuildSelection(
            Data         => \@Trackers,
            Name         => 'TrackerID',
            ID           => 'TrackerID',
            SelectedID   => $Form->{TrackerID},
            PossibleNone => 1,
            Translation  => 0,
            Class        => 'W75pc',
        ),
        PriorityIDStrg => $LayoutObject->BuildSelection(
            Data         => \@Priorities,
            Name         => 'PriorityID',
            ID           => 'PriorityID',
            SelectedID   => $Form->{PriorityID},
            PossibleNone => 1,
            Translation  => 0,
            Class        => 'W75pc',
        ),
        IncidentTrackerIDStrg => $LayoutObject->BuildSelection(
            Data         => \@AllTrackers,
            Name         => 'IncidentTrackerID',
            ID           => 'IncidentTrackerID',
            SelectedID   => $Form->{IncidentTrackerID},
            PossibleNone => 1,
            Translation  => 0,
            Class        => 'W75pc',
        ),
        AllowedProjectIDsStrg => $LayoutObject->BuildSelection(
            Data        => \@Projects,
            Name        => 'AllowedProjectIDs',
            ID          => 'AllowedProjectIDs',
            SelectedID  => \@AllowedSelected,
            Multiple    => 1,
            Size        => 4,
            Translation => 0,
            Class       => 'W75pc',
        ),
        AgentGroupStrg => $LayoutObject->BuildSelection(
            Data         => \@Groups,
            Name         => 'AgentGroup',
            ID           => 'AgentGroup',
            SelectedID   => $Form->{AgentGroup},
            PossibleNone => 1,
            Translation  => 0,
            Class        => 'W75pc',
        ),
    );
}

sub _EnsureOption {
    my ( $Self, $ListRef, $ID ) = @_;

    my @List = @{ $ListRef || [] };
    return @List if !IsNumber($ID) && !( defined $ID && length $ID && $ID =~ m{\A\d+\z} );
    my $Want = 0 + $ID;
    for my $Row (@List) {
        return @List if defined $Row->{Key} && ( 0 + $Row->{Key} ) == $Want;
    }
    push @List, {
        Key   => $Want,
        Value => sprintf( '#%s (saved)', $Want ),
    };
    return @List;
}

sub _SplitIDs {
    my ( $Self, $Raw ) = @_;
    return () if !defined $Raw || !length $Raw;
    my @IDs;
    for my $Part ( split /[\s,;]+/, $Raw ) {
        next if !length $Part;
        next if $Part !~ m{\A\d+\z};
        push @IDs, 0 + $Part;
    }
    return @IDs;
}

sub _JoinIDs {
    my ( $Self, @Raw ) = @_;
    my @IDs;
    for my $Part (@Raw) {
        next if !defined $Part;
        if ( ref $Part eq 'ARRAY' ) {
            push @IDs, $Self->_SplitIDs( join ',', @{$Part} );
            next;
        }
        push @IDs, $Self->_SplitIDs($Part);
    }
    my %Seen;
    @IDs = grep { !$Seen{$_}++ } @IDs;
    return join ',', @IDs;
}

sub _FormFromRequest {
    my ( $Self, %Param ) = @_;

    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    return (
        Enabled             => $ParamObject->GetParam( Param => 'Enabled' )             ? 1 : 0,
        BaseURL             => $Self->_Trim( $ParamObject->GetParam( Param => 'BaseURL' ) ),
        OTRSBaseURL         => $Self->_Trim( $ParamObject->GetParam( Param => 'OTRSBaseURL' ) ),
        OTRSLinkPreview     => '',
        ProjectID           => $Self->_Trim( $ParamObject->GetParam( Param => 'ProjectID' ) ),
        TrackerID           => $Self->_Trim( $ParamObject->GetParam( Param => 'TrackerID' ) ),
        PriorityID          => $Self->_Trim( $ParamObject->GetParam( Param => 'PriorityID' ) ),
        DefaultDueDateDays  => $Self->_Trim( $ParamObject->GetParam( Param => 'DefaultDueDateDays' ) ) || '0',
        DefaultCustomFields => $ParamObject->GetParam( Param => 'DefaultCustomFields' ) // '',
        SubjectPrefix       => $Self->_Trim( $ParamObject->GetParam( Param => 'SubjectPrefix' ) ),
        Timeout             => $Self->_Trim( $ParamObject->GetParam( Param => 'Timeout' ) ) || '30',
        UITimeout           => $Self->_Trim( $ParamObject->GetParam( Param => 'UITimeout' ) ) || '5',
        CatalogCacheTTL     => $Self->_Trim( $ParamObject->GetParam( Param => 'CatalogCacheTTL' ) ) || '900',
        SyncComments        => $ParamObject->GetParam( Param => 'SyncComments' )        ? 1 : 0,
        SyncAttachments     => $ParamObject->GetParam( Param => 'SyncAttachments' )     ? 1 : 0,
        InboundSync         => $ParamObject->GetParam( Param => 'InboundSync' )         ? 1 : 0,
        NotifyOnStatusNote  => $ParamObject->GetParam( Param => 'NotifyOnStatusNote' )  ? 1 : 0,
        AutoRetry           => $ParamObject->GetParam( Param => 'AutoRetry' )           ? 1 : 0,
        FormLoadAllProjects => $ParamObject->GetParam( Param => 'FormLoadAllProjects' ) ? 1 : 0,
        AllowLegacyTLS      => $ParamObject->GetParam( Param => 'AllowLegacyTLS' )      ? 1 : 0,
        IncidentTrackerID   => $Self->_Trim( $ParamObject->GetParam( Param => 'IncidentTrackerID' ) ),
        SSLVersion          => $Self->_Trim( $ParamObject->GetParam( Param => 'SSLVersion' ) ),
        MaxAttachmentBytes  => $Self->_Trim( $ParamObject->GetParam( Param => 'MaxAttachmentBytes' ) ),
        SyncBatchLimit      => $Self->_Trim( $ParamObject->GetParam( Param => 'SyncBatchLimit' ) ),
        RetryBatchLimit     => $Self->_Trim( $ParamObject->GetParam( Param => 'RetryBatchLimit' ) ),
        AllowedProjectIDs   => $Self->_JoinIDs(
            $ParamObject->GetArray( Param => 'AllowedProjectIDs' )
        ),
        AgentGroup          => $Self->_Trim( $ParamObject->GetParam( Param => 'AgentGroup' ) ),
        StatusSync          => $ParamObject->GetParam( Param => 'StatusSync' ) // '',
        APIKeySet           => IsStringWithData( $ConfigObject->Get('Redmine::APIKey') ) ? 1 : 0,
    );
}

sub _CurrentForm {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $StatusSync   = $ConfigObject->Get('Redmine::StatusSync') || {};
    my $OTRSBase     = $Self->_NormalizeOTRSBaseURL( $ConfigObject->Get('Redmine::OTRSBaseURL') );
    my $Preview      = $Kernel::OM->Get('Kernel::System::Redmine')->TicketZoomURL( TicketID => 0 );
    $Preview =~ s{TicketID=0}{TicketID=<ID>};

    return (
        Enabled             => $ConfigObject->Get('Redmine::Enabled')             ? 1 : 0,
        BaseURL             => $ConfigObject->Get('Redmine::BaseURL')             // '',
        OTRSBaseURL         => $OTRSBase,
        OTRSLinkPreview     => $Preview,
        ProjectID           => $ConfigObject->Get('Redmine::ProjectID')           // '',
        TrackerID           => $ConfigObject->Get('Redmine::TrackerID')           // '',
        PriorityID          => $ConfigObject->Get('Redmine::PriorityID')          // '',
        DefaultDueDateDays  => $ConfigObject->Get('Redmine::DefaultDueDateDays')  // '0',
        DefaultCustomFields => $ConfigObject->Get('Redmine::DefaultCustomFields') // '',
        SubjectPrefix       => $ConfigObject->Get('Redmine::SubjectPrefix')       // '',
        Timeout             => $ConfigObject->Get('Redmine::Timeout')             // '30',
        UITimeout           => $ConfigObject->Get('Redmine::UITimeout')           // '5',
        CatalogCacheTTL     => $ConfigObject->Get('Redmine::CatalogCacheTTL')     // '900',
        SyncComments        => $ConfigObject->Get('Redmine::SyncComments')        ? 1 : 0,
        SyncAttachments     => $ConfigObject->Get('Redmine::SyncAttachments')     ? 1 : 0,
        InboundSync         => $ConfigObject->Get('Redmine::InboundSync')         ? 1 : 0,
        NotifyOnStatusNote  => $ConfigObject->Get('Redmine::NotifyOnStatusNote')  ? 1 : 0,
        AutoRetry           => $ConfigObject->Get('Redmine::AutoRetry')           ? 1 : 0,
        FormLoadAllProjects => $ConfigObject->Get('Redmine::FormLoadAllProjects') ? 1 : 0,
        AllowLegacyTLS      => $ConfigObject->Get('Redmine::AllowLegacyTLS')      ? 1 : 0,
        IncidentTrackerID   => $ConfigObject->Get('Redmine::IncidentTrackerID')   // '13',
        SSLVersion          => $ConfigObject->Get('Redmine::SSLVersion')          // 'auto',
        MaxAttachmentBytes  => $ConfigObject->Get('Redmine::MaxAttachmentBytes')  // '5000000',
        SyncBatchLimit      => $ConfigObject->Get('Redmine::SyncBatchLimit')      // '50',
        RetryBatchLimit     => $ConfigObject->Get('Redmine::RetryBatchLimit')     // '20',
        AllowedProjectIDs   => $ConfigObject->Get('Redmine::AllowedProjectIDs')   // '',
        AgentGroup          => $ConfigObject->Get('Redmine::AgentGroup')          // '',
        StatusSync          => $Self->_FormatStatusSync($StatusSync),
        APIKeySet           => IsStringWithData( $ConfigObject->Get('Redmine::APIKey') ) ? 1 : 0,
    );
}

sub _SaveSettings {
    my ( $Self, %Values ) = @_;

    my $SysConfigObject = $Kernel::OM->Get('Kernel::System::SysConfig');
    my $LogObject       = $Kernel::OM->Get('Kernel::System::Log');
    my @Dirty;

    # Optional keys that may land in XML after this Admin UI (skip if not registered yet).
    my %OptionalIfMissing = map { $_ => 1 } qw(
        Redmine::UITimeout
        Redmine::AllowLegacyTLS
        Redmine::AllowedProjectIDs
        Redmine::AgentGroup
    );

    SETTING:
    for my $Name ( sort keys %Values ) {

        # Skip undefined optional strings that can clear required-looking settings incorrectly
        next SETTING if !defined $Values{$Name};

        # O2: do not Force-steal locks — fail clearly if another admin holds the setting.
        # (If OTRS/package settings ever require Force for SettingLock, document here —
        # prefer DirtySettings deploy below over Force steal.)
        my $Lock = $SysConfigObject->SettingLock(
            Name   => $Name,
            UserID => $Self->{UserID} || 1,
        );
        if ( !$Lock ) {
            if ( $OptionalIfMissing{$Name} ) {
                $LogObject->Log(
                    Priority => 'notice',
                    Message  => "AdminRedmineBridge: skip $Name (not in SysConfig yet)",
                );
                next SETTING;
            }
            $LogObject->Log(
                Priority => 'error',
                Message  => "AdminRedmineBridge: cannot lock $Name (held by another user?)",
            );
            return (
                0,
                "Cannot lock setting $Name — it may be locked by another administrator.",
            );
        }

        my %Update = $SysConfigObject->SettingUpdate(
            Name              => $Name,
            IsValid           => 1,
            EffectiveValue    => $Values{$Name},
            ExclusiveLockGUID => $Lock,
            UserID            => $Self->{UserID} || 1,
        );
        $SysConfigObject->SettingUnlock( Name => $Name );

        if ( !$Update{Success} ) {
            my $Detail = $Update{Error} || $Update{Message} || 'unknown';
            $LogObject->Log(
                Priority => 'error',
                Message  => "AdminRedmineBridge: cannot update $Name ($Detail)",
            );
            return ( 0, "Cannot update setting $Name ($Detail)" );
        }
        push @Dirty, $Name;
    }

    # Deploy only settings we changed (not AllSettings => 1).
    my %Deploy = $SysConfigObject->ConfigurationDeploy(
        Comments      => 'AdminRedmineBridge settings',
        DirtySettings => \@Dirty,
        UserID        => $Self->{UserID} || 1,
    );
    if ( !$Deploy{Success} ) {
        # Some OTRS builds expect Force with DirtySettings for package-owned keys.
        %Deploy = $SysConfigObject->ConfigurationDeploy(
            Comments      => 'AdminRedmineBridge settings',
            DirtySettings => \@Dirty,
            Force         => 1,
            UserID        => $Self->{UserID} || 1,
        );
    }
    if ( !$Deploy{Success} ) {
        $LogObject->Log(
            Priority => 'error',
            Message  => 'AdminRedmineBridge: ConfigurationDeploy failed',
        );
        return ( 0, Translatable('Configuration deploy failed.') );
    }

    # Reload Kernel::Config so subsequent reads see new values in this process
    $Kernel::OM->ObjectsDiscard( Objects => ['Kernel::Config'] );

    # Clear only catalog cache (not TLS strategy cache).
    $Kernel::OM->Get('Kernel::System::Cache')->CleanUp( Type => 'RedmineBridgeCatalog' );

    return ( 1, undef );
}

sub _ParseStatusSync {
    my ( $Self, $Text ) = @_;

    my %Map;
    return \%Map if !defined $Text || !length $Text;

    LINE:
    for my $Line ( split /\n/, $Text ) {
        $Line =~ s{\A\s+}{};
        $Line =~ s{\s+\z}{};
        next LINE if !length $Line || $Line =~ m{\A#};

        my ( $Key, $Val );
        if ( $Line =~ m{\A([^=]+?)\s*=\s*(.*?)\s*\z} ) {
            $Key = $1;
            $Val = $2;
        }
        else {
            next LINE;
        }
        $Key =~ s{\s+\z}{};
        next LINE if !length $Key;
        $Map{$Key} = $Val;
    }
    return \%Map;
}

sub _FormatStatusSync {
    my ( $Self, $Map ) = @_;

    return '' if !IsHashRefWithData($Map);
    my @Lines;
    for my $Key ( sort keys %{$Map} ) {
        push @Lines, "$Key = $Map->{$Key}";
    }
    return join "\n", @Lines;
}

sub _Trim {
    my ( $Self, $Value ) = @_;
    return '' if !defined $Value;
    $Value =~ s{\A\s+}{};
    $Value =~ s{\s+\z}{};
    return $Value;
}

sub _NormalizeOTRSBaseURL {
    my ( $Self, $Raw ) = @_;
    return '' if !defined $Raw;
    $Raw =~ s{\A\s+}{};
    $Raw =~ s{\s+\z}{};
    return '' if !length $Raw;
    $Raw =~ s{\?.*\z}{};
    $Raw =~ s{/index\.pl\z}{}i;
    $Raw =~ s{/\z}{};
    return $Raw;
}

1;
