package FusionInventory::Agent::Task::Inventory::Linux::PowerPC::Bios;

use strict;
use warnings;

use FusionInventory::Agent::Tools;

sub isEnabled {
    return 1;
}

sub doInventory {
    my (%params) = @_;

    my $inventory = $params{inventory};
    my $logger    = $params{logger};

    my $bios;

    $bios->{SSN} = getFirstLine(file => '/proc/device-tree/serial-number');
    $bios->{SSN} =~ s/[^\,^\.^\w^\ ]//g; # I remove some unprintable char

    $bios->{SMODEL} = getFirstLine(file => '/proc/device-tree/model');
    $bios->{SMODEL} =~ s/[^\,^\.^\w^\ ]//g;

    my $colorCode = getFirstLine(file => '/proc/device-tree/color-code');
    my ($color) = unpack "h7" , $colorCode;
    $bios->{SMODEL} .= " color: $color" if $color;

    $bios->{BVERSION} =
        getFirstLine(file => '/proc/device-tree/openprom/model');
    $bios->{BVERSION} =~ s/[^\,^\.^\w^\ ]//g;

    my $copyright = getFirstLine(file => '/proc/device-tree/copyright');
    if ($copyright && $copyright =~ /Apple/) {
        # What about the Apple clone?
        $bios->{BMANUFACTURER} = "Apple Computer, Inc.";
        $bios->{SMANUFACTURER} = "Apple Computer, Inc."
    }

    $inventory->setBios($bios);
}

1;