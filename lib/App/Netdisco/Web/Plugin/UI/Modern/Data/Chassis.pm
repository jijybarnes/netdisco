package App::Netdisco::Web::Plugin::UI::Modern::Data::Chassis;

use strict;
use warnings;

use App::Netdisco::Web::Plugin::UI::Modern::Data qw/json_bool/;

use base 'Exporter';
our @EXPORT_OK = qw/device_stack stack_layout/;

=head1 NAME

App::Netdisco::Web::Plugin::UI::Modern::Data::Chassis - a device's stack units, modules and transceivers, put with its ports

=head1 DESCRIPTION

Netdisco keeps the device's entity tree (C<device_module>: the stack, its
chassis, their modules, the ports and the containers and transceivers between)
and its ports (C<device_port>) apart, with nothing that says which entity is
which port. This reads the one against the other, as well as can be told:

=over 4

=item *

The B<units> are the chassis of the entity tree that sit in no other chassis,
in the order the device numbers them. A device with no chassis has none from
the entities.

=item *

An entity is put with a B<port> by its name, if one fits uniquely: the same
name; the same numbers with the entity's letters the start of the port's
(C<Te1/1/3> is C<TenGigabitEthernet1/1/3>); or, on a stack that numbers its
ports by unit and position (C<2.24>), the port entity of that position in that
unit.

=item *

A container named after a port with nothing plugged in (C<Te1/1/2 Container>)
stands for that port.

=item *

A port with no entity, or a device with no entities, is put in a unit by the
first number of its name (C<GigabitEthernet3/0/12> is of unit 3), when the
name is a three-part one or a C<unit.port> one. Without entities that needs at
least two units to be told apart.

=back

None of this is certain, and nothing here guesses past that: a port which no
rule places is left with no unit.

=cut

# 't', 'true', 1: the driver gives either
sub _true { my $v = shift; return (defined $v and $v ne '' and $v !~ m/^(?:f|false|0)$/i) ? 1 : 0 }

sub _str { my $v = shift; return (defined $v and length $v) ? "$v" : undef }

# the number a name ends in: "Switch 3", "switch-3", "port-24"
sub _trailing_number {
  my $name = shift;
  return (defined $name and $name =~ m/(\d+)\s*$/) ? 0 + $1 : undef;
}

=head1 FUNCTIONS

=head2 stack_layout( \@modules, \@port_names )

Pure. C<@modules> are C<device_module> rows as hashes (C<index>, C<parent>,
C<class>, C<pos>, C<name>, C<description>, C<model>, C<serial>, C<hw_ver>,
C<fw_ver>, C<sw_ver>, C<fru>); C<@port_names> the device's port names.

Returns C<< { source, units, ports } >>:

=over 4

=item C<source>

C<entities> when the units come from the entity tree, C<names> when from the
port names alone, C<none> when there are no units.

=item C<units>

Each C<< { number, label, model, serial, hw_ver, sw_ver, fw_ver, port_count,
modules } >>, in number order. C<modules> are the unit's modules which have
ports or a model, each C<< { id, label, model, serial, port_count } >>.

=item C<ports>

Port name to C<< { unit, module, transceiver } >> for each port that has any:
C<unit> is the unit's number, C<module> the id of the nearest module the
port's entity sits in, C<transceiver> the pluggable part in its socket
(C<description>, C<model>, C<serial>).

=back

=cut

