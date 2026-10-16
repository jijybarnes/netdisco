package App::Netdisco::Web::Data::Ports;

use strict;
use warnings;

use JSON::PP ();
use App::Netdisco::Util::Port 'hidden_device_ports';
use App::Netdisco::Web::Data qw/problem json_bool iso8601_sql speed_to_bps/;

use base 'Exporter';
our @EXPORT_OK = qw/
  device_ports device_port port_nodes
  normalize_port normalize_node port_status ports_overview
/;

=head1 NAME

App::Netdisco::Web::Data::Ports - a device's ports and their nodes, normalized

=head1 FUNCTIONS

=head2 port_status( \%columns, $vlan_count )

One word for the state the classic Ports tab draws as an icon, decided in the
same order as F<share/views/ajax/device/ports.tt> so that both interfaces
agree: C<disabled> (admin down), C<blocking> (spanning tree, on a port in at
most one VLAN, since per-VLAN spanning tree blocks a trunk only for some),
C<errdisabled>, C<down> (enabled, no link), else C<up>. C<dormant> counts as up,
as it does there.

=cut

sub port_status {
  my ($c, $vlan_count) = @_;
  my $admin = $c->{up_admin} // '';
  my $oper  = $c->{up} // '';

  return 'disabled' if $admin ne 'up';
  return 'blocking' if $oper eq 'up' and ($c->{stp} // '') eq 'blocking'
                       and ($vlan_count // 0) < 2;
  return 'errdisabled' if defined $c->{error_disable_cause}
                          and length $c->{error_disable_cause};
  return 'down' if $oper ne 'up' and $oper ne 'dormant';
  return 'up';
}

sub _str { my $v = shift; (defined $v and length $v) ? "$v" : undef }
sub _int { my $v = shift; (defined $v and $v =~ m/^-?\d+$/) ? 0 + $v : undef }

=head2 normalize_port( \%columns, \%extra )

Pure: one port's columns (C<device_port>, plus what L</device_ports> joins in)
to the API shape. C<%extra> carries what comes from other queries: C<vlans>,
the port's VLAN numbers, and C<node_count>, its active nodes.

=cut

sub normalize_port {
  my ($c, $extra) = @_;
  $extra ||= {};
  my @vlans = sort { $a <=> $b } grep { defined } @{ $extra->{vlans} || [] };

  my $custom = $c->{custom_fields};
  $custom = (eval { JSON::PP->new->decode($custom) } || {})
    if defined $custom and not ref $custom;

  my $has_neighbor = (_str($c->{remote_ip}) or _str($c->{remote_id}));
  my $has_poe = defined $c->{poe_admin} || defined $c->{poe_status};

  return {
    port          => _str($c->{port}),
    descr         => _str($c->{descr}),
    name          => _str($c->{name}),
    type          => _str($c->{type}),
    ifindex       => _int($c->{ifindex}),
    mac           => _str($c->{mac}),
    mtu           => _int($c->{mtu}),

    status        => port_status($c, scalar @vlans),
    admin_status  => _str($c->{up_admin}),
    oper_status   => _str($c->{up}),
    error_disable_cause => _str($c->{error_disable_cause}),
    stp_state     => _str($c->{stp}),

    speed         => _str($c->{speed}),
    speed_bps     => speed_to_bps($c->{speed}),
    speed_admin   => _str($c->{speed_admin}),
    duplex        => _str($c->{duplex}),
    duplex_admin  => _str($c->{duplex_admin}),

    native_vlan   => _int($c->{vlan}),
    pvid          => _int($c->{pvid}),
    vlans         => \@vlans,

    is_uplink         => json_bool($c->{is_uplink}),
    is_master         => json_bool($c->{is_master}),
    slave_of          => _str($c->{slave_of}),
    has_subinterfaces => json_bool($c->{has_subinterfaces}),
    last_change_at    => _str($c->{last_change_at}),

    poe => ($has_poe ? {
      admin_enabled => json_bool(($c->{poe_admin} // '') eq 'true'),
      status        => _str($c->{poe_status}),
      class         => _str($c->{poe_class}),
      power_mw      => _int($c->{poe_power}),
    } : undef),

    neighbor => ($has_neighbor ? {
      ip              => _str($c->{remote_ip}),
      port            => _str($c->{remote_port}),
      id              => _str($c->{remote_id}),
      type            => _str($c->{remote_type}),
      dns             => _str($c->{remote_dns}),
      # the canonical IP of the neighbor when Netdisco knows it as a device
      device_ip       => _str($c->{neighbor_device_ip}),
      is_manual       => json_bool($c->{manual_topo}),
      is_phone        => json_bool($c->{remote_is_phone}),
      is_wap          => json_bool($c->{remote_is_wap}),
      is_discoverable => json_bool($c->{remote_is_discoverable}),
    } : undef),

    node_count    => 0 + ($extra->{node_count} || 0),
    tags          => [ @{ $c->{tags} || [] } ],
    custom_fields => (ref {} eq ref $custom ? $custom : {}),
  };
}

# The lastchange column is sysUpTime when the port last changed, so its wall
# clock time is the last discover minus the uptime since; with_times does the
# same arithmetic for the classic tab. A counter that has wrapped since, or a
# missing uptime, gives no time rather than a wrong one.
my $LAST_CHANGE_SQL = 'CASE WHEN me.lastchange IS NULL OR device.uptime IS NULL'
  . ' OR device.last_discover IS NULL OR me.lastchange > device.uptime THEN NULL ELSE '
  . iso8601_sql(q{device.last_discover - (device.uptime - me.lastchange) / 100 * interval '1 second'})
  . ' END';

sub _port_rs {
  my ($device) = @_;
  return $device->ports->with_properties->with_custom_fields->search({}, {
    '+columns' => {
      last_change_at     => \$LAST_CHANGE_SQL,
      neighbor_device_ip => 'neighbor_alias.ip',
      poe_admin          => 'power.admin',
      poe_status         => 'power.status',
      poe_class          => 'power.class',
      poe_power          => 'power.power',
    },
    join => [qw/device neighbor_alias power/],
  });
}

sub _vlans_by_port {
  my ($schema, $device, $only_port) = @_;
  my %by_port = ();
  my $rs = $schema->resultset('DevicePortVlan')->search({
    'me.ip' => $device->ip,
    (defined $only_port ? ('me.port' => $only_port) : ()),
  }, { columns => [qw/port vlan/] });
  # get_column: DevicePortVlan's port and vlan accessors are relationships
  push @{ $by_port{ $_->get_column('port') } }, $_->get_column('vlan') for $rs->all;
  return \%by_port;
}

sub _node_counts_by_port {
  my ($schema, $device) = @_;
  my $rs = $schema->resultset('Node')->search(
    { 'me.switch' => $device->ip, 'me.active' => 1 },
    { select => [ 'me.port', { count => 'me.mac' } ], as => [qw/port node_count/],
      group_by => 'me.port' });
  return { map {( $_->get_column('port') => $_->get_column('node_count') )} $rs->all };
}

=head2 device_ports( $schema, $device, %opts )

Every port of C<$device>, in the order the classic tab sorts them, without the
ports C<hide_deviceports> hides unless C<include_hidden> is true.

=cut

sub device_ports {
  my ($schema, $device, %opts) = @_;

  my @rows = _port_rs($device)->order_by_port_name->all;
  unless ($opts{include_hidden}) {
    my $hide = hidden_device_ports($device, \@rows);
    @rows = grep { not exists $hide->{ $_->port } } @rows;
  }

  my $vlans  = _vlans_by_port($schema, $device);
  my $counts = _node_counts_by_port($schema, $device);

  return [ map {
    normalize_port({ $_->get_columns }, {
      vlans => $vlans->{ $_->port }, node_count => $counts->{ $_->port },
    })
  } @rows ];
}

=head2 device_port( $schema, $device, $port )

One port, hidden or not: a client asking for it by name already knows it is
there. Stops the route with a 404 if the device has no such port.

=cut

sub device_port {
  my ($schema, $device, $name) = @_;
  my $row = _port_rs($device)->search({ 'me.port' => $name })->single
    or problem(404, 'Port not found',
         sprintf q{Device %s has no port '%s'.}, $device->ip, $name);

  my $count = $schema->resultset('Node')->search(
    { 'me.switch' => $device->ip, 'me.port' => $name, 'me.active' => 1 })->count;

  return normalize_port({ $row->get_columns }, {
    vlans => _vlans_by_port($schema, $device, $name)->{ $name },
    node_count => $count,
  });
}

=head2 normalize_node( \%node, \@ips )

Pure: a C<node> row's columns (with C<_iso_*> times, C<vendor> and the
C<netbios_*> columns joined in) and its C<node_ip> rows, to the API shape.

=cut

sub normalize_node {
  my ($n, $ips) = @_;
  my $has_nbt = _str($n->{netbios_name});

  return {
    mac           => _str($n->{mac}),
    vlan          => _int($n->{vlan}),
    active        => json_bool($n->{active}),
    vendor        => _str($n->{vendor}),
    first_seen_at => _str($n->{_iso_time_first}),
    last_seen_at  => _str($n->{_iso_time_last}),
    netbios       => ($has_nbt ? {
      name   => _str($n->{netbios_name}),
      domain => _str($n->{netbios_domain}),
      user   => _str($n->{netbios_user}),
    } : undef),
    ips => [ map {{
      ip            => _str($_->{ip}),
      dns           => _str($_->{dns}),
      active        => json_bool($_->{active}),
      first_seen_at => _str($_->{_iso_time_first}),
      last_seen_at  => _str($_->{_iso_time_last}),
    }} sort { ($b->{active} || 0) <=> ($a->{active} || 0) or $a->{ip} cmp $b->{ip} }
       @{ $ips || [] } ],
  };
}

=head2 port_nodes( $schema, $device, $port, %opts )

The nodes seen on one port, most recently seen first: active ones only unless
C<archived> is true, each with its IP addresses (likewise).

=cut

sub port_nodes {
  my ($schema, $device, $port, %opts) = @_;

  $schema->resultset('DevicePort')->find({ ip => $device->ip, port => $port })
    or problem(404, 'Port not found',
         sprintf q{Device %s has no port '%s'.}, $device->ip, $port);

  my $nodes = $schema->resultset('Node')->search({
    'me.switch' => $device->ip,
    'me.port'   => $port,
    ($opts{archived} ? () : ('me.active' => 1)),
  }, {
    join => [qw/manufacturer netbios/],
    '+columns' => {
      vendor          => 'manufacturer.company',
      netbios_name    => 'netbios.nbname',
      netbios_domain  => 'netbios.domain',
      netbios_user    => 'netbios.nbuser',
      _iso_time_first => \iso8601_sql('me.time_first'),
      _iso_time_last  => \iso8601_sql('me.time_last'),
    },
    order_by => [ { -desc => 'me.time_last' }, 'me.mac' ],
  });

  my @rows = map {{ $_->get_columns }} $nodes->all;
  return [] unless @rows;

  my %ips_by_mac = ();
  my $ips = $schema->resultset('NodeIp')->search({
    'me.mac' => { -in => [ map { $_->{mac} } @rows ] },
    ($opts{archived} ? () : ('me.active' => 1)),
  }, {
    '+columns' => {
      _iso_time_first => \iso8601_sql('me.time_first'),
      _iso_time_last  => \iso8601_sql('me.time_last'),
    },
  });
  push @{ $ips_by_mac{ $_->{mac} } }, $_ for map {{ $_->get_columns }} $ips->all;

  return [ map { normalize_node($_, $ips_by_mac{ $_->{mac} }) } @rows ];
}


=head2 ports_overview( \@ports )

Pure: normalized ports summed up for a device's overview: the count in each
status, and the ports that need a look, worst first. A port needs a look when
it is error disabled, blocked by spanning tree, or linked at half duplex
(nearly always a duplex mismatch with what is plugged in).

=cut

my %ATTENTION_RANK = (errdisabled => 0, blocking => 1, half_duplex => 2);

sub ports_overview {
  my $ports = shift || [];
  my %count = map {( $_ => 0 )} qw/up down disabled blocking errdisabled/;
  my @attention = ();

  foreach my $p (@$ports) {
    ++$count{ $p->{status} };
    if ($p->{status} eq 'errdisabled') {
      push @attention, { port => $p->{port}, kind => 'errdisabled',
                         detail => $p->{error_disable_cause}, descr => $p->{name} };
    }
    elsif ($p->{status} eq 'blocking') {
      push @attention, { port => $p->{port}, kind => 'blocking',
                         detail => ($p->{neighbor} ? ($p->{neighbor}{ip} // $p->{neighbor}{id}) : undef),
                         descr => $p->{name} };
    }
    elsif ($p->{status} eq 'up' and ($p->{duplex} // '') eq 'half') {
      push @attention, { port => $p->{port}, kind => 'half_duplex',
                         detail => $p->{speed}, descr => $p->{name} };
    }
  }

  # sorted by kind then in the ports' own order, which is the order given
  my $i = 0;
  my %pos = map {( $_->{port} => $i++ )} @$ports;
  @attention = sort { $ATTENTION_RANK{ $a->{kind} } <=> $ATTENTION_RANK{ $b->{kind} }
                      or $pos{ $a->{port} } <=> $pos{ $b->{port} } } @attention;

  return { total => scalar @$ports, by_status => \%count, attention => \@attention };
}

1;
