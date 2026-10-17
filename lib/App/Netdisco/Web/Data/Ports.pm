package App::Netdisco::Web::Data::Ports;

use strict;
use warnings;

use JSON::PP ();
use App::Netdisco::Util::Port 'hidden_device_ports';
use App::Netdisco::Web::Data qw/problem json_bool iso8601_sql speed_to_bps/;

use base 'Exporter';
our @EXPORT_OK = qw/
  device_ports device_port port_nodes
  normalize_port normalize_node port_status ports_overview normalize_control normalize_last_node
  normalize_vlan normalize_log_entry device_vlans port_log free_interval
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

=head2 normalize_last_node( \%node )

Pure: the node most recently seen on a port, for the table's column of what is
connected. C<undef> in, C<undef> out.

=cut

sub normalize_last_node {
  my $n = shift;
  return undef unless $n and _str($n->{mac});
  return {
    mac          => _str($n->{mac}),
    ip           => _str($n->{ip}),
    dns          => _str($n->{dns}),
    vendor       => _str($n->{vendor}),
    last_seen_at => _str($n->{_iso_time_last}),
  };
}

=head2 normalize_control( \%allowed, $has_poe )

Pure: what the signed in user may change on one port, as the API shows it.
C<%allowed> holds the three decisions the port control ACLs make: C<service>
(admin status and PoE), C<pvid> (the native VLAN) and C<name> (the name and
description), and C<custom_fields>, the names of the editable custom fields
this port's ACLs let it have. C<undef> in, C<undef> out: a user without port
control is told nothing, rather than a list of refusals.

PoE can only be switched on a port that has a PoE row, and by whoever may
change its admin status, as in the classic tab. A custom field is edited by
whoever may change the name, as there.

=cut

sub normalize_control {
  my ($allowed, $has_poe) = @_;
  return undef unless $allowed;
  my $name = ($allowed->{name} || $allowed->{service}) ? 1 : 0;
  return {
    admin_status  => json_bool($allowed->{service}),
    poe           => json_bool($allowed->{service} and $has_poe),
    native_vlan   => json_bool($allowed->{pvid}),
    name          => json_bool($name),
    custom_fields => ($name ? [ sort @{ $allowed->{custom_fields} || [] } ] : []),
  };
}

=head2 normalize_vlan( \%device_vlan )

Pure: one of a device's VLANs, by number and name. The name is what the device
calls it, or C<undef>: a VLAN with no name is not given its number as one.

=cut

sub normalize_vlan {
  my $v = shift;
  return { vlan => _int($v->{vlan}), name => _str($v->{description}) };
}

=head2 normalize_log_entry( \%device_port_log, \%reasons )

Pure: one entry of a port's control log. C<%reasons> is
C<port_control_reasons>, which gives the reason its text.

=cut

