#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use JSON::PP ();
use Scalar::Util 'blessed';

use App::Netdisco::Web::Data qw/speed_to_bps layers_list iso8601_sql json_bool/;
use App::Netdisco::Web::Data::Device 'normalize_device';
use App::Netdisco::Web::Data::Ports qw/port_status normalize_port normalize_node normalize_control/;

# The v2 shapes are the contract both the API and the modern interface read,
# so every field is pinned here from plain column hashes: the database is not
# needed to know what a row becomes (and CI has none, see xt/36).

sub is_json_bool { my ($v, $want, $name) = @_;
  ok blessed($v) && $v->isa('JSON::PP::Boolean') && (!!$v == !!$want), $name }

# ---- helpers ----

is speed_to_bps('1.0 Gbps'), 1_000_000_000, 'speedToBps__decimal_gigabits__converts';
is speed_to_bps('100 Mbps'), 100_000_000, 'speedToBps__megabits__converts';
is speed_to_bps('2.5 Gbps'), 2_500_000_000, 'speedToBps__fractional_gigabits__converts';
is speed_to_bps('64 kbps'), 64_000, 'speedToBps__kilobits__converts';
is speed_to_bps('10 bps'), 10, 'speedToBps__bare_bits__converts';
is speed_to_bps($_), undef, "speedToBps__'" . ($_ // 'undef') . "'__is_unknown"
  for (undef, '', 'auto', '1 Gb', 'fast', '1.0 Xbps');

is_deeply layers_list('00001110'), [2, 3, 4], 'layersList__lab_switch__layers_two_to_four';
is_deeply layers_list('00000010'), [2], 'layersList__layer_two_only';
is_deeply layers_list('10000001'), [1, 8], 'layersList__first_and_last_bits__layers_one_and_eight';
is_deeply layers_list($_), [], 'layersList__malformed__is_empty' for (undef, '', '0101', 'abcdefgh');

like iso8601_sql('me.creation'), qr/^to_char\(\(me\.creation\)::timestamptz, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM'\)$/,
  'iso8601Sql__column__renders_with_its_utc_offset';

# ---- port status, in the classic icon's order ----

my %up = (up_admin => 'up', up => 'up');
is port_status({ %up }, 1), 'up', 'portStatus__enabled_and_linked__up';
is port_status({ up_admin => 'down', up => 'up' }), 'disabled', 'portStatus__admin_down__disabled';
is port_status({ up_admin => 'down', up => 'down', error_disable_cause => 'bpduguard' }), 'disabled',
  'portStatus__admin_down_and_errdisabled__admin_down_wins';
is port_status({ %up, stp => 'blocking' }, 1), 'blocking', 'portStatus__stp_blocking_one_vlan__blocking';
is port_status({ %up, stp => 'blocking' }, 2), 'up', 'portStatus__stp_blocking_on_a_trunk__still_up';
is port_status({ up_admin => 'up', up => 'down', error_disable_cause => 'bpduguard' }), 'errdisabled',
  'portStatus__error_disabled__errdisabled';
is port_status({ up_admin => 'up', up => 'down' }), 'down', 'portStatus__enabled_no_link__down';
is port_status({ up_admin => 'up', up => 'lowerLayerDown' }), 'down', 'portStatus__lower_layer_down__down';
is port_status({ up_admin => 'up', up => 'dormant' }), 'up', 'portStatus__dormant__counts_as_up';
is port_status({ up_admin => 'up', up => 'down', error_disable_cause => '' }), 'down',
  'portStatus__empty_errdisable_cause__is_no_cause';
is port_status({}), 'disabled', 'portStatus__no_admin_status__is_not_claimed_up';

# ---- one port ----

my $port = normalize_port({
  ip => '10.0.0.1', port => 'Gi1/0/1', descr => 'GigabitEthernet1/0/1', name => '',
  type => 'ethernetCsmacd', ifindex => '10101', mac => 'aa:bb:cc:dd:ee:ff', mtu => '1500',
  up => 'up', up_admin => 'up', stp => 'forwarding', speed => '1.0 Gbps', speed_admin => 'auto',
  duplex => 'full', duplex_admin => 'auto', vlan => '10', pvid => 10,
  is_uplink => 0, is_master => 0, slave_of => undef, has_subinterfaces => 0,
  last_change_at => '2026-10-13T07:52:12+02:00',
  remote_ip => '', remote_id => undef,
  poe_admin => 'true', poe_status => 'deliveringPower', poe_class => 'class2', poe_power => '6400',
  tags => ['printer'], custom_fields => '{"room":"2.14"}', snmp_comm => 'never-emitted',
}, { vlans => [20, 10], node_count => 2 });

is $port->{port}, 'Gi1/0/1', 'normalizePort__port__is_the_name';
is $port->{name}, undef, 'normalizePort__empty_string__becomes_null';
is $port->{ifindex}, 10101, 'normalizePort__ifindex__is_a_number';
is(JSON::PP->new->encode([ $port->{ifindex}, $port->{mtu} ]), '[10101,1500]',
  'normalizePort__numbers__encode_unquoted');
is $port->{status}, 'up', 'normalizePort__status__is_derived';
is $port->{speed_bps}, 1_000_000_000, 'normalizePort__speed__also_in_bits_per_second';
is $port->{speed_admin}, 'auto', 'normalizePort__speed_admin__kept_as_text';
is $port->{native_vlan}, 10, 'normalizePort__native_vlan__from_the_vlan_column';
is_deeply $port->{vlans}, [10, 20], 'normalizePort__vlans__sorted_numerically';
is $port->{node_count}, 2, 'normalizePort__node_count__from_the_extra';
is_json_bool $port->{is_uplink}, 0, 'normalizePort__is_uplink__json_false';
is_deeply { %{ $port->{poe} }, admin_enabled => !!$port->{poe}{admin_enabled} },
  { admin_enabled => 1, status => 'deliveringPower', class => 'class2', power_mw => 6400 },
  'normalizePort__power_row__poe_object_in_milliwatts';
is $port->{neighbor}, undef, 'normalizePort__no_remote_ip_or_id__no_neighbor';
is_deeply $port->{tags}, ['printer'], 'normalizePort__tags__kept';
is_deeply $port->{custom_fields}, { room => '2.14' }, 'normalizePort__custom_fields_json__decoded';
ok !exists $port->{snmp_comm} && !exists $port->{ip}, 'normalizePort__unlisted_columns__are_not_passed_through';

my $bare = normalize_port({ port => 'Te1/1/1', up => 'down', up_admin => 'up',
  remote_ip => '10.0.0.2', remote_port => 'Te2/0/12', neighbor_device_ip => '10.0.0.2',
  manual_topo => 1, custom_fields => 'not json' });
is $bare->{poe}, undef, 'normalizePort__no_power_row__poe_null';
is $bare->{neighbor}{device_ip}, '10.0.0.2', 'normalizePort__known_neighbor__has_its_device_ip';
is_json_bool $bare->{neighbor}{is_manual}, 1, 'normalizePort__manual_topology__flagged';
is_deeply $bare->{vlans}, [], 'normalizePort__no_vlans__empty_list_not_null';
is $bare->{node_count}, 0, 'normalizePort__no_nodes__zero_not_null';
is_deeply $bare->{custom_fields}, {}, 'normalizePort__unparseable_custom_fields__empty_object';
is $bare->{last_change_at}, undef, 'normalizePort__no_last_change__null';

# the field list is the contract: adding one is fine, losing or renaming one is not
is_deeply [ sort keys %$port ], [ sort qw/
  port descr name type ifindex mac mtu status admin_status oper_status
  error_disable_cause stp_state speed speed_bps speed_admin duplex duplex_admin
  native_vlan pvid vlans is_uplink is_master slave_of has_subinterfaces
  last_change_at poe neighbor node_count control tags custom_fields
/ ], 'normalizePort__fields__are_the_documented_set';

# ---- what the user may change ----

is normalize_control(undef, 1), undef, 'normalizeControl__user_without_port_control__null_not_a_list_of_refusals';
is $port->{control}, undef, 'normalizePort__no_control_given__control_null';

sub flags { my $c = shift; return { map { $_ => ($c->{$_} ? 1 : 0) } sort keys %$c } }
is_deeply flags(normalize_control({ service => 1, pvid => 1, name => 0 }, 1)),
  { admin_status => 1, name => 1, native_vlan => 1, poe => 1 },
  'normalizeControl__service_allowed__also_covers_the_name_and_poe';
is_deeply flags(normalize_control({ service => 1, pvid => 0, name => 0 }, 0)),
  { admin_status => 1, name => 1, native_vlan => 0, poe => 0 },
  'normalizeControl__no_poe_row__poe_not_offered_even_when_service_is_allowed';
is_deeply flags(normalize_control({ service => 0, pvid => 0, name => 1 }, 1)),
  { admin_status => 0, name => 1, native_vlan => 0, poe => 0 },
  'normalizeControl__name_only__poe_needs_the_right_to_switch_the_port';
is_deeply flags(normalize_control({ service => 0, pvid => 1, name => 0 }, 1)),
  { admin_status => 0, name => 0, native_vlan => 1, poe => 0 },
  'normalizeControl__vlan_only__nothing_else_follows';
is_deeply flags(normalize_control({}, 1)), { admin_status => 0, name => 0, native_vlan => 0, poe => 0 },
  'normalizeControl__no_decision__everything_refused';

my $ctl = normalize_port({ port => 'Gi1/0/1', poe_admin => 'true' }, { control => { service => 1 } });
is_json_bool $ctl->{control}{poe}, 1, 'normalizePort__control_and_a_poe_row__poe_offered';
is_json_bool normalize_port({ port => 'Gi1/0/1' }, { control => { service => 1 } })->{control}{poe}, 0,
  'normalizePort__control_without_a_poe_row__poe_not_offered';

# ---- one device ----

my $device = normalize_device({
  ip => '10.0.0.1', dns => 'sw1.example', name => 'sw1', description => 'Arista EOS',
  vendor => 'arista', model => 'cEOSLab', os => 'EOS', os_ver => '4.32', serial => 'X1',
  chassis_id => '', mac => 'aa:bb', location => undef, contact => 'noc',
  layers => '00001110', uptime => '8328', num_ports => '4', is_pseudo => 0,
  snmp_class => 'SNMP::Info::Layer3::Arista', snmp_ver => '2', snmp_engineid => 'f571',
  snmp_comm => 'secret-community',
  _iso_creation => '2026-10-13T07:53:12+02:00', _iso_last_discover => '2026-10-13T07:53:11+02:00',
  _iso_last_macsuck => undef, _iso_last_arpnip => '',
  tags => [], custom_fields => {},
});

is $device->{os_version}, '4.32', 'normalizeDevice__os_ver__renamed_os_version';
is $device->{uptime_seconds}, 83, 'normalizeDevice__uptime_ticks__whole_seconds';
is_deeply $device->{layers}, [2, 3, 4], 'normalizeDevice__layers__as_numbers';
is $device->{chassis_id}, undef, 'normalizeDevice__empty_string__null';
is $device->{first_seen_at}, '2026-10-13T07:53:12+02:00', 'normalizeDevice__creation__first_seen_at';
is $device->{last_macsuck_at}, undef, 'normalizeDevice__never_macsucked__null';
is $device->{last_arpnip_at}, undef, 'normalizeDevice__empty_time__null';
is $device->{snmp}{version}, 2, 'normalizeDevice__snmp_version__a_number';
is_json_bool $device->{is_pseudo}, 0, 'normalizeDevice__is_pseudo__json_false';
unlike(JSON::PP->new->encode($device), qr/secret-community/,
  'normalizeDevice__snmp_community__never_appears');

# device_summary adds poe (normalize_poe) to these
is_deeply [ sort keys %$device ], [ sort qw/
  ip dns name description vendor model os os_version serial chassis_id mac
  location contact layers uptime_seconds num_ports is_pseudo snmp
  first_seen_at last_discover_at last_macsuck_at last_arpnip_at tags custom_fields
/ ], 'normalizeDevice__fields__are_the_documented_set';

# ---- one node ----

my $node = normalize_node(
  { mac => 'aa:c1:ab:06:a5:a4', vlan => '10', active => 1, vendor => 'Dell',
    _iso_time_first => '2026-10-13T07:53:15+02:00', _iso_time_last => '2026-10-13T08:20:00+02:00',
    netbios_name => undef },
  [ { ip => '10.10.10.12', dns => undef, active => 0 },
    { ip => '10.10.10.11', dns => 'h1.lab', active => 1 },
    { ip => '10.10.10.10', dns => '', active => 1 } ],
);
is $node->{vlan}, 10, 'normalizeNode__vlan__a_number';
is $node->{netbios}, undef, 'normalizeNode__no_netbios__null';
is_deeply [ map { $_->{ip} } @{ $node->{ips} } ], [qw/10.10.10.10 10.10.10.11 10.10.10.12/],
  'normalizeNode__ips__active_first_then_by_address';
is $node->{ips}[0]{dns}, undef, 'normalizeNode__empty_dns__null';
is $node->{last_seen_at}, '2026-10-13T08:20:00+02:00', 'normalizeNode__time_last__last_seen_at';

is_json_bool json_bool('0'), 0, 'jsonBool__string_zero__false';
is_json_bool json_bool('t'), 1, 'jsonBool__true_value__true';

done_testing;
