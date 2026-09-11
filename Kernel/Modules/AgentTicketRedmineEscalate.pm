# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
package Kernel::Modules::AgentTicketRedmineEscalate;

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

    # FormID is bound to the session in Run (S9); do not trust request alone in new().
    $Self->{FormID} = undef;

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    if ( !$Self->{TicketID} ) {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('Need TicketID!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    # S4: honour configured ticket permission (not hard-coded rw).
    my $Permission = $ConfigObject->Get("Ticket::Frontend::$Self->{Action}###Permission") || 'rw';
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $Access       = $TicketObject->TicketPermission(
        Type     => $Permission,
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID},
    );
    return $LayoutObject->NoPermission( WithHeader => 'yes' ) if !$Access;

    # Optional agent group gate (empty = no extra restriction).
    my $AgentGroup = $ConfigObject->Get('Redmine::AgentGroup');
    if ( IsStringWithData($AgentGroup) ) {
        my $Ok = $Kernel::OM->Get('Kernel::System::Group')->PermissionCheck(
            UserID    => $Self->{UserID},
            GroupName => $AgentGroup,
            Type      => 'rw',
        );
        return $LayoutObject->NoPermission( WithHeader => 'yes' ) if !$Ok;
    }

    my %PossibleActions = ( 1 => $Self->{Action} );
    my $ACL             = $TicketObject->TicketAcl(
        Data          => \%PossibleActions,
        Action        => $Self->{Action},
        TicketID      => $Self->{TicketID},
        ReturnType    => 'Action',
        ReturnSubType => '-',
        UserID        => $Self->{UserID},
    );
    my %AclAction = $TicketObject->TicketAclActionData();
    if ( $ACL || IsHashRefWithData( \%AclAction ) ) {
        my %AclActionLookup = reverse %AclAction;
        return $LayoutObject->NoPermission( WithHeader => 'yes' )
            if !$AclActionLookup{ $Self->{Action} };
    }

    # S9: bind FormID to session.
    my ( $FormOk, $FormErr ) = $Self->_EnsureFormID();
    if ( !$FormOk ) {
        return $LayoutObject->ErrorScreen(
            Message => $FormErr || Translatable('Invalid form session. Please reopen the escalate dialog.'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    my %Ticket = $TicketObject->TicketGet(
        TicketID      => $Self->{TicketID},
        DynamicFields => 1,
        UserID        => $Self->{UserID},
    );

    my $Subaction = $Self->{Subaction} || $ParamObject->GetParam( Param => 'Subaction' ) || '';

    # Manual inbound sync for this ticket (already linked).
    if ( $Subaction eq 'SyncNow' ) {
        $LayoutObject->ChallengeTokenCheck();
        return $Self->_SyncNowScreen(
            LayoutObject => $LayoutObject,
            Ticket       => \%Ticket,
            ConfigObject => $ConfigObject,
        );
    }

    if ( $Subaction eq 'Unlink' ) {
        $LayoutObject->ChallengeTokenCheck();
        return $Self->_UnlinkScreen(
            LayoutObject => $LayoutObject,
            Ticket       => \%Ticket,
            ConfigObject => $ConfigObject,
            ParamObject  => $ParamObject,
        );
    }

    if ( $Subaction eq 'Relink' ) {
        $LayoutObject->ChallengeTokenCheck();
        return $Self->_RelinkScreen(
            LayoutObject => $LayoutObject,
            Ticket       => \%Ticket,
            ConfigObject => $ConfigObject,
            ParamObject  => $ParamObject,
        );
    }

    # Already linked — show info in popup (do not silently close).
    if ( IsStringWithData( $Ticket{DynamicField_RedmineID} ) ) {
        return $Self->_AlreadyLinkedScreen(
            LayoutObject => $LayoutObject,
            Ticket       => \%Ticket,
            ConfigObject => $ConfigObject,
        );
    }

    my $RedmineObject = $Kernel::OM->Get('Kernel::System::Redmine');
    # Subaction already resolved above.

    # Mode from GET for server-side Create/Link switch (U1).
    my $ModeParam = $ParamObject->GetParam( Param => 'Mode' ) // '';
    my $LinkMode  = ( $ModeParam eq 'Link' ) ? 1 : 0;

    # ---- AJAX: extra files for escalate (UploadCache) ----
    if ( $Subaction eq 'AJAXUploadExtra' ) {
        $LayoutObject->ChallengeTokenCheck();
        my $UploadCacheObject = $Kernel::OM->Get('Kernel::System::Web::UploadCache');
        my $Max               = $ConfigObject->Get('Redmine::MaxAttachmentBytes') || 5_000_000;
        my %Payload           = ( Success => 0, Error => '', Files => [] );

        my %Upload = $ParamObject->GetUploadAll( Param => 'FileUpload' );
        if ( !%Upload || !defined $Upload{Content} ) {
            $Payload{Error} = 'No file';
        }
        elsif ( length( $Upload{Content} ) > $Max ) {
            $Payload{Error} = 'File too large';
        }
        else {
            my $Added = $UploadCacheObject->FormIDAddFile(
                FormID      => $Self->{FormID},
                Filename    => $Upload{Filename},
                Content     => $Upload{Content},
                ContentType => $Upload{ContentType} || 'application/octet-stream',
                Disposition => 'attachment',
            );
            if ($Added) {
                $Payload{Success} = 1;
                $Payload{Files}   = [ $Self->_ExtraFilesMeta() ];
            }
            else {
                $Payload{Error} = 'Upload cache failed';
            }
        }

        my $JSON = $Kernel::OM->Get('Kernel::System::JSON')->Encode( Data => \%Payload );
        return $LayoutObject->Attachment(
            ContentType => 'application/json; charset=utf-8',
            Content     => $JSON,
            Type        => 'inline',
            NoCache     => 1,
        );
    }

    if ( $Subaction eq 'AJAXDeleteExtra' ) {
        $LayoutObject->ChallengeTokenCheck();

        # S6: mutations must be POST (token stays in body, not query logs).
        my $Method = uc( $ENV{REQUEST_METHOD} || '' );
        if ( $Method ne 'POST' ) {
            my $JSON = $Kernel::OM->Get('Kernel::System::JSON')->Encode(
                Data => {
                    Success => 0,
                    Error   => 'POST required',
                    Files   => [],
                },
            );
            return $LayoutObject->Attachment(
                ContentType => 'application/json; charset=utf-8',
                Content     => $JSON,
                Type        => 'inline',
                NoCache     => 1,
            );
        }

        my $FileID = $ParamObject->GetParam( Param => 'FileID' );
        my $UploadCacheObject = $Kernel::OM->Get('Kernel::System::Web::UploadCache');
        my %Payload = ( Success => 0, Error => '', Files => [] );
        if ($FileID) {
            $UploadCacheObject->FormIDRemoveFile(
                FormID => $Self->{FormID},
                FileID => $FileID,
            );
            $Payload{Success} = 1;
            $Payload{Files}   = [ $Self->_ExtraFilesMeta() ];
        }
        else {
            $Payload{Error} = 'Need FileID';
        }
        my $JSON = $Kernel::OM->Get('Kernel::System::JSON')->Encode( Data => \%Payload );
        return $LayoutObject->Attachment(
            ContentType => 'application/json; charset=utf-8',
            Content     => $JSON,
            Type        => 'inline',
            NoCache     => 1,
        );
    }

    # ---- AJAX: trackers + assignees for selected project ----
    if ( $Subaction eq 'AJAXProjectMeta' ) {
        $LayoutObject->ChallengeTokenCheck();    # S6

        my $ProjectID = $ParamObject->GetParam( Param => 'ProjectID' );
        my %Payload   = (
            Success   => 0,
            Trackers  => [],
            Assignees => [],
            Error     => '',
        );
        if ( IsNumber($ProjectID) ) {
            my %TrackersRes = $RedmineObject->ListTrackers( ProjectID => $ProjectID );
            if ( $TrackersRes{Success} ) {
                $Payload{Trackers} = [
                    map {
                        {
                            id   => 0 + ( $_->{id} // 0 ),
                            name => $_->{name} // '',
                        }
                    } @{ $TrackersRes{Trackers} || [] }
                ];
                $Payload{Success} = 1;
            }
            else {
                $Payload{Error} = $TrackersRes{Error} || 'trackers';
            }
            my %AssigneesRes = $RedmineObject->ListProjectAssignees( ProjectID => $ProjectID );
            if ( $AssigneesRes{Success} ) {
                $Payload{Assignees} = [
                    map {
                        {
                            id   => 0 + ( $_->{id} // 0 ),
                            name => $_->{name} // '',
                        }
                    } @{ $AssigneesRes{Assignees} || [] }
                ];
            }
        }
        else {
            $Payload{Error} = 'Need ProjectID';
        }

        my $JSON = $Kernel::OM->Get('Kernel::System::JSON')->Encode( Data => \%Payload );
        return $LayoutObject->Attachment(
            ContentType => 'application/json; charset=utf-8',
            Content     => $JSON,
            Type        => 'inline',
            NoCache     => 1,
        );
    }

    my %Defaults = $RedmineObject->EscalateDefaults(
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID},
    );

    # ---- confirm / create ----
    if ( $Subaction eq 'Create' ) {
        $LayoutObject->ChallengeTokenCheck();

        my $ProjectID    = $ParamObject->GetParam( Param => 'ProjectID' );
        my $TrackerID    = $ParamObject->GetParam( Param => 'TrackerID' );
        my $PriorityID   = $ParamObject->GetParam( Param => 'PriorityID' );
        my $AssignedToID = $ParamObject->GetParam( Param => 'AssignedToID' );
        my $DueYear      = $ParamObject->GetParam( Param => 'DueDateYear' );
        my $DueMonth     = $ParamObject->GetParam( Param => 'DueDateMonth' );
        my $DueDay       = $ParamObject->GetParam( Param => 'DueDateDay' );
        my $MassRaw      = $ParamObject->GetParam( Param => 'MassIncident' );
        my $Confirm      = $ParamObject->GetParam( Param => 'ConfirmCreate' );
        my $Subject      = $ParamObject->GetParam( Param => 'IssueSubject' );
        my $Description  = $ParamObject->GetParam( Param => 'IssueDescription' );
        my $IncludeAtt   = $ParamObject->GetParam( Param => 'IncludeAttachments' ) ? 1 : 0;
        my @AttachKeys   = $ParamObject->GetArray( Param => 'AttachmentKey' );
        $Subject     = '' if !defined $Subject;
        $Description = '' if !defined $Description;
        $Subject =~ s{\A\s+}{};
        $Subject =~ s{\s+\z}{};
        $Description =~ s{\s+\z}{};

        # Normalize empty / PossibleNone placeholders from BuildSelection.
        $PriorityID   = undef if !defined $PriorityID   || $PriorityID eq ''   || $PriorityID eq '-';
        $AssignedToID = undef if !defined $AssignedToID || $AssignedToID eq '' || $AssignedToID eq '-';

        my $DueDate = '';
        if ( IsNumber($DueYear) && IsNumber($DueMonth) && IsNumber($DueDay) ) {
            $DueDate = sprintf( '%04d-%02d-%02d', 0 + $DueYear, 0 + $DueMonth, 0 + $DueDay );
        }

        # Mass incident: radios send 0/1; unset means not answered yet.
        my $MassIncident;
        my $MassIncidentSet = 0;
        if ( defined $MassRaw && ( $MassRaw eq '0' || $MassRaw eq '1' ) ) {
            $MassIncident    = 0 + $MassRaw;
            $MassIncidentSet = 1;
        }

        my $IncidentTrackerID = $ConfigObject->Get('Redmine::IncidentTrackerID') // 13;
        my $IsIncidentTracker = ( IsNumber($TrackerID) && IsNumber($IncidentTrackerID)
                && ( 0 + $TrackerID ) == ( 0 + $IncidentTrackerID ) ) ? 1 : 0;

        my %FormState = (
            ProjectID          => $ProjectID,
            TrackerID          => $TrackerID,
            PriorityID         => $PriorityID,
            AssignedToID       => $AssignedToID,
            DueDate            => $DueDate,
            DueDateYear        => $DueYear,
            DueDateMonth       => $DueMonth,
            DueDateDay         => $DueDay,
            MassIncident       => $MassIncidentSet ? $MassIncident : undef,
            MassIncidentSet    => $MassIncidentSet,
            IssueSubject       => $Subject,
            IssueDescription   => $Description,
            IncludeAttachments => $IncludeAtt,
            AttachmentKeys     => \@AttachKeys,
            AttachmentKeysSet  => 1,
            FormID             => $Self->{FormID},
            LinkMode           => 0,
        );

        if ( !$Confirm ) {
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $LayoutObject->{LanguageObject}->Translate('Please confirm issue creation.'),
                %FormState,
            );
        }
        if ( !IsNumber($ProjectID) || !IsNumber($TrackerID) ) {
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $LayoutObject->{LanguageObject}->Translate('Please select project and tracker.'),
                %FormState,
            );
        }
        if ( !length $Subject || !length $Description ) {
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $LayoutObject->{LanguageObject}->Translate('Please fill in subject and description.'),
                %FormState,
            );
        }
        if ( !IsNumber($AssignedToID) ) {
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $LayoutObject->{LanguageObject}->Translate('Please select an assignee.'),
                %FormState,
            );
        }
        if ( !length $DueDate ) {
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $LayoutObject->{LanguageObject}->Translate('Please fill in due date.'),
                %FormState,
            );
        }
        if ( $IsIncidentTracker && !$MassIncidentSet ) {
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $LayoutObject->{LanguageObject}->Translate('Please choose mass incident: Yes or No.'),
                %FormState,
            );
        }

        my %Result = eval {
            $RedmineObject->EscalateTicket(
                TicketID           => $Self->{TicketID},
                UserID             => $Self->{UserID},
                ProjectID          => $ProjectID,
                TrackerID          => $TrackerID,
                PriorityID         => $PriorityID,
                AssignedToID       => $AssignedToID,
                DueDate            => $DueDate,
                MassIncident       => $MassIncidentSet ? $MassIncident : 0,
                Subject            => $Subject,
                Description        => $Description,
                IncludeAttachments => $IncludeAtt,
                AttachmentKeys     => \@AttachKeys,
                FormID             => $Self->{FormID},
            );
        };
        if ($@) {
            my $Die = $@;
            $Die =~ s{\s+at\s+\S+.*}{}s;
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "AgentTicketRedmineEscalate Create died: $Die",
            );
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $Die || $LayoutObject->{LanguageObject}->Translate('Could not create Redmine issue.'),
                %FormState,
            );
        }

        if ( $Result{Success} ) {
            $Kernel::OM->Get('Kernel::System::Web::UploadCache')->FormIDRemove(
                FormID => $Self->{FormID},
            );

            # K11: show Warning before close so attachment failures stay visible.
            if ( IsStringWithData( $Result{Warning} ) ) {
                return $Self->_ResultScreen(
                    LayoutObject => $LayoutObject,
                    Title        => Translatable('Redmine issue created'),
                    Message      => $Result{Warning},
                    Comment      => $Result{URL} || '',
                    Type         => 'Warning',
                    ClosePopup   => 1,
                );
            }

            return $LayoutObject->PopupClose(
                Reload => 1,
            );
        }
        return $Self->_FormScreen(
            LayoutObject => $LayoutObject,
            Ticket       => \%Ticket,
            Defaults     => \%Defaults,
            Error        => $Result{Error}
                || $LayoutObject->{LanguageObject}->Translate('Could not create Redmine issue.'),
            %FormState,
        );
    }

    # ---- link existing issue ----
    if ( $Subaction eq 'Link' ) {
        $LayoutObject->ChallengeTokenCheck();

        my $Existing = $ParamObject->GetParam( Param => 'ExistingIssueID' ) // '';
        my $Confirm  = $ParamObject->GetParam( Param => 'ConfirmLink' );
        $Existing =~ s{\A\s+}{};
        $Existing =~ s{\s+\z}{};

        my %FormState = (
            LinkMode         => 1,
            ExistingIssueID  => $Existing,
            ProjectID        => $ParamObject->GetParam( Param => 'ProjectID' ),
            TrackerID        => $ParamObject->GetParam( Param => 'TrackerID' ),
            IssueSubject     => $ParamObject->GetParam( Param => 'IssueSubject' ) // $Defaults{Subject},
            IssueDescription => $ParamObject->GetParam( Param => 'IssueDescription' )
                // $Defaults{Description},
        );

        if ( !$Confirm ) {
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $LayoutObject->{LanguageObject}->Translate('Please confirm linking to the existing issue.'),
                %FormState,
            );
        }
        if ( !length $Existing ) {
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $LayoutObject->{LanguageObject}->Translate('Please enter Redmine issue ID or URL.'),
                %FormState,
            );
        }

        my %Result = eval {
            $RedmineObject->LinkTicketToIssue(
                TicketID => $Self->{TicketID},
                UserID   => $Self->{UserID},
                IssueID  => $Existing,
            );
        };
        if ($@) {
            my $Die = $@;
            $Die =~ s{\s+at\s+\S+.*}{}s;
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "AgentTicketRedmineEscalate Link died: $Die",
            );
            return $Self->_FormScreen(
                LayoutObject => $LayoutObject,
                Ticket       => \%Ticket,
                Defaults     => \%Defaults,
                Error        => $Die || $LayoutObject->{LanguageObject}->Translate('Could not link Redmine issue.'),
                %FormState,
            );
        }

        if ( $Result{Success} ) {
            if ( IsStringWithData( $Result{Warning} ) ) {
                return $Self->_ResultScreen(
                    LayoutObject => $LayoutObject,
                    Title        => Translatable('Redmine issue linked'),
                    Message      => $Result{Warning},
                    Comment      => $Result{URL} || '',
                    Type         => 'Warning',
                    ClosePopup   => 1,
                );
            }
            return $LayoutObject->PopupClose(
                Reload => 1,
            );
        }
        return $Self->_FormScreen(
            LayoutObject => $LayoutObject,
            Ticket       => \%Ticket,
            Defaults     => \%Defaults,
            Error        => $Result{Error}
                || $LayoutObject->{LanguageObject}->Translate('Could not link Redmine issue.'),
            %FormState,
        );
    }

    # ---- default: confirmation form (server Mode=Create|Link) ----
    return $Self->_FormScreen(
        LayoutObject => $LayoutObject,
        Ticket       => \%Ticket,
        Defaults     => \%Defaults,
        LinkMode     => $LinkMode,
    );
}

