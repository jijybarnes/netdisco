package App::Netdisco::Web::Data::Device;

use strict;
use warnings;

use JSON::PP ();
use App::Netdisco::Web::Data qw/problem json_bool iso8601_sql layers_list/;

use base 'Exporter';
our @EXPORT_OK = qw/find_device device_summary normalize_device normalize_poe normalize_health normalize_counts/;

=head1 NAME

App::Netdisco::Web::Data::Device - one device, normalized

=head1 FUNCTIONS

=head2 find_device( $schema, $q )

The device C<$q> names: its canonical IP, any of its interface addresses, or
its name, as the classic device page accepts. Stops the route with a 404
otherwise.

=cut

sub find_device {
  my ($schema, $q) = @_;
  my $device = (defined $q and length $q)
    ? $schema->resultset('Device')->search_for_device($q) : undef;
  return $device || problem(404, 'Device not found',
    sprintf q{No device is known as '%s'.}, ($q // ''));
}

my @TIMES = (
  [ creation      => 'first_seen_at' ],
  [ last_discover => 'last_discover_at' ],
  [ last_macsuck  => 'last_macsuck_at' ],
  [ last_arpnip   => 'last_arpnip_at' ],
);

=head2 device_summary( $schema, $device )

The device as the v2 API returns it, read again with its times rendered by the
database (see L<App::Netdisco::Web::Data/iso8601_sql>).

=cut

sub device_summary {
  my ($schema, $device) = @_;

  my $row = $schema->resultset('Device')->search({ 'me.ip' => $device->ip }, {
    '+columns' => { map {( "_iso_$_->[0]" => \iso8601_sql("me.$_->[0]") )} @TIMES },
  })->single or problem(404, 'Device not found', 'The device was removed.');

  my @modules = map {{ $_->get_columns }} $schema->resultset('DevicePower')
    ->search({ 'me.ip' => $device->ip })->with_poestats->all;

  my $health = $schema->resultset('DeviceSkip')->search(
    { 'me.device' => $device->ip, 'me.deferrals' => { '>' => 0 } },
    { select => [ { max => 'me.deferrals' }, \iso8601_sql('MAX(me.last_defer)') ],
      as => [qw/deferrals _iso_last_defer/] })->single;

  my $c = { $row->get_columns };
  my %counts = (
    addresses => $device->device_ips->count,
    vlans     => $device->vlans->count,
    modules   => $device->modules->count,
    neighbors => $schema->resultset('DevicePort')->search(
      { 'me.ip' => $device->ip, 'me.remote_ip' => { '!=' => undef } },
      { columns => ['remote_ip'], distinct => 1 })->count,
  );

  return {
    %{ normalize_device($c) },
    poe     => normalize_poe(\@modules),
    health  => normalize_health($health ? { $health->get_columns } : undef),
    counts  => normalize_counts($c, \%counts),
  };
}

=head2 normalize_health( \%skip )

Pure: whether the backend can reach the device, from the C<device_skip> rows
the SNMP Connect Failures admin task lists (a device is failing while any of
its rows has C<deferrals> above zero). C<%skip> carries the largest deferral
count and the latest failure, or is C<undef> when there is no such row.

=cut

sub normalize_health {
  my $skip = shift;
  my $n = ($skip and defined $skip->{deferrals} and $skip->{deferrals} =~ m/^\d+$/) ? 0 + $skip->{deferrals} : 0;
  return {
    state           => ($n > 0 ? 'failing' : 'ok'),
    deferrals       => $n,
    last_failure_at => ($n > 0 && defined $skip->{_iso_last_defer} && length $skip->{_iso_last_defer})
                         ? "$skip->{_iso_last_defer}" : undef,
  };
}

=head2 normalize_counts( \%device, \%counted )

Pure: how many of each thing the device page's tabs list. C<ports> is what the
device reported at its last discover; the tab then shows the ports the site's
C<hide_deviceports> leaves in, which can be fewer, so the browser corrects the
count when the tab loads. The others are exact.

=cut

sub normalize_counts {
  my ($device, $counted) = @_;
  my $n = sub { my $v = shift; (defined $v and $v =~ m/^\d+$/) ? 0 + $v : 0 };
  return {
    ports     => $n->($device->{num_ports}),
    addresses => $n->($counted->{addresses}),
    vlans     => $n->($counted->{vlans}),
    modules   => $n->($counted->{modules}),
    neighbors => $n->($counted->{neighbors}),
  };
}

=head2 normalize_poe( \@modules )

Pure: the device's power modules, as C<with_poestats> reads them, totalled into
one object, or C<undef> for a device with no PoE. The module budget and the
committed power are watts as the switch reports them; the delivered power is
what the ports measure, in watts, to a tenth. Committed power is estimated from
each powered port's class, as the classic PoE report does.

=cut

sub normalize_poe {
  my $modules = shift;
  return undef unless $modules and scalar @$modules;

  my %t = map {( $_ => 0 )} qw/budget committed delivering capable powered disabled errored/;
  foreach my $m (@$modules) {
    $t{budget}     += $m->{power}                // 0;
    $t{committed}  += $m->{poe_power_committed}  // 0;
    $t{delivering} += $m->{poe_power_delivering} // 0;
    $t{capable}    += $m->{poe_capable_ports}    // 0;
    $t{powered}    += $m->{poe_powered_ports}    // 0;
    $t{disabled}   += $m->{poe_disabled_ports}   // 0;
    $t{errored}    += $m->{poe_errored_ports}    // 0;
  }

  my $tenth = sub { 0 + sprintf '%.1f', shift };
  return {
    modules          => scalar @$modules,
    budget_watts     => $tenth->($t{budget}),
    committed_watts  => $tenth->($t{committed}),
    delivering_watts => $tenth->($t{delivering}),
    capable_ports    => 0 + $t{capable},
    powered_ports    => 0 + $t{powered},
    disabled_ports   => 0 + $t{disabled},
    errored_ports    => 0 + $t{errored},
  };
}

=head2 normalize_device( \%columns )

Pure: the C<device> row's columns (plus the C<_iso_*> times) to the API shape.
The SNMP community column is never read, so it cannot leak through here.

=cut

sub normalize_device {
  my $c = shift;
  my $str = sub { my $v = $c->{ $_[0] }; (defined $v and length $v) ? "$v" : undef };
  my $int = sub { my $v = $c->{ $_[0] }; (defined $v and $v =~ m/^-?\d+$/) ? 0 + $v : undef };

  my $custom = $c->{custom_fields};
  $custom = (eval { JSON::PP->new->decode($custom) } || {})
    if defined $custom and not ref $custom;

  return {
    ip           => $str->('ip'),
    dns          => $str->('dns'),
    name         => $str->('name'),
    description  => $str->('description'),
    vendor       => $str->('vendor'),
    model        => $str->('model'),
    os           => $str->('os'),
    os_version   => $str->('os_ver'),
    serial       => $str->('serial'),
    chassis_id   => $str->('chassis_id'),
    mac          => $str->('mac'),
    location     => $str->('location'),
    contact      => $str->('contact'),
    layers       => layers_list($c->{layers}),
    # sysUpTime is in hundredths of a second, as of the last discover
    uptime_seconds => (defined $int->('uptime') ? int($int->('uptime') / 100) : undef),
    num_ports    => $int->('num_ports'),
    is_pseudo    => json_bool($c->{is_pseudo}),
    snmp         => {
      class     => $str->('snmp_class'),
      version   => $int->('snmp_ver'),
      engine_id => $str->('snmp_engineid'),
    },
    (map {( $_->[1] => $str->("_iso_$_->[0]") )} @TIMES),
    tags          => [ @{ $c->{tags} || [] } ],
    custom_fields => (ref {} eq ref $custom ? $custom : {}),
  };
}

1;
