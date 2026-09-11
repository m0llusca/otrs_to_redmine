# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
package Kernel::Output::HTML::TicketMenu::RedmineEscalate;

use parent 'Kernel::Output::HTML::Base';

use strict;
use warnings;
use utf8;

use Kernel::System::VariableCheck qw(:all);
use Kernel::Language qw(Translatable);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Ticket',
);

sub Run {
    my ( $Self, %Param ) = @_;

    return if !$Param{Ticket};
    return if !$Param{Config}->{Action};

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $Module       = $ConfigObject->Get('Frontend::Module')->{ $Param{Config}->{Action} };
    return if !$Module;

    if ( $Param{Config}->{Action} ) {
        my %ACLLookup = reverse( %{ $Param{ACL} || {} } );
        return if !$ACLLookup{ $Param{Config}->{Action} };
    }

    my %Ticket = %{ $Param{Ticket} };
    if ( !exists $Ticket{DynamicField_RedmineID} ) {
        my %Full = $Kernel::OM->Get('Kernel::System::Ticket')->TicketGet(
            TicketID      => $Ticket{TicketID},
            DynamicFields => 1,
            UserID        => $Self->{UserID},
            Silent        => 1,
        );
        $Ticket{DynamicField_RedmineID}  = $Full{DynamicField_RedmineID};
        $Ticket{DynamicField_RedmineURL} = $Full{DynamicField_RedmineURL};
    }

    my $ID = $Ticket{DynamicField_RedmineID} // '';
    my $Name;
    my $Description;

    if ( IsStringWithData($ID) ) {
        # Distinct from TicketMenu::RedmineOpen («Redmine #ID» → open in browser).
        $Name        = Translatable('Redmine sync');
        $Description = Translatable('Already linked — details and sync from Redmine');
    }
    else {
        $Name        = $Param{Config}->{Name} || Translatable('Create Redmine issue');
        $Description = $Param{Config}->{Description}
            || Translatable('Create a linked Redmine issue for this ticket');
    }

    return {
        %{ $Param{Config} },
        %Ticket,
        Name        => $Name,
        Description => $Description,
        Link        => "Action=AgentTicketRedmineEscalate;TicketID=$Ticket{TicketID}",
        PopupType   => $Param{Config}->{PopupType} || 'TicketAction',
        Target      => '',
    };
}

1;
