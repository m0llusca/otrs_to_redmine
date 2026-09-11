# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
package var::packagesetup::OTRSRedmineBridge;

use strict;
use warnings;
use utf8;

our @ObjectDependencies = (
    'Kernel::System::DynamicField',
    'Kernel::System::Log',
    'Kernel::System::Redmine',
    'Kernel::System::SysConfig',
    'Kernel::System::Valid',
);

sub new {
    my ( $Type, %Param ) = @_;
    my $Self = {};
    bless( $Self, $Type );
    return $Self;
}

sub CodeInstall {
    my ( $Self, %Param ) = @_;
    $Self->_EnsureDynamicFields();
    $Self->_EnsureZoomDynamicFields();
    return 1;
}

sub CodeReinstall {
    my ( $Self, %Param ) = @_;
    return $Self->CodeInstall(%Param);
}

sub CodeUpgrade {
    my ( $Self, %Param ) = @_;
    $Self->_RemoveObsoleteSettings();
    return $Self->CodeInstall(%Param);
}

# Drop leftover ArticleCreate → Redmine hook so upgrade does not keep firing a deleted module.
sub _RemoveObsoleteSettings {
    my ( $Self, %Param ) = @_;

    my $SysConfigObject = $Kernel::OM->Get('Kernel::System::SysConfig');
    my $LogObject       = $Kernel::OM->Get('Kernel::System::Log');
    my @Dirty;

    SETTING:
    for my $Name (
        'Ticket::EventModulePost###5510-RedmineOutbound',
        'Redmine::SyncComments',
    )
    {
        my $Lock = $SysConfigObject->SettingLock(
            Name   => $Name,
            Force  => 1,
            UserID => 1,
        );
        next SETTING if !$Lock;

        my %Update = $SysConfigObject->SettingUpdate(
            Name              => $Name,
            IsValid           => 0,
            ExclusiveLockGUID => $Lock,
            UserID            => 1,
        );
        $SysConfigObject->SettingUnlock( Name => $Name );
        if ( $Update{Success} ) {
            push @Dirty, $Name;
        }
        else {
            $LogObject->Log(
                Priority => 'notice',
                Message  => "OTRSRedmineBridge: obsolete $Name already gone",
            );
        }
    }

    return 1 if !@Dirty;

    $SysConfigObject->ConfigurationDeploy(
        Comments      => 'OTRSRedmineBridge: disable obsolete outbound article sync',
        DirtySettings => \@Dirty,
        Force         => 1,
        UserID        => 1,
    );
    return 1;
}

sub CodeUninstall {
    my ( $Self, %Param ) = @_;
    $Kernel::OM->Get('Kernel::System::Log')->Log(
        Priority => 'notice',
        Message  => 'OTRSRedmineBridge uninstalled; Dynamic Fields kept.',
    );
    return 1;
}

sub _EnsureDynamicFields {
    my ( $Self, %Param ) = @_;

    my $DynamicFieldObject = $Kernel::OM->Get('Kernel::System::DynamicField');
    my $ValidID = $Kernel::OM->Get('Kernel::System::Valid')->ValidLookup( Valid => 'valid' );

    # EscalationStatus machine codes: none|pending|created|linked|error|error_exhausted
    my @Fields = (
        {
            Name       => 'RedmineID',
            Label      => 'ID в Redmine',
            FieldOrder => 9100,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
        {
            Name       => 'RedmineURL',
            Label      => 'Ссылка на задачу',
            FieldOrder => 9101,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
        {
            Name       => 'RedmineEscalationStatus',
            Label      => 'Статус эскалации',
            FieldOrder => 9102,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => 'none' },
        },
        {
            Name       => 'RedmineLastError',
            Label      => 'Ошибка эскалации Redmine',
            FieldOrder => 9103,
            FieldType  => 'TextArea',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '', Rows => 5, Cols => 60 },
        },
        {
            Name       => 'RedmineStatus',
            Label      => 'Статус Redmine',
            FieldOrder => 9104,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
        {
            Name       => 'RedmineProjectID',
            Label      => 'Redmine Project ID',
            FieldOrder => 9105,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
        {
            Name       => 'RedmineTrackerID',
            Label      => 'Redmine Tracker ID',
            FieldOrder => 9106,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
        {
            Name       => 'RedmineLastJournalID',
            Label      => 'Redmine Last Journal ID',
            FieldOrder => 9107,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
        {
            Name       => 'RedmineLastAttachmentID',
            Label      => 'Redmine Last Attachment ID',
            FieldOrder => 9108,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
        {
            Name       => 'RedmineRetryPayload',
            Label      => 'Redmine Retry Payload',
            FieldOrder => 9109,
            FieldType  => 'TextArea',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '', Rows => 3, Cols => 60 },
        },
        {
            Name       => 'RedmineRetryCount',
            Label      => 'Redmine Retry Count',
            FieldOrder => 9110,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '0' },
        },
        {
            Name       => 'RedmineLastUpdatedOn',
            Label      => 'Redmine Last Updated On',
            FieldOrder => 9111,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
        {
            Name       => 'RedmineLastSyncAt',
            Label      => 'Redmine Last Sync At',
            FieldOrder => 9112,
            FieldType  => 'Text',
            ObjectType => 'Ticket',
            Config     => { DefaultValue => '' },
        },
    );

    for my $Field (@Fields) {
        my $Existing = $DynamicFieldObject->DynamicFieldGet( Name => $Field->{Name} );
        next if $Existing && $Existing->{ID};
        my $ID = $DynamicFieldObject->DynamicFieldAdd(
            %{$Field},
            ValidID => $ValidID,
            UserID  => 1,
        );
        if ( !$ID ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Could not create Dynamic Field $Field->{Name}",
            );
        }
    }
    return 1;
}

sub _EnsureZoomDynamicFields {
    my ( $Self, %Param ) = @_;

    my %Res = eval {
        $Kernel::OM->Get('Kernel::System::Redmine')->EnsureZoomDynamicFields();
    };
    if ($@) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'OTRSRedmineBridge EnsureZoomDynamicFields died: ' . $@,
        );
        return 1;
    }
    if ( !$Res{Success} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => 'OTRSRedmineBridge EnsureZoomDynamicFields: ' . ( $Res{Error} || 'failed' ),
        );
    }
    else {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'notice',
            Message  => 'OTRSRedmineBridge EnsureZoomDynamicFields: '
                . ( $Res{Message} || ( $Res{Changed} ? 'updated' : 'ok' ) ),
        );
    }
    return 1;
}

1;