sub _EnsureFormID {
    my ( $Self, %Param ) = @_;

    my $ParamObject     = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $ParamFormID     = $ParamObject->GetParam( Param => 'FormID' );
    my $SessionFormID   = $Self->{UserRedmineFormID} || '';

    # No param: create and bind (first open of the dialog).
    if ( !IsStringWithData($ParamFormID) ) {
        if ( IsStringWithData($SessionFormID) ) {
            $Self->{FormID} = $SessionFormID;
            return ( 1, undef );
        }
        my $New = $Kernel::OM->Get('Kernel::System::Web::UploadCache')->FormIDCreate();
        $Self->_StoreSessionFormID($New);
        $Self->{FormID} = $New;
        return ( 1, undef );
    }

    # Param present: must match session when session already has one.
    if ( IsStringWithData($SessionFormID) && $ParamFormID ne $SessionFormID ) {
        return ( 0, Translatable('Invalid form session. Please reopen the escalate dialog.') );
    }

    # First create with a client FormID (rare): accept and bind.
    if ( !IsStringWithData($SessionFormID) ) {
        $Self->_StoreSessionFormID($ParamFormID);
        $Self->{FormID} = $ParamFormID;
        return ( 1, undef );
    }

    $Self->{FormID} = $SessionFormID;
    return ( 1, undef );
}

