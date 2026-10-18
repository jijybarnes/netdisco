#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;

# hide_deviceports moved out of the classic Ports tab into
# App::Netdisco::Util::Port so that the v2 API hides exactly the same ports.
# Nothing covered the rule before the move; this pins what it did there, on
# stand-in rows carrying the accessors the ACL matcher reads.

BEGIN { $ENV{DANCER_ENVIRONMENT} = 'testing' }

use App::Netdisco;
use Dancer qw/:syntax :script/;
use App::Netdisco::Web::Data::Ports 'hidden_device_ports';

{
  package XtRow;
  sub new { my ($class, %f) = @_; bless {%f}, $class }
  our $AUTOLOAD;
  sub can { my ($self, $m) = @_; return (ref $self and exists $self->{$m}) ? sub { $_[0]->{$m} } : undef }
  sub AUTOLOAD { my $self = shift; (my $m = $AUTOLOAD) =~ s/.*:://; return if $m eq 'DESTROY'; $self->{$m} }
}
{
  package XtList;
  sub new { my ($class, @rows) = @_; bless [@rows], $class }
  sub all { @{ $_[0] } }
}

my @ips = (
  XtRow->new(ip => '10.0.0.1', alias => '10.0.0.1', port => 'Mgmt0'),
  XtRow->new(ip => '10.0.0.1', alias => '192.168.5.1', port => 'Vlan5'),
);
my $device = XtRow->new(ip => '10.0.0.1', name => 'sw1');
{ no warnings 'once'; *XtRow::device_ips = sub { XtList->new(@ips) }; }

my @ports = map { XtRow->new(ip => '10.0.0.1', %$_) } (
  { port => 'Ethernet1', up => 'up',         type => 'ethernetCsmacd' },
  { port => 'Ethernet2', up => 'notPresent', type => 'ethernetCsmacd' },
  { port => 'Vlan5',     up => 'up',         type => 'propVirtual' },
  { port => 'Mgmt0',     up => 'up',         type => 'ethernetCsmacd' },
);

is_deeply hidden_device_ports($device, \@ports), { Ethernet2 => 1 },
  'hiddenDevicePorts__shipped_rule__hides_ports_not_present';

# A port is matched as the list of its rows, port row first, so a bare IP is
# compared with the port row's address (the device's), and the interface
# address on a device_ip row is reachable as a named property.
setting('hide_deviceports' => [ { '10.0.0.0/8' => 'alias:192\.168\.5\.1' } ]);
is_deeply hidden_device_ports($device, \@ports), { Vlan5 => 1 },
  'hiddenDevicePorts__interface_address_as_a_property__hides_the_port_it_is_on';

setting('hide_deviceports' => [ { '10.0.0.0/8' => '192.168.5.1' } ]);
is_deeply hidden_device_ports($device, \@ports), {},
  'hiddenDevicePorts__interface_address_as_a_bare_ip__is_compared_with_the_port_row';

setting('hide_deviceports' => [ { '172.16.0.0/12' => 'port:Ethernet.*' } ]);
is_deeply hidden_device_ports($device, \@ports), {},
  'hiddenDevicePorts__rule_for_another_device__hides_nothing';

setting('hide_deviceports' => [ { '10.0.0.0/8' => 'port:Ethernet.*' }, 'not a map' ]);
is_deeply hidden_device_ports($device, \@ports), { Ethernet1 => 1, Ethernet2 => 1 },
  'hiddenDevicePorts__port_name_pattern__hides_each_match_and_skips_bad_entries';

setting('hide_deviceports' => undef);
is_deeply hidden_device_ports($device, \@ports), {},
  'hiddenDevicePorts__setting_absent__hides_nothing';

done_testing;
