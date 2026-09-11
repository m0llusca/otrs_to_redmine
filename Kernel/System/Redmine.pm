# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::System::Redmine;

use strict;
use warnings;
use utf8;

use Kernel::System::Redmine::HTTP;
use Kernel::System::Redmine::Diagnostics;
use Kernel::System::Redmine::Catalog;
use Kernel::System::Redmine::Issue;
use Kernel::System::Redmine::Sync;
use Kernel::System::Redmine::TicketDF;

use parent qw(
    Kernel::System::Redmine::HTTP
    Kernel::System::Redmine::Diagnostics
    Kernel::System::Redmine::Catalog
    Kernel::System::Redmine::Issue
    Kernel::System::Redmine::Sync
    Kernel::System::Redmine::TicketDF
);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Cache',
    'Kernel::System::DynamicField',
    'Kernel::System::DynamicField::Backend',
    'Kernel::System::Encode',
    'Kernel::System::HTMLUtils',
    'Kernel::System::JSON',
    'Kernel::System::Log',
    'Kernel::System::SysConfig',
    'Kernel::System::Ticket',
    'Kernel::System::Ticket::Article',
    'Kernel::System::User',
    'Kernel::System::Web::UploadCache',
);

sub new {
    my ( $Type, %Param ) = @_;
    my $Self = {};
    bless( $Self, $Type );
    return $Self;
}

# Admin health widget helper (reads CronSync cache).
sub SyncHealthStatus {
    my ( $Self, %Param ) = @_;

    my $CacheObject = $Kernel::OM->Get('Kernel::System::Cache');
    my $LastSyncAt  = $CacheObject->Get( Type => 'RedmineBridgeHealth', Key => 'LastSyncAt' );
    my $LastError   = $CacheObject->Get( Type => 'RedmineBridgeHealth', Key => 'LastSyncError' );
    my $SyncedCount = $CacheObject->Get( Type => 'RedmineBridgeHealth', Key => 'SyncedCount' );
    my $LastOK      = $CacheObject->Get( Type => 'RedmineBridgeHealth', Key => 'LastSyncOK' );

    my $Age;
    if ( defined $LastSyncAt && $LastSyncAt =~ m{\A\d+\z} ) {
        $Age = time() - $LastSyncAt;
    }

    my $Stale = 0;
    if ( !defined $Age || $Age > 15 * 60 ) {
        $Stale = 1;
    }

    return (
        LastSyncAt  => $LastSyncAt,
        LastSyncError => $LastError,
        SyncedCount => $SyncedCount,
        LastSyncOK  => $LastOK,
        AgeSeconds  => $Age,
        Stale       => $Stale,
    );
}

1;