sub _StoreSessionFormID {
    my ( $Self, $FormID ) = @_;

    return if !$FormID || !$Self->{SessionID};

    $Kernel::OM->Get('Kernel::System::AuthSession')->UpdateSessionID(
        SessionID => $Self->{SessionID},
        Key       => 'UserRedmineFormID',
        Value     => $FormID,
    );
    $Self->{UserRedmineFormID} = $FormID;
    return 1;
}

sub _EscalationStatusLabel {
    my ( $Self, $Raw, $LayoutObject ) = @_;

    return '' if !IsStringWithData($Raw);

    # Machine codes (Issue mixin) + legacy Russian literals.
    my %Map = (
        pending  => 'pending',
        created  => 'created',
        error    => 'error',
        linked   => 'linked',
        Pending  => 'pending',
        Created  => 'created',
        Error    => 'error',
        Linked   => 'linked',
        'Ошибка' => 'error',
        'Создано' => 'created',
        'Связано' => 'linked',
    );

    my $Key = $Map{$Raw} || $Raw;
    return $LayoutObject->{LanguageObject}->Translate($Key);
}

sub _FormScreen {
    my ( $Self, %Param ) = @_;

    my $LayoutObject  = $Param{LayoutObject};
    my $ConfigObject  = $Kernel::OM->Get('Kernel::Config');
    my $RedmineObject = $Kernel::OM->Get('Kernel::System::Redmine');
    my %Ticket        = %{ $Param{Ticket} || {} };
    my %Defaults      = %{ $Param{Defaults} || {} };

    my $DefaultProject = $Param{ProjectID}
        // $Ticket{DynamicField_RedmineProjectID}
        // $ConfigObject->Get('Redmine::ProjectID');
    my $ProjectID = $DefaultProject;

    # Catalog uses Redmine::UITimeout internally (EscalateFormCatalog / _CatalogUITimeout).
    my %Catalog = eval { $RedmineObject->EscalateFormCatalog( ProjectID => $ProjectID ) };
    if ($@) {
        my $Die = $@;
        $Die =~ s{\s+at\s+\S+.*}{}s;
        %Catalog = ( Success => 0, Error => $Die );
    }
    my @ProjectList;
    my @Projects = ( IsArrayRefWithData( $Catalog{Projects} ) ) ? @{ $Catalog{Projects} } : ();
    if ( $Catalog{Success} ) {
        for my $P (@Projects) {
            next if !$RedmineObject->_IsAllowedRedmineProjectID( $P->{id} );
            push @ProjectList, {
                Key   => $P->{id},
                Value => "$P->{name} (#$P->{id})",
            };
        }
        # Drop stale ProjectID (e.g. ticket DF outside create allow-list).
        if (
            @ProjectList
            && IsNumber($ProjectID)
            && !grep { ( 0 + $_->{Key} ) == ( 0 + $ProjectID ) } @ProjectList
            )
        {
            $ProjectID = $ProjectList[0]->{Key};
            %Catalog   = eval {
                $RedmineObject->EscalateFormCatalog( ProjectID => $ProjectID );
            };
            if ($@) {
                my $Die = $@;
                $Die =~ s{\s+at\s+\S+.*}{}s;
                %Catalog = ( Success => 0, Error => $Die );
            }
        }
    }

    my @TrackerList;
    my @Trackers = ( IsArrayRefWithData( $Catalog{Trackers} ) ) ? @{ $Catalog{Trackers} } : ();
    if ( $Catalog{Success} ) {
        for my $T (@Trackers) {
            push @TrackerList, {
                Key   => $T->{id},
                Value => "$T->{name} (#$T->{id})",
            };
        }
    }

    my @PriorityList;
    my $DefaultPriorityFromList;
    my @Priorities = ( IsArrayRefWithData( $Catalog{Priorities} ) ) ? @{ $Catalog{Priorities} } : ();
    for my $P (@Priorities) {
        push @PriorityList, {
            Key   => $P->{id},
            Value => $P->{name},
        };
        $DefaultPriorityFromList = $P->{id} if $P->{is_default};
    }

    my @AssigneeList;
    my @Assignees = ( IsArrayRefWithData( $Catalog{Assignees} ) ) ? @{ $Catalog{Assignees} } : ();
    for my $A (@Assignees) {
        push @AssigneeList, {
            Key   => $A->{id},
            Value => $A->{name},
        };
    }

    my $DefaultTracker = $Param{TrackerID}
        // $Ticket{DynamicField_RedmineTrackerID}
        // $ConfigObject->Get('Redmine::TrackerID');

    my $IncidentTrackerID = $ConfigObject->Get('Redmine::IncidentTrackerID') // 13;
    # If SysConfig/default tracker is not in this project, fall back to Инцидент when available.
    if ( IsNumber($IncidentTrackerID) && @Trackers ) {
        my $DefaultOk = (
            IsNumber($DefaultTracker)
                && grep { ( 0 + ( $_->{id} // 0 ) ) == ( 0 + $DefaultTracker ) } @Trackers
        ) ? 1 : 0;
        if ( !$DefaultOk ) {
            my ($Incident) = grep { ( 0 + ( $_->{id} // 0 ) ) == ( 0 + $IncidentTrackerID ) } @Trackers;
            $DefaultTracker = $IncidentTrackerID if $Incident;
        }
    }

    my $DefaultPriority = $Param{PriorityID}
        // $ConfigObject->Get('Redmine::PriorityID')
        // $DefaultPriorityFromList;

    my $DefaultAssignee = $Param{AssignedToID};

    my $DefaultDueDate = $Param{DueDate};
    if ( !defined $DefaultDueDate || !length $DefaultDueDate ) {
        $DefaultDueDate = $RedmineObject->_DefaultDueDate();
    }
    my ( $DueY, $DueM, $DueD ) = ( '', '', '' );
    if ( $Param{DueDateYear} && $Param{DueDateMonth} && $Param{DueDateDay} ) {
        $DueY = $Param{DueDateYear};
        $DueM = $Param{DueDateMonth};
        $DueD = $Param{DueDateDay};
    }
    elsif ( $DefaultDueDate =~ m{\A(\d{4})-(\d{2})-(\d{2})\z} ) {
        ( $DueY, $DueM, $DueD ) = ( $1, $2, $3 );
    }

    my $DueDateStrg = $LayoutObject->BuildDateSelection(
        Prefix          => 'DueDate',
        Format          => 'DateInputFormat',
        Validate        => 1,
        DueDateYear     => $DueY,
        DueDateMonth    => $DueM,
        DueDateDay      => $DueD,
        DueDateClass    => 'Validate_Required',
        DueDateRequired => 1,
    );

    my $IsIncidentTracker = (
        IsNumber($DefaultTracker)
            && IsNumber($IncidentTrackerID)
            && ( 0 + $DefaultTracker ) == ( 0 + $IncidentTrackerID )
    ) ? 1 : 0;

    my $MassIncidentSet = $Param{MassIncidentSet} ? 1 : 0;
    my $MassIncident    = $MassIncidentSet ? ( $Param{MassIncident} ? 1 : 0 ) : undef;

    # Native selects — OTRS Modernize/InputFields can submit a different value
    # than what the agent sees (historically remapped Инцидент → Задача).
    my $ProjectStrg = $LayoutObject->BuildSelection(
        Data         => \@ProjectList,
        Name         => 'ProjectID',
        SelectedID   => $ProjectID,
        PossibleNone => 0,
        Translation  => 0,
        Class        => 'Validate_Required W75pc',
    );
    my $TrackerStrg = $LayoutObject->BuildSelection(
        Data         => \@TrackerList,
        Name         => 'TrackerID',
        ID           => 'TrackerID',
        SelectedID   => $DefaultTracker,
        PossibleNone => 0,
        Translation  => 0,
        Class        => 'Validate_Required W75pc',
    );
    my $PriorityStrg = $LayoutObject->BuildSelection(
        Data         => \@PriorityList,
        Name         => 'PriorityID',
        SelectedID   => $DefaultPriority,
        PossibleNone => 1,
        Translation  => 0,
        Class        => 'W75pc',
    );
    my $AssigneeStrg = $LayoutObject->BuildSelection(
        Data         => \@AssigneeList,
        Name         => 'AssignedToID',
        ID           => 'AssignedToID',
        SelectedID   => $DefaultAssignee,
        PossibleNone => 1,
        Translation  => 0,
        Class        => 'Validate_Required W75pc',
    );

    my $IssueSubject = defined $Param{IssueSubject}
        ? $Param{IssueSubject}
        : ( $Defaults{Subject} // '' );
    my $IssueDescription = defined $Param{IssueDescription}
        ? $Param{IssueDescription}
        : ( $Defaults{Description} // '' );

    my @AttachmentList;
    if ( $ConfigObject->Get('Redmine::SyncAttachments') ) {
        eval {
            @AttachmentList = $RedmineObject->ListEscalateAttachments(
                TicketID => $Self->{TicketID},
            );
            1;
        } or do {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => 'AgentTicketRedmineEscalate ListEscalateAttachments: ' . ( $@ || 'failed' ),
            );
            @AttachmentList = ();
        };
    }

    my %SelectedKeys;
    if ( $Param{AttachmentKeysSet} ) {
        for my $Key ( @{ $Param{AttachmentKeys} || [] } ) {
            $SelectedKeys{$Key} = 1 if defined $Key && length $Key;
        }
    }

    my $IncludeAttachments = 1;
    if ( exists $Param{IncludeAttachments} ) {
        $IncludeAttachments = $Param{IncludeAttachments} ? 1 : 0;
    }

    for my $File (@AttachmentList) {
        if ( $Param{AttachmentKeysSet} ) {
            $File->{Checked} = $SelectedKeys{ $File->{Key} } ? 1 : 0;
        }
        else {
            $File->{Checked} = $File->{TooLarge} ? 0 : 1;
        }
        $File->{DownloadURL}
            = $LayoutObject->{Baselink}
            . 'Action=AgentTicketAttachment'
            . ";TicketID=$Self->{TicketID}"
            . ";ArticleID=$File->{ArticleID}"
            . ";FileID=$File->{FileID}";
        $File->{PreviewURL} = $File->{IsImage} ? $File->{DownloadURL} : '';
        my $Short = $File->{Filename} // '';
        if ( length($Short) > 14 ) {
            $Short = substr( $Short, 0, 11 ) . '...';
        }
        $File->{ShortName} = $Short;
    }

    my @ExtraFiles = $Self->_ExtraFilesMeta();
    for my $File (@ExtraFiles) {
        my $Short = $File->{Filename} // '';
        if ( length($Short) > 14 ) {
            $Short = substr( $Short, 0, 11 ) . '...';
        }
        $File->{ShortName} = $Short;
    }

    my $EscalationStatus = $Ticket{DynamicField_RedmineEscalationStatus} // '';
    my $EscalationStatusLabel
        = $Self->_EscalationStatusLabel( $EscalationStatus, $LayoutObject );

    my $Output = $LayoutObject->Header(
        Type  => 'Small',
        Value => $Ticket{TicketNumber},
        Title => Translatable('Create Redmine issue'),
    );
    my $JSONObject = $Kernel::OM->Get('Kernel::System::JSON');
    my $Lang       = $LayoutObject->{LanguageObject};

    $Output .= $LayoutObject->Output(
        TemplateFile => 'AgentTicketRedmineEscalate',
        Data         => {
            %Ticket,
            ProjectStrg            => $ProjectStrg,
            TrackerStrg            => $TrackerStrg,
            PriorityStrg           => $PriorityStrg,
            AssigneeStrg           => $AssigneeStrg,
            DueDateStrg            => $DueDateStrg,
            DueDate                => $DefaultDueDate,
            MassIncident           => $MassIncident,
            MassIncidentSet        => $MassIncidentSet,
            IncidentTrackerID      => 0 + ( $IncidentTrackerID || 13 ),
            IncidentTrackerIDJSON  => $JSONObject->Encode(
                Data => '' . ( 0 + ( $IncidentTrackerID || 13 ) )
            ),
            IsIncidentTracker      => $IsIncidentTracker,
            IssueSubject           => $IssueSubject,
            IssueDescription       => $IssueDescription,
            AttachmentList         => \@AttachmentList,
            HasAttachments         => scalar @AttachmentList ? 1 : 0,
            ExtraFiles             => \@ExtraFiles,
            HasExtraFiles          => scalar @ExtraFiles ? 1 : 0,
            FormID                 => $Self->{FormID},
            MaxAttachmentBytes     => 0 + (
                $ConfigObject->Get('Redmine::MaxAttachmentBytes') || 5_000_000
            ),
            MaxAttachmentBytesJSON => $JSONObject->Encode(
                Data => 0 + ( $ConfigObject->Get('Redmine::MaxAttachmentBytes') || 5_000_000 )
            ),
            MsgUploadingJSON => $JSONObject->Encode(
                Data => $Lang->Translate('Uploading...')
            ),
            MsgReadyJSON => $JSONObject->Encode(
                Data => $Lang->Translate('Files ready to attach.')
            ),
            MsgTooLargeJSON => $JSONObject->Encode(
                Data => $Lang->Translate('File too large')
            ),
            MsgUploadFailJSON => $JSONObject->Encode(
                Data => $Lang->Translate('Upload failed')
            ),
            MsgRemoveJSON => $JSONObject->Encode(
                Data => $Lang->Translate('Remove')
            ),
            IncludeAttachments     => $IncludeAttachments,
            LinkMode               => $Param{LinkMode} ? 1 : 0,
            ExistingIssueID        => $Param{ExistingIssueID} // '',
            Error                  => $Param{Error},
            ProjectsOK             => $Catalog{Success} ? 1 : 0,
            ProjectsErr            => $Catalog{Error} || '',
            EscalationStatus       => $EscalationStatus,
            EscalationStatusLabel  => $EscalationStatusLabel,
        },
    );
    $Output .= $LayoutObject->Footer( Type => 'Small' );
    return $Output;
}

sub _ExtraFilesMeta {
    my ( $Self, %Param ) = @_;

    my $FormID = $Param{FormID} || $Self->{FormID};
    return () if !$FormID;

    my $RedmineObject = $Kernel::OM->Get('Kernel::System::Redmine');
    my @Meta          = $Kernel::OM->Get('Kernel::System::Web::UploadCache')->FormIDGetAllFilesMeta(
        FormID => $FormID,
    );
    my @Out;
    for my $File (@Meta) {
        my $Filename = $File->{Filename} // 'file';
        my ($Ext) = $Filename =~ m{\.([A-Za-z0-9]{1,8})\z};
        $Ext = $Ext ? uc($Ext) : 'FILE';
        $Ext = 'FILE' if length($Ext) > 5;
        my $Size = 0 + ( $File->{FilesizeRaw} // 0 );
        if ( !$Size && defined $File->{Filesize} && $File->{Filesize} =~ m{\A(\d+)\z} ) {
            $Size = 0 + $1;
        }
        my $IsImage = ( ( $File->{ContentType} // '' ) =~ m{\Aimage/(?:png|jpe?g|gif|webp|bmp)\b}i ) ? 1 : 0;
        my ( $BadgeBg, $BadgeFg ) = $RedmineObject->_AttachmentBadgeColors(
            Ext         => $Ext,
            ContentType => $File->{ContentType},
            IsImage     => $IsImage,
        );
        push @Out, {
            FileID      => $File->{FileID},
            Filename    => $Filename,
            ContentType => $File->{ContentType} || 'application/octet-stream',
            Size        => $Size,
            SizeLabel   => $RedmineObject->_FormatByteSize($Size),
            Ext         => $Ext,
            IsImage     => $IsImage,
            BadgeBg     => $BadgeBg,
            BadgeFg     => $BadgeFg,
        };
    }
    return @Out;
}

sub _TicketRedmineURL {
    my ( $Self, %Param ) = @_;

    my $Ticket       = $Param{Ticket}       || {};
    my $ConfigObject = $Param{ConfigObject} || $Kernel::OM->Get('Kernel::Config');
    my $IssueID      = $Ticket->{DynamicField_RedmineID} // '';
    my $URL          = $Ticket->{DynamicField_RedmineURL} // '';
    return $URL if length $URL;

    my $Base = $ConfigObject->Get('Redmine::BaseURL') || '';
    $Base =~ s{/\z}{};
    return '' if !length $Base || !length $IssueID;
    return "$Base/issues/$IssueID";
}

sub _AlreadyLinkedScreen {
    my ( $Self, %Param ) = @_;

    my $Ticket  = $Param{Ticket} || {};
    my $IssueID = $Ticket->{DynamicField_RedmineID} // '';
    my $URL     = $Self->_TicketRedmineURL(%Param);
    my $Lang    = $Param{LayoutObject}->{LanguageObject};
    my $Redmine = $Kernel::OM->Get('Kernel::System::Redmine');

    my @Siblings = $Redmine->TicketsByRedmineIssueID(
        IssueID         => $IssueID,
        ExcludeTicketID => $Self->{TicketID},
        UserID          => $Self->{UserID},
    );

    return $Self->_ResultScreen(
        LayoutObject    => $Param{LayoutObject},
        Title           => Translatable('Already linked'),
        Message         => $Lang->Translate( 'Redmine issue already linked: #%s', $IssueID ),
        Comment         => length $URL ? $URL : '',
        Type            => 'Notice',
        OpenURL         => $URL,
        ShowSyncButton  => 1,
        ShowLinkActions => 1,
        TicketID        => $Self->{TicketID},
        SiblingTickets  => \@Siblings,
        Error           => $Param{Error},
        SyncOK          => $Param{SyncOK},
    );
}

sub _UnlinkScreen {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Param{LayoutObject};
    my $Lang         = $LayoutObject->{LanguageObject};
    my $ParamObject  = $Param{ParamObject};
    my $Ticket       = $Param{Ticket} || {};
    my $URL          = $Self->_TicketRedmineURL(%Param);

    if ( !$ParamObject->GetParam( Param => 'ConfirmUnlink' ) ) {
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Lang->Translate('Please confirm unlinking from the Redmine issue.'),
        );
    }

    if ( !IsStringWithData( $Ticket->{DynamicField_RedmineID} ) ) {
        return $Self->_ResultScreen(
            LayoutObject => $LayoutObject,
            Title        => Translatable('Redmine'),
            Message      => $Lang->Translate('No Redmine issue is linked to this ticket.'),
            Type         => 'Error',
        );
    }

    my $Redmine = $Kernel::OM->Get('Kernel::System::Redmine');
    my %Result  = eval {
        $Redmine->UnlinkTicketFromIssue(
            TicketID => $Self->{TicketID},
            UserID   => $Self->{UserID},
        );
    };
    my $Die = $@ || '';
    if ($Die) {
        $Die =~ s{[^\x09\x0A\x0D\x20-\x7E\x{A0}-\x{FFFF}]}{?}g;
        $Die =~ s{\s+at\s+\S+.*}{}s;
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Die || $Lang->Translate('Could not unlink Redmine issue.'),
        );
    }
    if ( !$Result{Success} ) {
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Result{Error} || $Lang->Translate('Could not unlink Redmine issue.'),
        );
    }

    return $Self->_ResultScreen(
        LayoutObject => $LayoutObject,
        Title        => Translatable('Already linked'),
        Message      => $Lang->Translate('Unlinked from Redmine.'),
        Comment      => $Result{IssueID}
        ? $Lang->Translate( 'Redmine issue #%s is no longer linked.', $Result{IssueID} )
        : '',
        Type => 'Notice',
    );
}

sub _RelinkScreen {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Param{LayoutObject};
    my $Lang         = $LayoutObject->{LanguageObject};
    my $ParamObject  = $Param{ParamObject};
    my $Existing     = $ParamObject->GetParam( Param => 'ExistingIssueID' ) // '';
    $Existing =~ s{\A\s+}{};
    $Existing =~ s{\s+\z}{};

    if ( !$ParamObject->GetParam( Param => 'ConfirmRelink' ) ) {
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Lang->Translate('Please confirm relinking to another Redmine issue.'),
        );
    }
    if ( !length $Existing ) {
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Lang->Translate('Please enter Redmine issue ID or URL.'),
        );
    }

    my $Redmine = $Kernel::OM->Get('Kernel::System::Redmine');
    my %Result  = eval {
        $Redmine->RelinkTicketToIssue(
            TicketID => $Self->{TicketID},
            UserID   => $Self->{UserID},
            IssueID  => $Existing,
        );
    };
    my $Die = $@ || '';
    if ($Die) {
        $Die =~ s{[^\x09\x0A\x0D\x20-\x7E\x{A0}-\x{FFFF}]}{?}g;
        $Die =~ s{\s+at\s+\S+.*}{}s;
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Die || $Lang->Translate('Could not relink Redmine issue.'),
        );
    }
    if ( !$Result{Success} ) {
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Result{Error} || $Lang->Translate('Could not relink Redmine issue.'),
        );
    }

    return $Self->_ResultScreen(
        LayoutObject => $LayoutObject,
        Title        => Translatable('Already linked'),
        Message      => $Lang->Translate('Relinked to Redmine.'),
        Comment      => $Result{URL}
            || (
            $Result{IssueID}
            ? $Lang->Translate( 'Redmine issue already linked: #%s', $Result{IssueID} )
            : ''
            ),
        Type    => 'Notice',
        OpenURL => $Result{URL} || '',
    );
}

sub _SyncNowScreen {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Param{LayoutObject};
    my $Lang         = $LayoutObject->{LanguageObject};
    my $Ticket       = $Param{Ticket} || {};
    my $URL          = $Self->_TicketRedmineURL(%Param);
    my $IssueID      = $Ticket->{DynamicField_RedmineID} // '';

    if ( !IsStringWithData($IssueID) ) {
        return $Self->_ResultScreen(
            LayoutObject => $LayoutObject,
            Title        => Translatable('Redmine'),
            Message      => $Lang->Translate('No Redmine issue is linked to this ticket.'),
            Type         => 'Error',
        );
    }

    my $Redmine = $Kernel::OM->Get('Kernel::System::Redmine');
    my %Result  = eval {
        $Redmine->SyncTicketFromRedmine(
            TicketID => $Self->{TicketID},
            UserID   => $Self->{UserID},
        );
    };
    my $Die = $@ || '';
    if ($Die) {
        $Die =~ s{[^\x09\x0A\x0D\x20-\x7E\x{A0}-\x{FFFF}]}{?}g;
        $Die =~ s{\s+at\s+\S+.*}{}s;
        $Die =~ s{\s+}{ }g;
        $Die =~ s{\A\s+|\s+\z}{}g;
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Die || $Lang->Translate('Could not sync from Redmine.'),
        );
    }

    if ( !$Result{Success} ) {
        return $Self->_AlreadyLinkedScreen(
            %Param,
            Error => $Result{Error} || $Result{Status} || $Lang->Translate('Could not sync from Redmine.'),
        );
    }

    # Re-read ticket after sync for siblings / status.
    my %Fresh = $Kernel::OM->Get('Kernel::System::Ticket')->TicketGet(
        TicketID      => $Self->{TicketID},
        DynamicFields => 1,
        UserID        => $Self->{UserID},
        Silent        => 1,
    );
    return $Self->_AlreadyLinkedScreen(
        LayoutObject => $LayoutObject,
        Ticket       => \%Fresh,
        ConfigObject => $Param{ConfigObject},
        Error        => undef,
        SyncOK       => $Lang->Translate('Synced from Redmine.'),
    );
}

sub _ResultScreen {
    my ( $Self, %Param ) = @_;
    my $LayoutObject = $Param{LayoutObject};
    my $Lang         = $LayoutObject->{LanguageObject};
    my $Output       = $LayoutObject->Header(
        Type  => 'Small',
        Title => $Param{Title} || Translatable('Redmine'),
    );

    my $Action = $LayoutObject->Ascii2Html( Text => $Self->{Action} );
    my $TID    = $LayoutObject->Ascii2Html( Text => '' . ( $Param{TicketID} || $Self->{TicketID} || '' ) );
    my $Token  = $LayoutObject->Ascii2Html( Text => $LayoutObject->{UserChallengeToken} // '' );
    my $CGI    = $LayoutObject->Ascii2Html( Text => ( $LayoutObject->{CGIHandle} || 'index.pl' ) );

    $Output .= <<"CSS";
<style type="text/css">
.RedmineLinkedPopup .Content {
  text-align: left;
}
.RedmineLinkedPopup .RedmineLinkedInner {
  width: 100%;
  max-width: 34em;
  margin: 0 auto;
  padding: 0 0.5em;
  text-align: left;
  box-sizing: border-box;
}
.RedmineLinkedPopup .RedmineLinkedBlock {
  margin: 0 0 1em;
  padding: 0 0 0.85em;
  border-bottom: 1px solid #cfd8e3;
  text-align: left;
}
.RedmineLinkedPopup .RedmineLinkedTitle {
  margin: 0 0 0.55em;
  padding: 0;
  font-size: 1.05em;
  font-weight: 600;
  color: #2f3e4d;
  text-align: left;
}
.RedmineLinkedPopup .RedmineLinkedMeta,
.RedmineLinkedPopup .RedmineLinkedBlock p,
.RedmineLinkedPopup .RedmineSiblingList {
  margin: 0.35em 0;
  padding: 0;
  list-style: none;
  word-break: break-word;
  text-align: left;
}
.RedmineLinkedPopup .RedmineSiblingList li {
  margin: 0.2em 0;
}
.RedmineLinkedPopup .RedmineLinkedActions {
  margin-top: 0.65em;
  text-align: left;
}
.RedmineLinkedPopup .RedmineInlineForm {
  display: inline;
  margin: 0 0.35em 0 0;
}
.RedmineLinkedPopup .RedmineLinkedBlock label {
  display: block;
  margin: 0.45em 0 0.25em;
  font-weight: normal;
  text-align: left;
}
.RedmineLinkedPopup input[type="text"].RedmineIssueInput {
  display: block;
  width: 100%;
  max-width: 100%;
  margin: 0 0 0.55em;
  box-sizing: border-box;
  padding: 5px 8px;
  text-align: left;
}
.RedmineLinkedPopup .RedmineConfirmLabel {
  display: block;
  margin: 0.45em 0;
  text-align: left;
}
.RedmineLinkedPopup .RedmineConfirmLabel input {
  margin-right: 0.4em;
  vertical-align: middle;
}
.RedmineLinkedPopup .RedmineLinkedFooter {
  margin: 0;
  padding: 0;
  text-align: left;
}
.RedmineLinkedPopup .RedmineLinkedFooter .CallForAction {
  min-width: 0;
}
</style>
CSS

    $Output .= q{<div class="LayoutPopup ARIARoleMain RedmineLinkedPopup"><div class="Content"><div class="RedmineLinkedInner">};

    if ( IsStringWithData( $Param{Error} ) ) {
        my $Err = $LayoutObject->Ascii2Html( Text => $Param{Error} );
        $Output .= qq{<div class="MessageBox Error"><p>$Err</p></div>};
    }
    if ( IsStringWithData( $Param{SyncOK} ) ) {
        my $Ok = $LayoutObject->Ascii2Html( Text => $Param{SyncOK} );
        $Output .= qq{<div class="MessageBox Notice"><p>$Ok</p></div>};
    }

    my $Type = $Param{Type} || 'Error';
    if ( $Type eq 'Warning' ) {
        $Output .= $LayoutObject->Warning(
            Message => $Param{Message},
            Comment => $Param{Comment} || '',
        );
    }
    elsif ( $Type eq 'Notice' ) {
        my $Msg = $LayoutObject->Ascii2Html( Text => $Param{Message} // '' );
        my $Raw = $Param{Comment} // '';
        my $Cmt = $LayoutObject->Ascii2Html( Text => $Raw );
        $Output .= q{<div class="RedmineLinkedBlock">};
        $Output .= qq{<div class="RedmineLinkedTitle">$Msg</div>};
        if ( length $Cmt ) {
            my $URLLabel = $LayoutObject->Ascii2Html( Text => $Lang->Translate('Redmine URL') );
            $Output .= qq{<p class="RedmineLinkedMeta"><strong>$URLLabel:</strong> };
            if ( $Raw =~ m{\Ahttps?://}i ) {
                $Output
                    .= qq{<a href="$Cmt" target="_blank" rel="noopener noreferrer">$Cmt</a>};
            }
            else {
                $Output .= $Cmt;
            }
            $Output .= q{</p>};
        }
        $Output .= q{</div>};
    }
    else {
        $Output .= $LayoutObject->Error(
            Message => $Param{Message},
            Comment => $Param{Comment} || '',
        );
    }

    if ( $Param{ShowLinkActions} ) {
        $Output .= $Self->_SiblingTicketsHTML(
            LayoutObject => $LayoutObject,
            Siblings     => $Param{SiblingTickets} || [],
        );
    }

    $Output .= q{<div class="RedmineLinkedBlock"><div class="RedmineLinkedTitle">}
        . $LayoutObject->Ascii2Html( Text => $Lang->Translate('Actions') )
        . q{</div><div class="RedmineLinkedActions">};

    if ( IsStringWithData( $Param{OpenURL} ) ) {
        my $Href  = $LayoutObject->Ascii2Html( Text => $Param{OpenURL} );
        my $Label = $Lang->Translate('Open in Redmine');
        $Output
            .= qq{<a class="CallForAction" href="$Href" target="_blank" rel="noopener noreferrer"><span>$Label</span></a> };
    }

    if ( $Param{ShowSyncButton} && $TID ) {
        my $Label = $Lang->Translate('Sync from Redmine now');
        $Output .= <<"HTML";
<form action="$CGI" method="post" class="RedmineInlineForm">
<input type="hidden" name="Action" value="$Action"/>
<input type="hidden" name="Subaction" value="SyncNow"/>
<input type="hidden" name="TicketID" value="$TID"/>
<input type="hidden" name="ChallengeToken" value="$Token"/>
<button type="submit" class="CallForAction"><span>$Label</span></button>
</form>
HTML
    }

    $Output .= q{</div></div>};

    if ( $Param{ShowLinkActions} && $TID ) {
        $Output .= $Self->_UnlinkRelinkFormsHTML(
            LayoutObject => $LayoutObject,
            Action       => $Action,
            TicketID     => $TID,
            Token        => $Token,
            CGI          => $CGI,
        );
    }

    # Close stays inside the same centered column as the forms above; the OTRS
    # LayoutPopup .Footer bar is omitted because its skin styling is full-width
    # and would detach the button from the column.
    $Output .= q{<div class="RedmineLinkedFooter">}
        . q{<a class="CallForAction CancelClosePopup" href="#"><span>}
        . $LayoutObject->Ascii2Html( Text => $Lang->Translate('Close') )
        . q{</span></a></div>};
    $Output .= q{</div></div></div>};

    $Output .= $LayoutObject->Footer( Type => 'Small' );
    return $Output;
}

sub _SiblingTicketsHTML {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Param{LayoutObject};
    my $Lang         = $LayoutObject->{LanguageObject};
    my $Siblings     = $Param{Siblings} || [];

    my $Title = $LayoutObject->Ascii2Html(
        Text => $Lang->Translate('Other linked OTRS tickets'),
    );
    my $HTML = qq{<div class="RedmineLinkedBlock"><div class="RedmineLinkedTitle">$Title</div>};

    if ( !IsArrayRefWithData($Siblings) ) {
        my $None = $LayoutObject->Ascii2Html(
            Text => $Lang->Translate('No other OTRS tickets are linked to this Redmine issue.'),
        );
        $HTML .= qq{<p class="FieldExplanation">$None</p></div>};
        return $HTML;
    }

    $HTML .= q{<ul class="RedmineSiblingList">};
    for my $Row ( @{$Siblings} ) {
        my $Num  = $LayoutObject->Ascii2Html( Text => $Row->{TicketNumber} // '' );
        my $Tit  = $LayoutObject->Ascii2Html( Text => $Row->{Title} // '' );
        my $ID   = 0 + ( $Row->{TicketID} || 0 );
        my $Zoom = $LayoutObject->Ascii2Html(
            Text => ( $LayoutObject->{Baselink} || 'index.pl?' )
                . "Action=AgentTicketZoom;TicketID=$ID"
        );
        $HTML .= qq{<li><a href="$Zoom" target="_top">$Num</a> — $Tit</li>};
    }
    $HTML .= q{</ul></div>};
    return $HTML;
}

sub _UnlinkRelinkFormsHTML {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Param{LayoutObject};
    my $Lang         = $LayoutObject->{LanguageObject};
    my $Action       = $Param{Action};
    my $TID          = $Param{TicketID};
    my $Token        = $Param{Token};
    my $CGI          = $Param{CGI};

    my $UnlinkL  = $LayoutObject->Ascii2Html( Text => $Lang->Translate('Unlink from Redmine') );
    my $ConfirmU = $LayoutObject->Ascii2Html( Text => $Lang->Translate('I confirm unlinking this ticket from Redmine') );
    my $RelinkL  = $LayoutObject->Ascii2Html( Text => $Lang->Translate('Relink to another Redmine issue') );
    my $ConfirmR = $LayoutObject->Ascii2Html( Text => $Lang->Translate('I confirm relinking to another Redmine issue') );
    my $IssueL   = $LayoutObject->Ascii2Html( Text => $Lang->Translate('Redmine issue ID or URL') );
    my $SubmitU  = $LayoutObject->Ascii2Html( Text => $Lang->Translate('Unlink') );
    my $SubmitR  = $LayoutObject->Ascii2Html( Text => $Lang->Translate('Relink') );

    return <<"HTML";
<div class="RedmineLinkedBlock">
<div class="RedmineLinkedTitle">$UnlinkL</div>
<form action="$CGI" method="post">
<input type="hidden" name="Action" value="$Action"/>
<input type="hidden" name="Subaction" value="Unlink"/>
<input type="hidden" name="TicketID" value="$TID"/>
<input type="hidden" name="ChallengeToken" value="$Token"/>
<label class="RedmineConfirmLabel"><input type="checkbox" name="ConfirmUnlink" value="1"/> $ConfirmU</label>
<div class="SpacingTop"><button type="submit" class="CallForAction"><span>$SubmitU</span></button></div>
</form>
</div>
<div class="RedmineLinkedBlock">
<div class="RedmineLinkedTitle">$RelinkL</div>
<form action="$CGI" method="post">
<input type="hidden" name="Action" value="$Action"/>
<input type="hidden" name="Subaction" value="Relink"/>
<input type="hidden" name="TicketID" value="$TID"/>
<input type="hidden" name="ChallengeToken" value="$Token"/>
<label for="ExistingIssueID">$IssueL</label>
<input type="text" name="ExistingIssueID" id="ExistingIssueID" class="RedmineIssueInput" placeholder="#12345" autocomplete="off"/>
<label class="RedmineConfirmLabel"><input type="checkbox" name="ConfirmRelink" value="1"/> $ConfirmR</label>
<div class="SpacingTop"><button type="submit" class="CallForAction"><span>$SubmitR</span></button></div>
</form>
</div>
HTML
}

1;
