# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Redmine::TicketDF;

use strict;
use warnings;
use utf8;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::Log',
    'Kernel::System::SysConfig',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
);

sub _SetDF {
    my ( $Self, %Param ) = @_;

    return if !$Param{Name} || !$Param{TicketID};

    my $DynamicFieldObject        = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');
    my $Config                    = $DynamicFieldObject->DynamicFieldGet( Name => $Param{Name} );
    return if !$Config || !IsHashRefWithData($Config);

    return $DynamicFieldBackendObject->ValueSet(
        DynamicFieldConfig => $Config,
        ObjectID           => $Param{TicketID},
        Value              => $Param{Value},
        UserID             => $Param{UserID} || 1,
    );
}

sub _GetDF {
    my ( $Self, %Param ) = @_;

    return if !$Param{Name} || !$Param{TicketID};

    my $DynamicFieldObject        = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');
    my $Config                    = $DynamicFieldObject->DynamicFieldGet( Name => $Param{Name} );
    return if !$Config || !IsHashRefWithData($Config);

    return $DynamicFieldBackendObject->ValueGet(
        DynamicFieldConfig => $Config,
        ObjectID           => $Param{TicketID},
    );
}

# Merge Redmine* keys into TicketZoom sidebar (keep Theme and other existing keys).
sub EnsureZoomDynamicFields {
    my ( $Self, %Param ) = @_;

    my $SysConfigObject = $Kernel::OM->Get('Kernel::System::SysConfig');
    my $Name            = 'Ticket::Frontend::AgentTicketZoom###DynamicField';

    my %Setting = eval { $SysConfigObject->SettingGet( Name => $Name ) };
    if ( !%Setting ) {
        return ( Success => 0, Error => "SysConfig setting $Name not found" );
    }

    my $Effective = $Setting{EffectiveValue};
    if ( ref $Effective ne 'HASH' ) {
        $Effective = {};
    }
    else {
        $Effective = { %{$Effective} };
    }

    my %Want = (
        RedmineID               => '1',
        RedmineURL              => '1',
        RedmineEscalationStatus => '1',
        RedmineLastError        => '1',
        RedmineStatus           => '1',
        RedmineProjectID        => '1',
        RedmineTrackerID        => '1',
    );

    my $Changed = 0;
    for my $Key ( sort keys %Want ) {
        if ( !defined $Effective->{$Key} || "$Effective->{$Key}" ne $Want{$Key} ) {
            $Effective->{$Key} = $Want{$Key};
            $Changed = 1;
        }
    }
    if ( !$Changed ) {
        return ( Success => 1, Changed => 0, Message => 'TicketZoom already shows Redmine fields' );
    }

    my $ExclusiveLockGUID = $SysConfigObject->SettingLock(
        Name   => $Name,
        Force  => 1,
        UserID => 1,
    );
    if ( !$ExclusiveLockGUID ) {
        return ( Success => 0, Error => "Could not lock SysConfig $Name" );
    }

    my %Update = $SysConfigObject->SettingUpdate(
        Name              => $Name,
        IsValid           => 1,
        EffectiveValue    => $Effective,
        ExclusiveLockGUID => $ExclusiveLockGUID,
        UserID            => 1,
    );
    $SysConfigObject->SettingUnlock( Name => $Name );
    if ( !$Update{Success} ) {
        return ( Success => 0, Error => $Update{Error} || 'SettingUpdate failed' );
    }

    # Deploy only this dirty setting (avoid AllSettings blast radius).
    my %Deploy = $SysConfigObject->ConfigurationDeploy(
        Comments      => 'OTRSRedmineBridge: enable Redmine DFs on TicketZoom',
        DirtySettings => [$Name],
        Force         => 1,
        UserID        => 1,
    );
    if ( !$Deploy{Success} ) {
        # Fallback for older SysConfig APIs that require AllSettings.
        %Deploy = $SysConfigObject->ConfigurationDeploy(
            Comments    => 'OTRSRedmineBridge: enable Redmine DFs on TicketZoom',
            AllSettings => 1,
            Force       => 1,
            UserID      => 1,
        );
    }
    if ( !$Deploy{Success} ) {
        return ( Success => 0, Error => 'Setting saved but ConfigurationDeploy failed' );
    }

    return (
        Success => 1,
        Changed => 1,
        Message => 'Redmine fields enabled on TicketZoom (Theme and other keys kept)',
    );
}

# Other OTRS tickets linked to the same Redmine issue (N→1).
sub TicketsByRedmineIssueID {
    my ( $Self, %Param ) = @_;

    my $IssueID = $Param{IssueID} // '';
    return () if !IsNumber($IssueID) && $IssueID !~ m{\A\d+\z};

    my $Exclude = 0 + ( $Param{ExcludeTicketID} || 0 );
    my $Limit   = 0 + ( $Param{Limit} || 20 );
    $Limit = 20 if $Limit < 1 || $Limit > 50;

    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my @TicketIDs    = $TicketObject->TicketSearch(
        Result                 => 'ARRAY',
        UserID                 => $Param{UserID} || 1,
        Limit                  => $Limit + 5,
        DynamicField_RedmineID => {
            Equals => "$IssueID",
        },
    );

    my @Out;
    for my $TicketID (@TicketIDs) {
        next if $Exclude && ( 0 + $TicketID ) == $Exclude;
        my %Ticket = $TicketObject->TicketGet(
            TicketID => $TicketID,
            UserID   => $Param{UserID} || 1,
            Silent   => 1,
        );
        next if !%Ticket;
        push @Out, {
            TicketID     => $TicketID,
            TicketNumber => $Ticket{TicketNumber} // '',
            Title        => $Ticket{Title}        // '',
        };
        last if @Out >= $Limit;
    }
    return @Out;
}

sub _AddInternalArticle {
    my ( $Self, %Param ) = @_;

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $Backend       = $ArticleObject->BackendForChannel( ChannelName => 'Internal' );
    if ( !$Backend ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'Redmine bridge: Internal article channel is not available',
        );
        return;
    }

    my $Filename = $Param{Filename};
    if ( defined $Filename && length $Filename ) {
        $Filename =~ s{[/\\]}{_}g;
        $Filename =~ s{\A\.}{_}g;
        $Filename = substr( $Filename, 0, 200 ) if length $Filename > 200;
    }

    return $Backend->ArticleCreate(
        TicketID             => $Param{TicketID},
        SenderType           => 'agent',
        IsVisibleForCustomer => 0,
        Subject              => $Param{Subject},
        Body                 => $Param{Body},
        ContentType          => 'text/plain; charset=utf-8',
        Charset              => 'utf-8',
        MimeType             => 'text/plain',
        HistoryType          => 'AddNote',
        HistoryComment       => $Param{HistoryComment} || '%%RedmineBridge',
        UserID               => $Param{UserID} || 1,
        (
            $Param{Attachment}
            ? (
                Attachment => [
                    {
                        Content     => $Param{Attachment}->{Content},
                        ContentType => $Param{Attachment}->{ContentType}
                            || 'application/octet-stream',
                        Filename => $Filename || $Param{Attachment}->{Filename} || 'file.bin',
                    }
                ]
                )
            : ()
        ),
    );
}

1;
