#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;

use App::Netdisco::Web::Plugin::UI::Modern::Data::Chassis 'stack_layout';

# Netdisco keeps a device's entity tree and its ports apart, with nothing that
# says which entity is which port, so the front panel's units, modules and
# transceivers are read from the two together. The fixtures below have the
# shapes of the devices in the lab (their trees were read from device_module),
# trimmed to a few ports, so each vendor's way of naming and numbering is what
# is pinned. Pure: no database (xt/36).

sub ent {
  my ($index, $parent, $class, %o) = @_;
  return { index => $index, parent => $parent, class => $class, pos => $o{pos},
           name => $o{name}, description => $o{description}, model => $o{model},
           serial => $o{serial}, fru => ($o{fru} ? 1 : 0), hw_ver => $o{hw}, sw_ver => $o{sw}, fw_ver => $o{fw} };
}

# ---- a Cisco 9300 stack: names abbreviated, uplinks in their own module ----
sub cisco_stack {
  my $units = shift;
  my @m = (ent(1, 0, 'stack', pos => -1, name => 'c93xxL Stack', model => 'C9300L-48P-4X'));
  foreach my $u (1 .. $units) {
    my $base = $u * 1000;
    push @m,
      ent($base, 1, 'chassis', pos => $u - 1, name => "Switch $u", model => 'C9300L-48P-4X', serial => "SER$u", sw => '17.9.4'),
      ent($base + 60, $base, 'module', pos => 11, name => "Switch $u Fixed Module 0"),
      ent($base + 109, $base + 60, 'module', pos => 0, name => "Switch $u Fixed Uplink Module 0");
    push @m, ent($base + 60 + $_, $base + 60, 'port', pos => $_ - 1, name => "Gi$u/0/$_", description => "Gi$u/0/$_") for 1 .. 4;
    foreach my $t (1 .. 4) {
      push @m, ent($base + 109 + $t, $base + 109, 'container', pos => $t - 1, name => "Te$u/1/$t Container");
    }
    # a transceiver in socket 3 of the uplink module
    push @m, ent($base + 114, $base + 112, 'port', pos => 1, name => "Te$u/1/3", fru => 1,
                 serial => "SFP$u", description => '10/100/1000BaseTX SFP');
    # the stack adapter, which is no port
    push @m, ent($base + 3, $base, 'other', pos => 1, name => "StackAdapter$u/1", model => 'C9300L-STACK', serial => "ADA$u");
  }
  return \@m;
}

my @cisco_ports = (
  (map { my $u = $_; map { "GigabitEthernet$u/0/$_" } 1 .. 4 } 1 .. 3),
  (map { my $u = $_; map { "TenGigabitEthernet$u/1/$_" } 1 .. 4 } 1 .. 3),
  'AppGigabitEthernet1/0/1', 'AppGigabitEthernet2/0/1', 'GigabitEthernet0/0', 'Bluetooth0/4', 'Vlan10', 'Loopback0',
);

my $c = stack_layout(cisco_stack(3), \@cisco_ports);
is $c->{source}, 'entities', 'stackLayout__cisco_stack__units_from_the_entities';
is_deeply [ map { $_->{number} } @{ $c->{units} } ], [1, 2, 3], 'stackLayout__cisco_stack__one_unit_per_chassis_in_order';
is_deeply [ map { $_->{label} } @{ $c->{units} } ], ['Switch 1', 'Switch 2', 'Switch 3'], 'stackLayout__cisco_stack__units_labelled_as_the_device_does';
my ($u2) = grep { $_->{number} == 2 } @{ $c->{units} };
is $u2->{model}, 'C9300L-48P-4X', 'stackLayout__unit__has_its_model';
is $u2->{serial}, 'SER2', 'stackLayout__unit__has_its_serial';
is $u2->{sw_ver}, '17.9.4', 'stackLayout__unit__has_its_software_version';

