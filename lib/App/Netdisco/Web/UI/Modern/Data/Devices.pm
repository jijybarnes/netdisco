package App::Netdisco::Web::UI::Modern::Data::Devices;

use strict;
use warnings;

use App::Netdisco::Web::UI::Modern::Data qw/iso8601_sql/;

use base 'Exporter';
our @EXPORT_OK = qw/list_devices normalize_device_row clamp_limit sort_spec word_conditions DEVICE_SORTS/;

=head1 NAME

App::Netdisco::Web::UI::Modern::Data::Devices - the list of devices, normalized

=head1 DESCRIPTION

What the modern interface's Devices page reads, and what C<GET /ajax/data/v2/devices>
returns: one light row per device, searched, ordered and cut to a page in the
database, so that a site with many thousands of devices sends only what is
shown.

=cut

# the columns a client may order by, and what each orders on. Never a name taken
# from the request: the request picks a key of this table.
use constant DEVICE_SORTS => {
  name          => [ 'COALESCE(NULLIF(me.dns, \'\'), me.name, host(me.ip))' ],
  ip            => [ 'me.ip' ],
  model         => [ 'me.model', 'me.vendor' ],
  os            => [ 'me.os', 'me.os_ver' ],
  location      => [ 'me.location' ],
  ports         => [ 'me.num_ports' ],
  last_discover => [ 'me.last_discover' ],
};

=head1 FUNCTIONS

=head2 clamp_limit( $wanted )

How many rows to return: 100 when none is asked for, never more than 1000.

=cut

sub clamp_limit {
  my $n = shift;
  return 100 unless defined $n and $n =~ m/^\d+$/ and $n > 0;
  return $n > 1000 ? 1000 : 0 + $n;
}

=head2 sort_spec( $key, $dir )

The ordering for a sort key and direction, or the default (by name) for a key
that is not one of L</DEVICE_SORTS>. Returns C<< ($key, $dir) >> as used.

=cut

sub sort_spec {
  my ($key, $dir) = @_;
  $key = 'name' unless defined $key and exists DEVICE_SORTS->{$key};
  $dir = (defined $dir and lc $dir eq 'desc') ? 'desc' : 'asc';
  return ($key, $dir);
}

sub _str { my $v = shift; (defined $v and length $v) ? "$v" : undef }

=head2 normalize_device_row( \%columns, $failing )

Pure: one device's columns (with the C<_iso_*> times) to the list's row.
C<$failing> is true when the device has connection failures recorded (see
L<App::Netdisco::Web::UI::Modern::Data::Device/normalize_health>).

=cut

sub normalize_device_row {
  my ($c, $failing) = @_;
  my $int = sub { my $v = shift; (defined $v and $v =~ m/^-?\d+$/) ? 0 + $v : undef };
  return {
    ip              => _str($c->{ip}),
    name            => _str($c->{name}),
    dns             => _str($c->{dns}),
    vendor          => _str($c->{vendor}),
    model           => _str($c->{model}),
    os              => _str($c->{os}),
    os_version      => _str($c->{os_ver}),
    location        => _str($c->{location}),
    num_ports       => $int->($c->{num_ports}),
    last_discover_at => _str($c->{_iso_last_discover}),
    last_macsuck_at  => _str($c->{_iso_last_macsuck}),
    health          => ($failing ? 'failing' : 'ok'),
  };
}

=head2 word_conditions( $q )

The conditions that find a device from some words: every word has to be
somewhere in the device (its names, address, model, software, place, serial or
description), so a search narrows as it is typed. LIKE's metacharacters in a
word are escaped: the words are text, not patterns.

=cut

sub word_conditions {
  my $q = shift;
  my @words = grep { length } split /\s+/, (defined $q ? $q : '');
  return map {
    (my $w = $_) =~ s/([\\%_])/\\$1/g;
    my $like = "%$w%";
    # +{ }: a bare { } here would be read as a block, and its pairs would join
    # the list one by one, so that the words were no longer all required
    +{ -or => [
        \[ q{host(me.ip) ILIKE ?} => [ bind_value => $like ] ],
        map {{ $_ => { -ilike => $like } }} qw/me.dns me.name me.model me.vendor me.os me.os_ver me.location me.serial me.description/,
    ] }
  } @words;
}

=head2 list_devices( $schema, %opts )

C<< { rows, total, failing } >>: one page of devices (C<limit>, from C<offset>),
those matching C<q> (every word of it), the failing ones only if C<health> is
C<failing>, in the order of C<sort> and C<dir>. C<total> counts the matches,
C<failing> how many of the known devices have connection failures, matching or not.

=cut

sub list_devices {
  my ($schema, %opts) = @_;
  my $limit  = clamp_limit($opts{limit});
  my $offset = (defined $opts{offset} and $opts{offset} =~ m/^\d+$/) ? 0 + $opts{offset} : 0;
  my ($key, $dir) = sort_spec($opts{sort}, $opts{dir});

  my %failing = map { $_->get_column('device') => 1 } $schema->resultset('DeviceSkip')->search(
    { deferrals => { '>' => 0 }, device => { '!=' => '255.255.255.255' } },
    { columns => ['device'], distinct => 1 })->all;

  my @conds = word_conditions($opts{q});
  push @conds, { 'me.ip' => { -in => [ keys %failing ] || [] } }
    if defined $opts{health} and $opts{health} eq 'failing' and %failing;
  push @conds, \'1=0' if defined $opts{health} and $opts{health} eq 'failing' and not %failing;

  my $rs = $schema->resultset('Device')->search({ -and => \@conds });
  my $total = $rs->count;

  my @order = map { +{ "-$dir" => \$_ } } @{ DEVICE_SORTS->{$key} };
  my @rows = map {{ $_->get_columns }} $rs->search({}, {
    '+columns' => {
      _iso_last_discover => \iso8601_sql('me.last_discover'),
      _iso_last_macsuck  => \iso8601_sql('me.last_macsuck'),
    },
    order_by => [ @order, { -asc => 'me.ip' } ],
    rows     => $limit,
    offset   => $offset,
  })->all;

  # device_skip also holds addresses that were tried and are not devices (a
  # discover of a whole subnet leaves one per dead address), which are not on
  # this list and so are not counted in it
  my $failing_known = %failing
    ? $schema->resultset('Device')->search({ 'me.ip' => { -in => [ keys %failing ] } })->count : 0;

  return {
    rows    => [ map { normalize_device_row($_, $failing{ $_->{ip} }) } @rows ],
    total   => $total,
    failing => $failing_known,
  };
}

1;