sub normalize_log_entry {
  my ($l, $reasons) = @_;
  my $reason = _str($l->{reason});
  return {
    at           => _str($l->{_iso_creation}),
    user         => _str($l->{username}),
    user_ip      => _str($l->{userip}),
    action       => _str($l->{action}),
    reason       => $reason,
    reason_label => (defined $reason ? (($reasons || {})->{$reason} // $reason) : undef),
    log          => _str($l->{log}),
  };
}

=head2 normalize_port( \%columns, \%extra )

Pure: one port's columns (C<device_port>, plus what L</device_ports> joins in)
to the API shape. C<%extra> carries what comes from other queries: C<vlans>,
the port's VLAN numbers, C<node_count>, its active nodes, C<last_node>, the
most recently seen of them, and C<control>, the port control decisions for the
signed in user (see L</normalize_control>).

=cut

sub normalize_port {
  my ($c, $extra) = @_;
  $extra ||= {};
  my @vlans = sort { $a <=> $b } grep { defined } @{ $extra->{vlans} || [] };

  my $custom = $c->{custom_fields};
  $custom = (eval { JSON::PP->new->decode($custom) } || {})
    if defined $custom and not ref $custom;

  if (ref {} eq ref $custom and $extra->{custom_fields}) {
    my %shown = map {( $_ => 1 )} @{ $extra->{custom_fields} };
    $custom = { map {( $_ => $custom->{$_} )} grep { $shown{$_} } keys %$custom };
  }

  my $has_neighbor = (_str($c->{remote_ip}) or _str($c->{remote_id}));
  my $has_poe = defined $c->{poe_admin} || defined $c->{poe_status};
  my $has_inventory = grep { _str($c->{$_}) } qw/remote_vendor remote_model remote_os_ver remote_serial/;
  my $has_nac = grep { _str($c->{$_}) } qw/pae_authconfig_state pae_authconfig_port_status pae_authsess_user/;

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
      # what the neighbor says it is, over LLDP
      inventory       => ($has_inventory ? {
        vendor     => _str($c->{remote_vendor}),
        model      => _str($c->{remote_model}),
        os_version => _str($c->{remote_os_ver}),
        serial     => _str($c->{remote_serial}),
      } : undef),
    } : undef),

    # 802.1X and MAB, as the port reports them
    nac => ($has_nac ? {
      port_control => _str($c->{pae_authconfig_port_control}),
      state        => _str($c->{pae_authconfig_state}),
      port_status  => _str($c->{pae_authconfig_port_status}),
      user         => _str($c->{pae_authsess_user}),
      is_mab       => json_bool($c->{pae_authsess_mab}),
    } : undef),

    is_free       => (exists $c->{is_free} ? json_bool($c->{is_free}) : undef),
    ssids         => [ sort grep { defined and length } @{ $extra->{ssids} || [] } ],
    last_comment  => _str($extra->{last_comment}),

    node_count    => 0 + ($extra->{node_count} || 0),
    last_node     => normalize_last_node($extra->{last_node}),
    control       => normalize_control($extra->{control}, $has_poe),
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

=head2 free_interval( $age_num, $age_unit )

Pure: how long a port must have been down to count as free, as the classic
tab's sidebar asks it: a number from 1 to 31 and a unit. Anything else is the
classic default, 3 months. Returns C<(num, unit)>.

=cut

sub free_interval {
  my ($num, $unit) = @_;
  $num = 3 unless defined $num and $num =~ m/^\d{1,2}$/ and $num >= 1 and $num <= 31;
  $unit = 'months' unless defined $unit and $unit =~ m/^(?:days|weeks|months|years)$/;
  return (0 + $num, $unit);
}

sub _port_rs {
  my ($device, %opts) = @_;
  my $rs = $device->ports->with_properties->with_custom_fields->with_remote_inventory;
  if ($opts{free}) {
    my ($num, $unit) = @{ $opts{free} };
    $rs = $rs->with_is_free({ age_num => $num, age_unit => $unit });
  }
  return $rs->search({}, {
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

sub _ssids_by_port {
  my ($schema, $device, $only_port) = @_;
  my %by_port = ();
  my $rs = $schema->resultset('DevicePortSsid')->search({
    'me.ip' => $device->ip,
    (defined $only_port ? ('me.port' => $only_port) : ()),
  }, { columns => [qw/port ssid/] });
  push @{ $by_port{ $_->get_column('port') } }, $_->get_column('ssid') for $rs->all;
  return \%by_port;
}

# The newest log entry of each port, as the classic Last Comment column has it,
# in one query rather than one per port.
sub _last_comments_by_port {
  my ($schema, $device, $only_port) = @_;
  my $rows = $schema->storage->dbh_do(sub {
    my (undef, $dbh) = @_;
    $dbh->selectall_arrayref(
      'SELECT DISTINCT ON (port) port, log FROM device_port_log WHERE ip = ?'
      . (defined $only_port ? ' AND port = ?' : '')
      . ' ORDER BY port, creation DESC, id DESC',
      undef, $device->ip, (defined $only_port ? $only_port : ()));
  });
  return { map {( $_->[0] => $_->[1] )} @$rows };
}

sub _node_counts_by_port {
  my ($schema, $device) = @_;
  my $rs = $schema->resultset('Node')->search(
    { 'me.switch' => $device->ip, 'me.active' => 1 },
    { select => [ 'me.port', { count => 'me.mac' } ], as => [qw/port node_count/],
      group_by => 'me.port' });
  return { map {( $_->get_column('port') => $_->get_column('node_count') )} $rs->all };
}

# The node most recently seen on each port, with its latest active address and
# its vendor: what the table shows in its "connected nodes" column. One query
# for the nodes, then one for the addresses of those, not one per port.
sub _last_nodes_by_port {
  my ($schema, $device) = @_;

  my @rows = map {{ $_->get_columns }} $schema->resultset('Node')->search(
    { 'me.switch' => $device->ip, 'me.active' => 1 },
    {
      join => 'manufacturer',
      '+columns' => {
        vendor => 'manufacturer.company',
        _iso_time_last => \iso8601_sql('me.time_last'),
      },
      order_by => [ 'me.port', { -desc => 'me.time_last' }, 'me.mac' ],
    })->all;

  my %first;
  foreach my $r (@rows) { $first{ $r->{port} } ||= $r }
  return {} unless %first;

  my %ip_of;
  my $ips = $schema->resultset('NodeIp')->search(
    { 'me.mac' => { -in => [ map { $_->{mac} } values %first ] }, 'me.active' => 1 },
    { columns => [qw/mac ip dns time_last/], order_by => { -desc => 'me.time_last' } });
  foreach my $i (map {{ $_->get_columns }} $ips->all) { $ip_of{ $i->{mac} } ||= $i }

  foreach my $r (values %first) {
    my $i = $ip_of{ $r->{mac} } or next;
    @$r{qw/ip dns/} = @$i{qw/ip dns/};
  }
  return \%first;
}

=head2 device_ports( $schema, $device, %opts )

Every port of C<$device>, in the order the classic tab sorts them, without the
ports C<hide_deviceports> hides unless C<include_hidden> is true.

C<control>, if given, is a code ref called with each port's row. It returns
the three port control decisions for the signed in user (see
L</normalize_control>), or C<undef> for a user who has no port control. It is
passed in because the decisions need the session, which this module does not
know about. C<custom_fields>, likewise, returns the names of the custom fields
a port may show, and C<free>, C<[num, unit]> (see L</free_interval>), has each
port say whether it is free.

=cut

sub device_ports {
  my ($schema, $device, %opts) = @_;

  my @rows = _port_rs($device, free => $opts{free})->order_by_port_name->all;
  unless ($opts{include_hidden}) {
    my $hide = hidden_device_ports($device, \@rows);
    @rows = grep { not exists $hide->{ $_->port } } @rows;
  }

  my $vlans    = _vlans_by_port($schema, $device);
  my $counts   = _node_counts_by_port($schema, $device);
  my $last     = _last_nodes_by_port($schema, $device);
  my $ssids    = _ssids_by_port($schema, $device);
  my $comments = _last_comments_by_port($schema, $device);

  return [ map {
    normalize_port({ $_->get_columns }, {
      vlans => $vlans->{ $_->port }, node_count => $counts->{ $_->port },
      last_node => $last->{ $_->port },
      ssids => $ssids->{ $_->port }, last_comment => $comments->{ $_->port },
      control => ($opts{control} ? $opts{control}->($_) : undef),
      custom_fields => ($opts{custom_fields} ? $opts{custom_fields}->($_) : undef),
    })
  } @rows ];
}

=head2 device_port( $schema, $device, $port, %opts )

One port, hidden or not: a client asking for it by name already knows it is
there. Stops the route with a 404 if the device has no such port. Takes the
same C<control> option as L</device_ports>.

=cut

sub device_port {
  my ($schema, $device, $name, %opts) = @_;
  my $row = _port_rs($device, free => $opts{free})->search({ 'me.port' => $name })->single
    or problem(404, 'Port not found',
         sprintf q{Device %s has no port '%s'.}, $device->ip, $name);

  my $count = $schema->resultset('Node')->search(
    { 'me.switch' => $device->ip, 'me.port' => $name, 'me.active' => 1 })->count;

  return normalize_port({ $row->get_columns }, {
    vlans => _vlans_by_port($schema, $device, $name)->{ $name },
    node_count => $count,
    last_node => _last_nodes_by_port($schema, $device)->{ $name },
    ssids => _ssids_by_port($schema, $device, $name)->{ $name },
    last_comment => _last_comments_by_port($schema, $device, $name)->{ $name },
    control => ($opts{control} ? $opts{control}->($row) : undef),
    custom_fields => ($opts{custom_fields} ? $opts{custom_fields}->($row) : undef),
  });
}

=head2 device_vlans( $schema, $device )

The VLANs the device knows, in number order, each with its name: what the
port control form offers as a port's native VLAN.

=cut

sub device_vlans {
  my ($schema, $device) = @_;
  return [ map { normalize_vlan({ $_->get_columns }) }
    $schema->resultset('DeviceVlan')->search({ 'me.ip' => $device->ip },
      { columns => [qw/vlan description/], order_by => 'me.vlan' })->all ];
}

=head2 port_log( $schema, $device, $port, %opts )

The newest entries of a port's control log, newest first: at most C<limit>
(25 unless given, at most 200, as many as the classic log shows). C<reasons>
is C<port_control_reasons>.

=cut

sub port_log {
  my ($schema, $device, $port, %opts) = @_;
  my $limit = $opts{limit};
  $limit = 25 unless defined $limit and $limit =~ m/^\d+$/ and $limit > 0;
  $limit = 200 if $limit > 200;

  $schema->resultset('DevicePort')->find({ ip => $device->ip, port => $port })
    or problem(404, 'Port not found',
         sprintf q{Device %s has no port '%s'.}, $device->ip, $port);

  return [ map { normalize_log_entry({ $_->get_columns }, $opts{reasons}) }
    $schema->resultset('DevicePortLog')->search(
      { 'me.ip' => $device->ip, 'me.port' => $port },
      { '+columns' => { _iso_creation => \iso8601_sql('me.creation') },
        order_by => [ { -desc => 'me.creation' }, { -desc => 'me.id' } ],
        rows => $limit })->all ];
}

=head2 normalize_node( \%node, \@ips, \@ssids )

Pure: a C<node> row's columns (with C<_iso_*> times, C<vendor> and the
C<netbios_*> columns joined in), its C<node_ip> rows and the SSIDs it was seen
on as a wireless client, to the API shape.

=cut

sub normalize_node {
  my ($n, $ips, $ssids) = @_;
  my $has_nbt = _str($n->{netbios_name});

  return {
    mac           => _str($n->{mac}),
    vlan          => _int($n->{vlan}),
    active        => json_bool($n->{active}),
    vendor        => _str($n->{vendor}),
    first_seen_at => _str($n->{_iso_time_first}),
    last_seen_at  => _str($n->{_iso_time_last}),
    ssids         => [ sort grep { defined and length } @{ $ssids || [] } ],
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

  my %ssids_by_mac = ();
  my $wireless = $schema->resultset('NodeWireless')->search(
    { 'me.mac' => { -in => [ map { $_->{mac} } @rows ] } }, { columns => [qw/mac ssid/] });
  push @{ $ssids_by_mac{ $_->get_column('mac') } }, $_->get_column('ssid') for $wireless->all;

  return [ map { normalize_node($_, $ips_by_mac{ $_->{mac} }, $ssids_by_mac{ $_->{mac} }) } @rows ];
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