is $c->{ports}{'GigabitEthernet2/0/3'}{unit}, 2, 'stackLayout__abbreviated_entity_name__port_placed_in_its_unit';
is $c->{ports}{'GigabitEthernet2/0/3'}{module}, 2060, 'stackLayout__access_port__placed_in_the_fixed_module';
is $c->{ports}{'TenGigabitEthernet1/1/2'}{module}, 1109, 'stackLayout__uplink_port__placed_in_the_nearest_module_not_the_fixed_one';
is $c->{ports}{'TenGigabitEthernet1/1/3'}{transceiver}{serial}, 'SFP1', 'stackLayout__fru_in_a_socket__is_the_transceiver';
is $c->{ports}{'TenGigabitEthernet1/1/3'}{transceiver}{description}, '10/100/1000BaseTX SFP', 'stackLayout__transceiver__has_its_description';
ok !defined $c->{ports}{'TenGigabitEthernet1/1/2'}{transceiver}, 'stackLayout__empty_socket__no_transceiver';
ok !defined $c->{ports}{'GigabitEthernet1/0/1'}{transceiver}, 'stackLayout__fixed_port__no_transceiver';

is $c->{ports}{'AppGigabitEthernet2/0/1'}{unit}, 2, 'stackLayout__port_with_no_entity__placed_by_the_first_number_of_its_name';
ok !defined $c->{ports}{'AppGigabitEthernet2/0/1'}{module}, 'stackLayout__port_placed_by_name__has_no_module';
ok !exists $c->{ports}{'GigabitEthernet0/0'}, 'stackLayout__two_part_name__left_unplaced';
ok !exists $c->{ports}{$_}, "stackLayout__${_}__left_unplaced" for qw/Bluetooth0/ ? ('Vlan10', 'Loopback0') : ();

is_deeply [ map { $_->{id} } @{ $u2->{modules} } ], [2060, 2109], 'stackLayout__unit__lists_its_modules_with_ports';
is $u2->{port_count}, 4 + 4 + 1, 'stackLayout__unit__counts_its_ports';

# a stack on one unit is still a unit, with its identity
my $one = stack_layout(cisco_stack(1), [ 'GigabitEthernet1/0/1' ]);
is scalar @{ $one->{units} }, 1, 'stackLayout__single_chassis__one_unit';
is $one->{source}, 'entities', 'stackLayout__single_chassis__units_from_the_entities';

# ---- Avaya: entities named port-N, ports named unit.port ----
my @avaya = (ent(1, 0, 'stack', name => 'stack'));
foreach my $u (1, 2) {
  my $chassis = $u == 1 ? 2 : 208;
  push @avaya, ent($chassis, 1, 'chassis', pos => $u, name => "switch-$u", model => '4850GTS-PWR+', serial => "AV$u");
  push @avaya, ent($chassis + 1000 + $_, $chassis, 'port', pos => $_, name => "port-$_", description => 'Multi-Speed Ethernet Port') for 1 .. 24;
  push @avaya, ent($chassis + 197, $chassis, 'module', pos => 197, name => 'cascade', model => '400-ST1');
}
my $a = stack_layout(\@avaya, [ '1.1', '1.24', '2.24', '3.9' ]);
is_deeply [ map { $_->{number} } @{ $a->{units} } ], [1, 2], 'stackLayout__avaya__units_from_chassis_names';
is $a->{ports}{'2.24'}{unit}, 2, 'stackLayout__avaya_unit_dot_port__placed_by_position_in_its_unit';
is $a->{ports}{'1.1'}{unit}, 1, 'stackLayout__avaya_first_unit__placed';
ok !exists $a->{ports}{'3.9'}, 'stackLayout__avaya_unit_the_stack_lacks__left_unplaced';
is_deeply [ map { "$_->{label}:$_->{model}" } @{ $a->{units}[1]{modules} } ], ['cascade:400-ST1'], 'stackLayout__module_with_a_model_but_no_ports__still_listed';

