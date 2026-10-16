package App::Netdisco::Web::Data::Device;

use strict;
use warnings;

use JSON::PP ();
use App::Netdisco::Web::Data qw/problem json_bool iso8601_sql layers_list/;

use base 'Exporter';
our @EXPORT_OK = qw/find_device device_summary normalize_device/;

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

  return normalize_device({ $row->get_columns });
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
