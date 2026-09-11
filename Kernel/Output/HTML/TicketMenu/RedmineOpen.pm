# --
# Copyright (C) 2026 OTRSRedmineBridge
# --
package Kernel::Output::HTML::TicketMenu::RedmineOpen;

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

    my %Ticket = %{ $Param{Ticket} };
    if (
        !IsStringWithData( $Ticket{DynamicField_RedmineURL} )
        && !IsStringWithData( $Ticket{DynamicField_RedmineID} )
        )
    {
        my %Full = $Kernel::OM->Get('Kernel::System::Ticket')->TicketGet(
            TicketID      => $Ticket{TicketID},
            DynamicFields => 1,
            UserID        => $Self->{UserID},
            Silent        => 1,
        );
        return if !IsStringWithData( $Full{DynamicField_RedmineID} )
            && !IsStringWithData( $Full{DynamicField_RedmineURL} );
        $Ticket{DynamicField_RedmineURL} = $Full{DynamicField_RedmineURL};
        $Ticket{DynamicField_RedmineID}  = $Full{DynamicField_RedmineID};
    }

    if ( $Param{Config}->{Action} ) {
        my %ACLLookup = reverse( %{ $Param{ACL} || {} } );
        return if !$ACLLookup{ $Param{Config}->{Action} };
    }

    my $BaseURL = $ConfigObject->Get('Redmine::BaseURL') // '';
    $BaseURL =~ s{/\z}{};
    my $ID  = $Ticket{DynamicField_RedmineID} || '';
    my $URL = $Ticket{DynamicField_RedmineURL} || '';

    # S11: only https?:// URLs under Redmine::BaseURL host; else rebuild from ID.
    my $SafeURL = $Self->_SafeRedmineURL(
        URL     => $URL,
        BaseURL => $BaseURL,
        IssueID => $ID,
    );
    return if !$SafeURL;

    return {
        %{ $Param{Config} },
        %Ticket,
        Name         => $ID ? "Redmine #$ID" : Translatable('Open in Redmine'),
        Description  => Translatable('Open linked Redmine issue in a new tab'),
        Link         => $SafeURL,
        ExternalLink => 1,
        LinkParam    => 'target="_blank" rel="noopener noreferrer"',
        PopupType    => '',
        Target       => '_blank',
    };
}

sub _SafeRedmineURL {
    my ( $Self, %Param ) = @_;

    my $BaseURL = $Param{BaseURL} || '';
    my $URL     = $Param{URL}     || '';
    my $IssueID = $Param{IssueID} || '';

    my $BaseHost = '';
    if ( $BaseURL =~ m{\Ahttps?://([^/:]+)}i ) {
        $BaseHost = lc $1;
    }

    if ( $URL =~ m{\A(https?)://([^/:]+)(/.*)?\z}i ) {
        my ( $Scheme, $Host, $Path ) = ( lc $1, lc $2, $3 // '' );
        if ( $BaseHost && $Host eq $BaseHost ) {
            return "$Scheme://$Host$Path";
        }
        if ($BaseURL) {
            # Same host via prefix match (BaseURL may include path prefix).
            my $Prefix = lc $BaseURL;
            if ( index( lc($URL), $Prefix ) == 0 ) {
                return $URL;
            }
        }
    }

    return if !IsNumber($IssueID) || !$BaseURL;
    return "$BaseURL/issues/$IssueID";
}

1;
