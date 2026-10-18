package App::Netdisco::Web::UI::Modern::Data::Search;

use strict;
use warnings;

use App::Netdisco::Web::UI::Modern::Data qw/iso8601_sql json_bool/;
use App::Netdisco::Web::UI::Modern::Data::Devices 'list_devices';

use base 'Exporter';
our @EXPORT_OK = qw/classify_query like_pattern quick_search normalize_node_hit QUICK_LIMIT/;

=head1 NAME

App::Netdisco::Web::UI::Modern::Data::Search - a few of everything that matches, at once

=head1 DESCRIPTION

What the modern interface's command palette asks as the user types, and what
C<GET /ajax/data/v2/search> returns: the first few devices, nodes, port descriptions
and VLANs that match some text. Each kind is one small query, cut short in the
database. It finds things to go to; the classic search, which the palette
offers for the same text, is where everything that matches is listed.

=cut

use constant QUICK_LIMIT => 5;

sub _str { my $v = shift; (defined $v and length $v) ? "$v" : undef }

=head1 FUNCTIONS

=head2 classify_query( $text )

Pure: what the text can be. C<text>, trimmed; C<mac>, the MAC address it
writes in any of the usual ways, canonical; C<ip>, the address it is; C<vlan>,
the VLAN number it is. C<words> is true when it is long enough to look for in
names (two characters), which a single letter is not.

=cut

sub classify_query {
  my $q = shift // '';
  $q =~ s/^\s+|\s+$//g;
  $q = substr($q, 0, 200);

  my $mac;
  (my $hex = lc $q) =~ s/[:.\-]//g;
  if (length $hex == 12 and $hex =~ m/^[0-9a-f]{12}$/
      and $q =~ m/^(?:[0-9a-f]{2}([:-])(?:[0-9a-f]{2}\1){4}[0-9a-f]{2}|[0-9a-f]{4}\.[0-9a-f]{4}\.[0-9a-f]{4}|[0-9a-f]{12})$/i) {
    $mac = join ':', ($hex =~ m/(..)/g);
  }

  my $ip;
  if ($q =~ m/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/
      and not grep { $_ > 255 } ($1, $2, $3, $4)) {
    $ip = join '.', map { 0 + $_ } ($1, $2, $3, $4);
  }
  elsif (not defined $mac and $q =~ m/^[0-9a-f:]+$/i and $q =~ m/:.*:/ and $q =~ m/^[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}$/i) {
    $ip = lc $q;
  }

  my $vlan = ($q =~ m/^\d{1,4}$/ and $q >= 1 and $q <= 4094) ? 0 + $q : undef;

  return { text => $q, mac => $mac, ip => $ip, vlan => $vlan, words => (length($q) >= 2 ? 1 : 0) };
}

=head2 like_pattern( $text )

Pure: an ILIKE pattern that finds C<$text> anywhere, with its own C<%>, C<_>
and C<\> taken literally.

=cut

sub like_pattern {
  my $t = shift // '';
  $t =~ s/([\\%_])/\\$1/g;
  return "%$t%";
}

=head2 normalize_node_hit( \%node, \%address, \%device )

Pure: a node found by the palette, where it was last seen and as what.

=cut

sub normalize_node_hit {
  my ($n, $ip, $dev) = @_;
  $ip ||= {}; $dev ||= {};
  return {
    mac          => _str($n->{mac}),
    ip           => _str($ip->{ip}),
    dns          => _str($ip->{dns}),
    vendor       => _str($n->{vendor}),
    device_ip    => _str($n->{switch}),
    device_name  => _str($dev->{dns} || $dev->{name}),
    port         => _str($n->{port}),
    vlan         => ((defined $n->{vlan} and $n->{vlan} =~ m/^\d+$/) ? 0 + $n->{vlan} : undef),
    active       => json_bool($n->{active}),
    last_seen_at => _str($n->{_iso_time_last}),
  };
}

sub _device_names {
  my ($schema, @ips) = @_;
  return {} unless @ips;
  return { map {( $_->{ip} => $_ )} map {{ $_->get_columns }}
    $schema->resultset('Device')->search({ 'me.ip' => { -in => \@ips } }, { columns => [qw/ip dns name/] })->all };
}

