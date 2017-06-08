package FusionInventory::Agent::Task::Inventory::Generic::Networks::iLO;

use strict;
use warnings;
use Socket;

use English qw(-no_match_vars);

use FusionInventory::Agent::Tools;
use FusionInventory::Agent::Tools::Network;

sub isEnabled {
    return $OSNAME eq 'MSWin32' ?
        canRun("C:\\Program\ Files\\HP\\hponcfg\\hponcfg.exe") :
        canRun('hponcfg');
}

sub _parseHponcfg {
    my (%params) = @_;

    my $handle = getFileHandle(%params);
    my $name = '';
    my $domainname = '';

    return unless $handle;

    my $interface = {
        DESCRIPTION => 'Management Interface - HP iLO',
        TYPE        => 'ethernet',
        MANAGEMENT  => 'iLO',
        STATUS      => 'Down',
    };

    while (my $line = <$handle>) {
        if ($line =~ /<IP_ADDRESS VALUE="($ip_address_pattern)" ?\/>/) {
            $interface->{IPADDRESS} = $1 unless $1 eq '0.0.0.0';
        }
        if ($line =~ /<SUBNET_MASK VALUE="($ip_address_pattern)" ?\/>/) {
            $interface->{IPMASK} = $1;
        }
        if ($line =~ /<GATEWAY_IP_ADDRESS VALUE="($ip_address_pattern)"\/>/) {
            $interface->{IPGATEWAY} = $1;
        }
        if ($line =~ /<DNS_NAME VALUE="(\S+)"\/>/) {
            $name = $1;
        }
        if ($line =~ /<DOMAIN_NAME VALUE="(\S+)"\/>/) {
            $domainname = $1;
        }
        if ($line =~ /<NIC_SPEED VALUE="([0-9]+)" ?\/>/) {
            $interface->{SPEED} = $1;
        }
        if ($line =~ /<ENABLE_NIC VALUE="Y" ?\/>/) {
            $interface->{STATUS} = 'Up';
        }
        if ($line =~ /not found/) {
            chomp $line;
            $params{logger}->error("error in hponcfg output: $line")
                if $params{logger};
        }
    }
    close $handle;

    if ((!$name eq '') && ($interface->{IPADDRESS} eq '')) {
       if (!$domainname eq '') {
           $name = $name . '.' . $domainname ;
       }
       if (defined inet_aton($name)) { 
           $interface->{IPADDRESS} = inet_ntoa(inet_aton($name));
       }
    }

    $interface->{IPSUBNET} = getSubnetAddress(
        $interface->{IPADDRESS}, $interface->{IPMASK}
    );

    return $interface;
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};
    my $logger    = $params{logger};

    my $command = $OSNAME eq 'MSWin32' ?
        '"c:\Program Files\HP\hponcfg\hponcfg" /a /w output.txt && type output.txt' :
        'hponcfg -aw -';


    my $entry = _parseHponcfg(
        logger => $logger,
        command => $command
    );

    $inventory->addEntry(
        section => 'NETWORKS',
        entry   => $entry
    );
}

1;
