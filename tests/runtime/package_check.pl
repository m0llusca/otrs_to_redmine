use strict;
use warnings;
use utf8;
use lib '/opt/otrs', '/opt/otrs/Kernel/cpan-lib';
use Kernel::System::ObjectManager;
use JSON::PP;

local $Kernel::OM = Kernel::System::ObjectManager->new();
my $JSON = JSON::PP->new->canonical;
my $Fields = $Kernel::OM->Get('Kernel::System::DynamicField');
my $Bridge = $Kernel::OM->Get('Kernel::System::Redmine');
my $SysConfig = $Kernel::OM->Get('Kernel::System::SysConfig');
my $Cache = $Kernel::OM->Get('Kernel::System::Cache');
my $FixtureFile = '/opt/otrs/var/tmp/bridge-benchmark.json';
open my $input, '<', $FixtureFile or die $!;
my $Fixture = do { local $/; $JSON->decode(<$input>) };
close $input;
my $StateFile = '/opt/otrs/var/tmp/bridge-package-upgrade.json';

sub update_setting {
    my ( $Name, $Value ) = @_;
    my $Lock = $SysConfig->SettingLock( Name => $Name, Force => 1, UserID => 1 ) or die 'Setting lock failed';
    my %Update = $SysConfig->SettingUpdate( Name => $Name, IsValid => 1,
        EffectiveValue => $Value, ExclusiveLockGUID => $Lock, UserID => 1 );
    $SysConfig->SettingUnlock( Name => $Name );
    die 'Setting update failed' if !$Update{Success};
    my %Deploy = $SysConfig->ConfigurationDeploy( Comments => 'Local package verification',
        DirtySettings => [$Name], Force => 1, UserID => 1 );
    die 'Setting deploy failed' if !$Deploy{Success};
}

if ( $ARGV[0] eq 'before' ) {
    my $ValidID = $Kernel::OM->Get('Kernel::System::Valid')->ValidLookup( Valid => 'valid' );
    my $CustomID = $Fields->DynamicFieldAdd( Name => 'PackageReviewKeep', Label => 'Local package verification',
        FieldOrder => 9800, FieldType => 'Text', ObjectType => 'Ticket',
        Config => { DefaultValue => '' }, ValidID => $ValidID, UserID => 1 );
    die 'Custom dynamic field failed' if !$CustomID;
    my %Zoom = $SysConfig->SettingGet( Name => 'Ticket::Frontend::AgentTicketZoom###DynamicField' );
    my %Value = %{ $Zoom{EffectiveValue} || {} };
    $Value{PackageReviewKeep} = '1';
    update_setting( 'Ticket::Frontend::AgentTicketZoom###DynamicField', \%Value );
    update_setting( 'Redmine::SyncBatchLimit', 37 );
    my $TicketID = $Fixture->{poll}->[0];
    $Bridge->_SetDF( TicketID => $TicketID, Name => 'RedmineID', Value => '7001', UserID => 1 )
        or die 'Cannot seed link';
    my %IDs;
    for my $Name ( keys %{ $Fixture->{field_ids} } ) {
        my $Field = $Fields->DynamicFieldGet( Name => $Name );
        $IDs{$Name} = $Field->{ID} if $Field && $Field->{ID};
    }
    open my $output, '>', $StateFile or die $!;
    print {$output} $JSON->encode({ field_ids => \%IDs, custom_id => $CustomID, ticket_id => $TicketID });
    close $output;
    $Cache->CleanUp();
    print "{\"upgrade_fixture_prepared\":true}\n";
    exit;
}
if ( $ARGV[0] eq 'fresh' ) {
    my %IDs;
    for my $Name ( keys %{ $Fixture->{field_ids} } ) {
        my $Field = $Fields->DynamicFieldGet( Name => $Name );
        die "Fresh install field missing: $Name" if !$Field || !$Field->{ID};
        $IDs{$Name} = $Field->{ID};
    }
    die 'Unexpected number of bridge fields' if scalar(keys %IDs) != 14;
    print $JSON->encode({ field_ids => \%IDs, bridge_field_count => scalar(keys %IDs) }), "\n";
    exit;
}
die 'Invalid package check action' if $ARGV[0] ne 'after';
open my $state, '<', $StateFile or die $!;
my $Before = do { local $/; $JSON->decode(<$state>) };
close $state;
for my $Name ( keys %{ $Before->{field_ids} } ) {
    die "Field ID changed: $Name" if $Fields->DynamicFieldGet( Name => $Name )->{ID} != $Before->{field_ids}->{$Name};
}
my $NewField = $Fields->DynamicFieldGet( Name => 'RedmineLastAttachmentSyncOn' );
die 'New cursor field missing' if !$NewField || !$NewField->{ID};
$Fixture->{field_ids}->{RedmineLastAttachmentSyncOn} = $NewField->{ID};
open my $fixture_output, '>', $FixtureFile or die $!;
print {$fixture_output} $JSON->encode($Fixture);
close $fixture_output;
die 'Ticket link lost on upgrade'
    if $Bridge->_GetDF( TicketID => $Before->{ticket_id}, Name => 'RedmineID' ) ne '7001';
my %Zoom = $SysConfig->SettingGet( Name => 'Ticket::Frontend::AgentTicketZoom###DynamicField' );
die 'Custom Zoom field lost' if !$Zoom{EffectiveValue}->{PackageReviewKeep};
for my $Name (qw(RedmineID RedmineURL RedmineEscalationStatus RedmineLastError RedmineStatus RedmineProjectID RedmineTrackerID)) {
    die "Zoom field missing: $Name" if !$Zoom{EffectiveValue}->{$Name};
}
my $Config = $Kernel::OM->Get('Kernel::Config');
die 'Custom sync limit lost' if $Config->Get('Redmine::SyncBatchLimit') != 37;
die 'Aggregate byte setting missing' if $Config->Get('Redmine::MaxAttachmentTotalBytes') != 20_000_000;
die 'Aggregate count setting missing' if $Config->Get('Redmine::MaxAttachmentCount') != 20;
die 'Wrong loaded module' if $INC{'Kernel/System/Redmine/Sync.pm'} !~ m{\A/opt/otrs/};
print $JSON->encode({ existing_field_ids_preserved => 1, link_preserved => 1,
    custom_zoom_field_preserved => 1, bridge_zoom_fields_present => 1, custom_sync_limit_preserved => 1,
    new_cursor_field_created => 1, aggregate_settings_present => 1,
    bridge_field_count => scalar(keys %{ $Fixture->{field_ids} }), loaded_sync => $INC{'Kernel/System/Redmine/Sync.pm'} }), "\n";
