#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use JSON::PP ();
use Template::AutoFilter;
use File::Spec::Functions qw/catfile updir/;
use FindBin;

use App::Netdisco::Web::PortsModern 'port_column_offer';

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
is scalar(() = $shell =~ /data-chip="/g), 7, 'portsShell__chips__all_seven';
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

# ---- the classic route hands over first ----

# The route reads the database, which a test cannot have (xt/36), so this is a
# source assertion: the hand-over must come before anything the classic route
# does, or a modern browser would pay for the classic query and get its pane.
my $src = do {
  local $/;
  open my $fh, '<', catfile($FindBin::Bin, updir(), qw/lib App Netdisco Web Plugin Device Ports.pm/) or die $!;
  <$fh>;
};
my ($body) = $src =~ m{^get '/ajax/content/device/ports' => require_login sub \{\n(.*?)^\};$}ms;
ok defined $body, 'portsRoute__found_in_the_source';
my ($first) = grep { /\S/ and !/^\s*#/ } split /\n/, ($body // '');
like $first, qr/^\s*return modern_ports_pane\(\) if current_web_ui\(\) eq 'modern';$/,
  'portsRoute__first_statement__hands_a_modern_browser_over';

done_testing;
