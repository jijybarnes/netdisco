#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use JSON::PP ();
use Template::AutoFilter;
use File::Spec::Functions qw/catfile updir/;
use FindBin;

use App::Netdisco::Web::UI::Modern::Ports qw/port_column_offer port_view_defaults short_device_name/;

# The modern Ports tab: the classic route hands over to it, it renders a shell
# that ports.js fills from API v2, and it writes the CSV download itself.

# ---- the columns offered to the browser ----

my $offer = port_column_offer([
  { name => 'c_admin', label => 'Port Control and Editing', default => undef, idx => 0 },
  { name => 'c_port', label => 'Port', default => 'checked', idx => 1 },
  { name => 'c_xt_plugin', default => 'checked', idx => 2 },
  { label => 'nameless', default => 'checked' },
]);
is_deeply [ map { $_->{name} } @$offer ], [qw/c_admin c_port c_xt_plugin/],
  'portColumnOffer__site_columns__kept_in_their_order_nameless_dropped';
is $offer->[2]{label}, 'c_xt_plugin', 'portColumnOffer__no_label__falls_back_to_the_name';
is(JSON::PP->new->canonical->encode([ map { $_->{default} } @$offer ]), '[false,true,true]',
  'portColumnOffer__defaults__json_booleans_from_the_checked_convention');
ok !grep({ exists $_->{custom} } @$offer), 'portColumnOffer__ordinary_columns__not_marked_custom';

my $cf = port_column_offer([
  { name => 'room', label => 'Room', field => 'cf_room', editable => 1, position => 'right' },
  { name => 'asset', label => 'Asset', field => 'cf_asset' },
]);
is(JSON::PP->new->canonical->encode([ map {[ $_->{custom}, $_->{editable} ]} @$cf ]), '[[true,true],[true,false]]',
  'portColumnOffer__custom_field__marked_and_whether_it_may_be_edited');

# ---- the View menu's defaults ----

is(JSON::PP->new->canonical->encode(port_view_defaults({
  p_fold_subinterfaces => { default => undef }, p_vlan_names => { default => 'checked' }, p_hide1002 => { default => undef },
  mac_format => { default => 'Cisco' }, age_num => { default => 2 }, age_unit => { default => 'weeks' },
})), '{"foldSubinterfaces":false,"freeAge":2,"freeUnit":"weeks","hide1002":false,"macFormat":"Cisco","vlanNames":true}',
  'portViewDefaults__sidebar_defaults__under_the_names_the_tab_keeps');
is(JSON::PP->new->canonical->encode(port_view_defaults(undef)),
  '{"foldSubinterfaces":false,"freeAge":3,"freeUnit":"months","hide1002":false,"macFormat":"IEEE","vlanNames":false}',
  'portViewDefaults__nothing_configured__the_classic_defaults');

is short_device_name('sw-bat-a-01.corp.lan'), 'sw-bat-a-01', 'shortDeviceName__host_name__without_the_domain';
is short_device_name('172.20.20.12'), '172.20.20.12', 'shortDeviceName__ipv4__whole';
is short_device_name('fe80::1'), 'fe80::1', 'shortDeviceName__ipv6__whole';

# ---- the shell, the sidebar, the CSV ----

sub engine {
  my $filter = shift;
  my $tt = Template::AutoFilter->new({
    INCLUDE_PATH => [ 'share/views-modern', 'share/views' ], ANYCASE => 1, ABSOLUTE => 1,
    PRE_CHOMP => 1, AUTO_FILTER => $filter, ENCODING => 'utf8',
    PLUGINS => { csv => 'App::Netdisco::Template::Plugin::CSV' },
  }) or die Template->error;
  return $tt;
}

my $tt = engine('html_entity');
my $shell = '';
$tt->process('ajax/device/ports.tt', {
  uri_base    => '/nd',
  device_ip   => 'fe80::1',
  device_name => 'sw <1>',
  view_defaults => '{"macFormat":"<b>"}',
  model       => 'C9300-48P <x>',
  port_filter => '"><script>alert(1)</script>',
  columns     => JSON::PP->new->canonical->encode([ { name => 'c_port', label => 'Port <b>', default => JSON::PP::true } ]),
  reasons     => JSON::PP->new->canonical->encode([ { value => 'other', label => 'Other "x"' } ]),
}, \$shell) or die $tt->error;

like $shell, qr{data-nd2-src="/nd/ajax/data/v2/devices/fe80%3A%3A1/ports"},
  'portsShell__device__its_v2_ports_under_the_site_base_the_address_escaped';
like $shell, qr{data-nd2-filter="&quot;&gt;&lt;script&gt;alert\(1\)&lt;/script&gt;"},
  'portsShell__filter__escaped_into_its_attribute';