# the nodes the text names: by MAC, by address, else by a DNS name containing
# it. Each node once, as last seen.
sub _nodes {
  my ($schema, $c, $limit) = @_;

  my @addresses;
  my $ips = $schema->resultset('NodeIp');
  if ($c->{mac}) {
    @addresses = ({ mac => $c->{mac} });
  }
  elsif ($c->{ip}) {
    @addresses = map {{ $_->get_columns }} $ips->search({ 'me.ip' => $c->{ip} },
      { columns => [qw/mac ip dns/], order_by => [ { -desc => 'me.active' }, { -desc => 'me.time_last' } ], rows => $limit })->all;
  }
  elsif ($c->{words} and length $c->{text} >= 3) {
    @addresses = map {{ $_->get_columns }} $ips->search(
      { 'me.dns' => { -ilike => like_pattern($c->{text}) }, 'me.active' => 1 },
      { columns => [qw/mac ip dns/], order_by => [ { -desc => 'me.time_last' } ], rows => $limit })->all;
  }
  return [] unless @addresses;

  my %addr_of;
  foreach my $a (@addresses) { $addr_of{ $a->{mac} } ||= $a }
  my @macs = keys %addr_of;

  # a node found by its MAC is named by its newest address
  if ($c->{mac}) {
    my ($best) = map {{ $_->get_columns }} $ips->search({ 'me.mac' => $c->{mac} },
      { columns => [qw/mac ip dns/], order_by => [ { -desc => 'me.active' }, { -desc => 'me.time_last' } ], rows => 1 })->all;
    $addr_of{ $c->{mac} } = $best if $best;
  }

  my %seen;
  my @nodes = grep { not $seen{ $_->{mac} }++ } map {{ $_->get_columns }} $schema->resultset('Node')->search(
    { 'me.mac' => { -in => \@macs } },
    { join => 'manufacturer',
      '+columns' => { vendor => 'manufacturer.company', _iso_time_last => \iso8601_sql('me.time_last') },
      order_by => [ { -desc => 'me.active' }, { -desc => 'me.time_last' } ] })->all;

  # an address with no node behind it (seen by arpnip only) is still worth going to
  push @nodes, map {{ mac => $_ }} grep { not $seen{$_} } @macs;

  my $devices = _device_names($schema, grep { defined } map { $_->{switch} } @nodes);
  return [ map { normalize_node_hit($_, $addr_of{ $_->{mac} }, $devices->{ $_->{switch} // '' }) }
           (@nodes > $limit ? @nodes[0 .. $limit - 1] : @nodes) ];
}

# the ports whose description (ifAlias) contains the text
sub _ports {
  my ($schema, $c, $limit) = @_;
  return [] unless $c->{words};
  my @rows = map {{ $_->get_columns }} $schema->resultset('DevicePort')->search(
    { 'me.name' => { -ilike => like_pattern($c->{text}) } },
    { columns => [qw/ip port name/], order_by => [qw/me.ip me.port/], rows => $limit })->all;
  my $devices = _device_names($schema, map { $_->{ip} } @rows);
  return [ map {{
    device_ip   => _str($_->{ip}),
    device_name => _str(($devices->{ $_->{ip} } || {})->{dns} || ($devices->{ $_->{ip} } || {})->{name}),
    port        => _str($_->{port}),
    name        => _str($_->{name}),
  }} @rows ];
}

# the VLANs with that number, or whose name contains the text, and on how many
# devices each is
sub _vlans {
  my ($schema, $c, $limit) = @_;
  my $cond = defined $c->{vlan} ? { 'me.vlan' => $c->{vlan} }
           : ($c->{words} ? { 'me.description' => { -ilike => like_pattern($c->{text}) } } : undef);
  return [] unless $cond;
  return [ map {{
    vlan         => 0 + $_->get_column('vlan'),
    name         => _str($_->get_column('name')),
    device_count => 0 + $_->get_column('device_count'),
  }} $schema->resultset('DeviceVlan')->search($cond, {
    select   => [ 'me.vlan', { max => 'me.description', -as => 'name' }, { count => { distinct => 'me.ip' }, -as => 'device_count' } ],
    as       => [qw/vlan name device_count/],
    group_by => 'me.vlan',
    order_by => [ { -desc => \'count(DISTINCT me.ip)' }, 'me.vlan' ],
    rows     => $limit,
  })->all ];
}

=head2 quick_search( $schema, $text )

The first few of each kind that match: C<devices> (as the Devices page lists
them), C<nodes>, C<ports> and C<vlans>. Nothing for text that names nothing.

=cut

sub quick_search {
  my ($schema, $text) = @_;
  my $c = classify_query($text);
  my $limit = QUICK_LIMIT;
  my $empty = { devices => [], nodes => [], ports => [], vlans => [] };
  return $empty unless length $c->{text};

  # a device's address is found among its own, which word_conditions covers;
  # a lone character or digit is too little to look for in names
  my $devices = ($c->{words} or $c->{ip})
    ? list_devices($schema, q => $c->{text}, limit => $limit)->{rows} : [];

  return {
    devices => $devices,
    nodes   => _nodes($schema, $c, $limit),
    ports   => _ports($schema, $c, $limit),
    vlans   => _vlans($schema, $c, $limit),
  };
}

1;
