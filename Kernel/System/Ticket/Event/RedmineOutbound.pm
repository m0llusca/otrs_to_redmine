# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
package Kernel::System::Ticket::Event::RedmineOutbound;

use strict;
use warnings;
use utf8;

use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Log',
    'Kernel::System::Redmine',
);

sub new {
    my ( $Type, %Param ) = @_;
    my $Self = {};
    bless( $Self, $Type );
    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    return if !$Param{Data}->{TicketID};
    return if !$Param{Data}->{ArticleID};
    return 1 if !$Kernel::OM->Get('Kernel::Config')->Get('Redmine::Enabled');
    return 1 if !$Kernel::OM->Get('Kernel::Config')->Get('Redmine::SyncComments');

    # Do not block ticket flow on Redmine errors
    eval {
        $Kernel::OM->Get('Kernel::System::Redmine')->SyncArticleToRedmine(
            TicketID  => $Param{Data}->{TicketID},
            ArticleID => $Param{Data}->{ArticleID},
            UserID    => $Param{UserID} || 1,
        );
    };
    if ($@) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "RedmineOutbound failed: $@",
        );
    }
    return 1;
}

1;