like $shell, qr{data-nd2-columns="\[\{&quot;default&quot;:true,&quot;label&quot;:&quot;Port &lt;b&gt;&quot;},
  'portsShell__columns__json_escaped_into_its_attribute';
is scalar(() = $shell =~ /data-chip="/g), 8, 'portsShell__chips__all_eight';
like $shell, qr{data-chip="free"}, 'portsShell__chips__free_ports_among_them';
like $shell, qr{data-nd2-device-name="sw &lt;1&gt;"}, 'portsShell__device_name__escaped_for_the_drawer';
like $shell, qr{data-nd2-view="\{&quot;macFormat&quot;:&quot;&lt;b&gt;&quot;\}"}, 'portsShell__view_defaults__escaped_into_their_attribute';
is scalar(() = $shell =~ /data-nd2-view="(?:foldSubinterfaces|vlanNames|hide1002|macFormat|freeAge|freeUnit)"/g), 6,
  'portsShell__view_menu__every_classic_display_option';
like $shell, qr{class="nd2-ports-hidden"}, 'portsShell__view_menu__hidden_ports_too';
like $shell, qr{data-nd2-model="C9300-48P &lt;x&gt;"}, 'portsShell__model__escaped_for_the_panel_label';
like $shell, qr{data-nd2-api="/nd/ajax/data/v2"}, 'portsShell__api_base__under_the_site_base_for_the_drawers_nodes';
like $shell, qr{data-nd2-device="fe80::1"}, 'portsShell__device__for_the_drawers_requests';
is(($shell =~ m{data-nd2-reasons="([^"]*)"})[0],
  '[{&quot;label&quot;:&quot;Other \\&quot;x\\&quot;&quot;,&quot;value&quot;:&quot;other&quot;}]',
  'portsShell__reasons__json_escaped_into_their_attribute_a_quote_in_a_label_cannot_end_it');
like $shell, qr{data-mode="status" aria-pressed="true"}, 'portsShell__panel__opens_on_status';

my $sidebar = '';
$tt->process('sidebar/device/ports.tt', { params => { q => '10.0.0.1', f => 'Gi1/0/4' } }, \$sidebar)
  or die $tt->error;
like $sidebar, qr{name="q" value="10\.0\.0\.1"}, 'portsSidebar__keeps_q_for_the_pane';
like $sidebar, qr{name="f" value="Gi1/0/4"}, 'portsSidebar__keeps_f_for_the_pane';
like $sidebar, qr{data-nd-has-sidebar="ports" value="0"}, 'portsSidebar__declares_no_sidebar';
unlike $sidebar, qr{port_state|c_port}, 'portsSidebar__carries_none_of_the_classic_options';

my $csv = '';
engine('none')->process('ajax/device/ports_csv.tt', { ports => [
  { port => 'Gi1/0/1', status => 'up', name => '=HYPERLINK("http://x")', descr => 'GigabitEthernet1/0/1',
    type => 'ethernetCsmacd', speed => '1.0 Gbps', duplex => 'full', native_vlan => 10, vlans => [10, 20],
    poe => { power_mw => 6400 }, node_count => 2, neighbor => undef, last_change_at => undef, mac => 'aa:bb', mtu => 1500 },
  { port => 'Te1/1/1', status => 'blocking', vlans => [], poe => undef, node_count => 0,
    neighbor => { ip => '10.0.0.2', port => 'Te2/0/12', dns => undef, id => 'core-b' } },
] }, \$csv) or die engine('none')->error;
my @lines = grep { length } split /\n/, $csv;
is scalar @lines, 3, 'portsCsv__two_ports__a_header_and_a_line_each';
like $lines[0], qr/^Port,Status,Name,Description/, 'portsCsv__header__first';
like $lines[1], qr/^Gi1\/0\/1,up,"'=HYPERLINK/, 'portsCsv__formula_in_a_value__neutralized';
like $lines[1], qr/,"10 20",6400,2,/, 'portsCsv__vlans_poe_and_nodes__as_values';
like $lines[2], qr/^Te1\/1\/1,blocking,.*,10\.0\.0\.2,Te2\/0\/12,core-b,/,
  'portsCsv__neighbor_without_dns__named_by_its_id';

# ---- the modern route goes in front of the classic one ----

# The routes read the database, which a test cannot have (xt/36), so these are
# source assertions; xt/156 checks the mechanism itself, request by request.
# The classic route is the interface's business no more than any other core
# route: it must not know there is one.
sub source_of {
  local $/;
  open my $fh, '<', catfile($FindBin::Bin, updir(), 'lib', @_) or die $!;
  return scalar <$fh>;
}
my $classic = source_of(qw/App Netdisco Web Plugin Device Ports.pm/);
unlike $classic, qr/modern|current_web_ui|App::Netdisco::Web::UI/,
  'portsRoute__classic__knows_no_web_interface';

# The modern one is the same path, signed in as the classic one is, and its
# first statement hands any other interface's request on, before it does
# anything of its own: a classic browser must not pay for the modern pane.
my $modern = source_of(qw/App Netdisco Web UI Modern Ports.pm/);
my ($body) = $modern =~ m{^get '/ajax/content/device/ports' => require_login sub \{\n(.*?)^\};$}ms;
ok defined $body, 'portsRoute__modern__registered_for_the_same_path';
my ($first) = grep { /\S/ and !/^\s*#/ } split /\n/, ($body // '');
like $first, qr/^\s*pass unless current_web_ui\(\) eq 'modern';$/,
  'portsRoute__modern_first_statement__passes_any_other_interface_on';

done_testing;