# ---- Arista: one chassis, the entities are named as the ports are ----
my @arista = (ent(1, 0, 'chassis', pos => 0, name => 'cEOSLab', model => 'cEOSLab', serial => 'ABC'),
              ent(2, 1, 'container', pos => 2, name => 'Ports'),
              ent(3, 2, 'port', pos => 0, name => 'Ethernet31'), ent(4, 2, 'port', pos => 1, name => 'Management0'));
my $e = stack_layout(\@arista, [ 'Ethernet31', 'Management0', 'Vlan10' ]);
is_deeply [ map { $_->{number} } @{ $e->{units} } ], [1], 'stackLayout__arista__one_unit_numbered_by_order_when_its_name_has_no_number';
is $e->{units}[0]{label}, 'cEOSLab', 'stackLayout__arista__unit_labelled_by_the_chassis_name';
is $e->{ports}{Ethernet31}{unit}, 1, 'stackLayout__exact_name__port_placed';
is $e->{ports}{Management0}{unit}, 1, 'stackLayout__exact_name_management__port_placed';

# ---- no entities: units from the names, if they tell at least two apart ----
my $n = stack_layout([], [ 'GigabitEthernet1/0/1', 'GigabitEthernet3/0/12', 'Vlan1', 'GigabitEthernet0/0' ]);
is $n->{source}, 'names', 'stackLayout__no_entities_two_numbers__units_from_the_names';
is_deeply [ map { "$_->{number}:$_->{label}" } @{ $n->{units} } ], ['1:Unit 1', '3:Unit 3'], 'stackLayout__names_only__units_labelled_by_number';
is $n->{ports}{'GigabitEthernet3/0/12'}{unit}, 3, 'stackLayout__names_only__port_in_its_unit';

my $s = stack_layout([], [ 'GigabitEthernet1/0/1', 'GigabitEthernet1/0/2' ]);
is $s->{source}, 'none', 'stackLayout__no_entities_one_number__no_units';
is_deeply $s->{units}, [], 'stackLayout__no_entities_one_number__nothing_to_choose';
is_deeply stack_layout(undef, undef), { source => 'none', units => [], ports => {} }, 'stackLayout__nothing_at_all__empty';

# ---- an abbreviation that fits two entities is not guessed ----
my @tw = (ent(1, 0, 'chassis', pos => 0, name => 'Chassis 1'), ent(2, 1, 'port', name => 'Tw1/0/1'), ent(3, 1, 'port', name => 'Twe1/0/1'));
my $t = stack_layout(\@tw, [ 'TwentyFiveGigE1/0/1' ]);
is $t->{ports}{'TwentyFiveGigE1/0/1'}{module}, undef, 'stackLayout__two_entities_fit_one_name__not_guessed';
ok !defined $t->{ports}{'TwentyFiveGigE1/0/1'}{transceiver}, 'stackLayout__two_entities_fit_one_name__no_transceiver_invented';

# an entity cannot stand for two ports
my @dup = (ent(1, 0, 'chassis', pos => 0, name => 'Chassis 1'), ent(2, 1, 'module', name => 'M'), ent(3, 2, 'port', name => 'Gi1/0/1'));
my $d = stack_layout(\@dup, [ 'GigabitEthernet1/0/1', 'GigabitEthernetX1/0/1' ]);
is scalar(grep { defined $d->{ports}{$_}{module} } keys %{ $d->{ports} }), 1, 'stackLayout__one_entity_two_ports__only_one_port_has_it';

# a cycle in the tree is no hang
my @loop = (ent(1, 2, 'chassis', name => 'A'), ent(2, 1, 'module', name => 'B'), ent(3, 2, 'port', name => 'Gi1'));
ok stack_layout(\@loop, ['GigabitEthernet1']), 'stackLayout__cycle_in_the_tree__still_answers';

done_testing;
