# Copyright (C) 2026 OTRSRedmineBridge. GPL version 3 or later.
package Kernel::System::Daemon::DaemonModules::RedmineBridgePoller;
use strict;
use warnings;
use utf8;
use Time::HiRes qw(sleep);
use parent qw(Kernel::System::Daemon::BaseDaemon);
our @ObjectDependencies = (
    'Kernel::Config', 'Kernel::System::Cache', 'Kernel::System::Log',
    'Kernel::System::Redmine',
);

sub new {
    my ($Type, %Param) = @_;
    my $Self = bless {NextPoll => 0, DiscardCount => 60, DiscardAt => time() + 60, Debug => $Param{Debug},
        DaemonName => 'Daemon: RedmineBridgePoller'}, $Type;
    $Kernel::OM->Get('Kernel::System::Cache')->Configure(
        CacheInMemory => 0, CacheInBackend => 1);
    return $Self;
}

sub Run {
    my ($Self) = @_;
    my $Now = time();
    my $Config = $Kernel::OM->Get('Kernel::Config');
    return 1 if !$Config->Get('Redmine::Enabled') || !$Config->Get('Redmine::InboundSync');
    my $Bridge = eval {$Kernel::OM->Get('Kernel::System::Redmine')};
    if (!$Bridge) {
        $Self->_LogError('Ошибка инициализации синхронизации Redmine.');
        return 1;
    }
    if ($Now >= $Self->{NextPoll}) {
        my $Interval = eval {$Kernel::OM->Get('Kernel::Config')->Get('Redmine::SyncPollInterval')};
        $Interval = 5 if !defined $Interval || $Interval !~ /\A\d+\z/;
        $Interval = 1 if $Interval < 1;
        $Interval = 60 if $Interval > 60;
        my $OK = eval {$Bridge->PollSync()};
        $Self->{NextPoll} = time() + $Interval;
        $Self->_LogError('Ошибка обнаружения изменений Redmine.') if !$OK;
    }
    my $OK = eval {$Bridge->DispatchSync()};
    $Self->_LogError('Ошибка постановки синхронизации Redmine в очередь.') if !$OK;
    return 1;
}

sub _LogError {
    my ($Self, $Message) = @_;
    # Never put exception text (which may contain credentials) in daemon logs.
    eval {$Kernel::OM->Get('Kernel::System::Log')->Log(Priority => 'error', Message => $Message)};
    return 1;
}

sub PostRun {
    my ($Self) = @_;
    sleep 1;
    # Core recreates the daemon and its ObjectManager after this bounded
    # lifetime, so Admin/SysConfig changes become visible without a restart.
    $Self->{DiscardCount}--;
    return $Self->{DiscardCount} > 0 && time() < $Self->{DiscardAt} ? 1 : undef;
}
1;