sub stack_layout {
  my ($modules, $port_names) = @_;
  $modules ||= [];
  $port_names ||= [];

  my %entity = map {( $_->{index} => $_ )} grep { defined $_->{index} } @$modules;
  my $parent = sub { my $e = shift; return defined $e->{parent} ? $entity{ $e->{parent} } : undef };

  # nearest ancestor (or self) satisfying a test, no further than a cycle allows
  my $up = sub {
    my ($e, $test) = @_;
    for (my $guard = 0; $e and $guard < 30; $e = $parent->($e), $guard++) {
      return $e if $test->($e);
    }
    return undef;
  };
  my $is_class = sub { my $c = shift; return sub { lc(($_[0]->{class} // '')) eq $c } };

  # ---- the units ----
  my @chassis = grep { lc($_->{class} // '') eq 'chassis' } values %entity;
  @chassis = grep { not $up->($parent->($_) || {}, $is_class->('chassis')) } @chassis;
  @chassis = sort { ($a->{pos} // 0) <=> ($b->{pos} // 0) or $a->{index} <=> $b->{index} } @chassis;

  # numbered as the device names them; if that does not number them each once,
  # by their order
  my @numbers = map { _trailing_number($_->{name}) } @chassis;
  my %seen;
  my $named = scalar(@chassis) && !grep({ !defined $_ or $seen{$_}++ } @numbers);
  my %unit_of_chassis;
  my @units;
  for my $i (0 .. $#chassis) {
    my $c = $chassis[$i];
    my $number = $named ? $numbers[$i] : $i + 1;
    $unit_of_chassis{ $c->{index} } = $number;
    push @units, {
      number => $number, label => (_str($c->{name}) // "Unit $number"),
      model => _str($c->{model}) // _str($c->{description}), serial => _str($c->{serial}),
      hw_ver => _str($c->{hw_ver}), sw_ver => _str($c->{sw_ver}), fw_ver => _str($c->{fw_ver}),
      port_count => 0, modules => [],
    };
  }
  @units = sort { $a->{number} <=> $b->{number} } @units;
  my %unit = map {( $_->{number} => $_ )} @units;

  my %ports;   # port name => { unit, module, transceiver }

  # ---- entities put with ports ----
  my @port_entities = grep { lc($_->{class} // '') eq 'port' } values %entity;

  # A socket with nothing in it has no port entity, only the container that
  # would hold one, named after the port ("Te1/1/2 Container"). It stands for
  # the port, so that the empty uplinks are with their module too.
  my %has_port_child = map {( $_->{parent} => 1 )} grep { defined $_->{parent} } @port_entities;
  foreach my $e (grep { lc($_->{class} // '') eq 'container' and not $has_port_child{ $_->{index} } } values %entity) {
    next unless defined $e->{name} and $e->{name} =~ m/^(\S+\d)\s+container$/i;
    push @port_entities, { %$e, name => $1 };
  }
  my (%by_name, %by_path);
  foreach my $e (@port_entities) {
    my $n = lc($e->{name} // '');
    next unless length $n;
    push @{ $by_name{$n} }, $e;
    # by the numbers it ends in, with the letters before them (Te1/1/3)
    push @{ $by_path{$2} }, [ $1, $e ] if $n =~ m/^([a-z\-]*?)(\d+(?:[\/.]\d+)*)$/;
  }

  my %claimed;
  my $take = sub {
    my ($list) = @_;
    return undef unless $list and @$list == 1 and not $claimed{ $list->[0]{index} }++;
    return $list->[0];
  };

  my %entity_of_port;
  # 1. the same name
  foreach my $name (@$port_names) {
    my $e = $take->($by_name{ lc $name }) or next;
    $entity_of_port{$name} = $e;
  }
  # 2. the same numbers, the entity's letters the start of the port's
  foreach my $name (@$port_names) {
    next if $entity_of_port{$name};
    next unless lc($name) =~ m/^([a-z\-]+?)(\d+(?:[\/.]\d+)*)$/;
    my ($letters, $path) = ($1, $2);
    my @fit = grep { length $_->[0] and index($letters, $_->[0]) == 0 } @{ $by_path{$path} || [] };
    my $e = $take->([ map { $_->[1] } @fit ]) or next;
    $entity_of_port{$name} = $e;
  }
  # 3. by position: port 24 of unit 2 is "2.24" or "2/24"
  my %by_position;
  foreach my $e (@port_entities) {
    my $chassis = $up->($e, $is_class->('chassis')) or next;
    my $u = $unit_of_chassis{ $chassis->{index} };
    next unless defined $u;
    my $n = _trailing_number($e->{name});
    $n = $e->{pos} unless defined $n;
    next unless defined $n;
    push @{ $by_position{"$u/$n"} }, $e;
  }
  foreach my $name (@$port_names) {
    next if $entity_of_port{$name};
    next unless $name =~ m/^(\d+)[.\/](\d+)$/ and $unit{$1};
    my $e = $take->($by_position{"$1/$2"}) or next;
    $entity_of_port{$name} = $e;
  }

  my %module_ports;
  foreach my $name (keys %entity_of_port) {
    my $e = $entity_of_port{$name};
    my $chassis = $up->($e, $is_class->('chassis'));
    my $module = $up->($parent->($e) || {}, $is_class->('module'));
    my $u = $chassis ? $unit_of_chassis{ $chassis->{index} } : undef;

    # the pluggable part: a FRU on the path from the port to its module whose
    # parent is a container (a socket)
    my $transceiver;
    my $walk = $e;
    for (my $guard = 0; $walk and $guard < 10; $walk = $parent->($walk), $guard++) {
      last if lc($walk->{class} // '') =~ m/^(?:chassis|stack)$/;
      my $p = $parent->($walk);
      if (_true($walk->{fru}) and $p and lc($p->{class} // '') eq 'container'
          and grep { _str($walk->{$_}) } qw/description model serial/) {
        $transceiver = { description => _str($walk->{description}), model => _str($walk->{model}),
                         serial => _str($walk->{serial}) };
        last;
      }
    }

    $ports{$name} = {
      unit => $u, module => ($module ? 0 + $module->{index} : undef), transceiver => $transceiver,
    };
    $unit{$u}{port_count}++ if defined $u and $unit{$u};
    $module_ports{ $module->{index} }++ if $module;
  }

  # the unit's modules: those with ports, or a model
  foreach my $e (sort { $a->{index} <=> $b->{index} } grep { lc($_->{class} // '') eq 'module' } values %entity) {
    my $chassis = $up->($e, $is_class->('chassis')) or next;
    my $u = $unit_of_chassis{ $chassis->{index} };
    next unless defined $u and $unit{$u};
    next unless $module_ports{ $e->{index} } or _str($e->{model});
    push @{ $unit{$u}{modules} }, {
      id => 0 + $e->{index}, label => (_str($e->{name}) // _str($e->{description}) // "Module $e->{index}"),
      model => _str($e->{model}), serial => _str($e->{serial}), port_count => 0 + ($module_ports{ $e->{index} } || 0),
    };
  }

  # ---- the rest, by the first number of the name ----
  my $first_number = sub {
    my $name = shift;
    return $1 if $name =~ m/^[A-Za-z][A-Za-z\-]*(\d+)\/\d+\/\d+(?:[.:]\d+)?$/;   # Gi1/0/1
    return $1 if $name =~ m/^(\d+)[.\/]\d+$/;                                    # 2.24
    return undef;
  };

  my $source = @units ? 'entities' : 'none';
  my @loose = grep { not $ports{$_} } @$port_names;

  if (not @units) {
    my %distinct = map {( $_ => 1 )} grep { defined } map { $first_number->($_) } @$port_names;
    if (scalar(keys %distinct) >= 2) {
      foreach my $n (sort { $a <=> $b } keys %distinct) {
        $unit{$n} = { number => 0 + $n, label => "Unit $n", model => undef, serial => undef,
                      hw_ver => undef, sw_ver => undef, fw_ver => undef, port_count => 0, modules => [] };
      }
      @units = map { $unit{$_} } sort { $a <=> $b } keys %unit;
      $source = 'names';
    }
  }

  if (@units) {
    foreach my $name (@loose) {
      my $n = $first_number->($name);
      next unless defined $n and $unit{ 0 + $n };
      $ports{$name} = { unit => 0 + $n, module => undef, transceiver => undef };
      $unit{ 0 + $n }{port_count}++;
    }
  }

  return { source => $source, units => \@units, ports => \%ports };
}

=head2 device_stack( $schema, $device )

L</stack_layout> of what the database holds for C<$device>.

=cut

sub device_stack {
  my ($schema, $device) = @_;
  my @modules = map {{ $_->get_columns }} $schema->resultset('DeviceModule')->search(
    { 'me.ip' => $device->ip },
    { columns => [qw/index parent class pos name description model serial hw_ver fw_ver sw_ver fru/] })->all;
  my @names = map { $_->port } $schema->resultset('DevicePort')->search(
    { 'me.ip' => $device->ip }, { columns => ['port'] })->all;
  return stack_layout(\@modules, \@names);
}

1;
