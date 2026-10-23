#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;

use App::Netdisco::Web::UI::Modern::Data::Search qw/classify_query like_pattern normalize_node_hit/;
use App::Netdisco::Web::UI::Modern::Shell 'palette_index';

# The command palette: what GET /ajax/data/v2/search takes the typed text to be, and
# what the palette offers without asking the server, which is what the core
# and the web plugins registered. Pure, so pinned without a database (xt/36).

# ---- what the text can be ----

my %mac = (mac => 'aa:bb:cc:0d:0e:0f');
is classify_query($_)->{mac}, $mac{mac}, "classifyQuery__mac_${_}__canonical"
  for 'aa:bb:cc:0d:0e:0f', 'AA-BB-CC-0D-0E-0F', 'aabb.cc0d.0e0f', 'aabbcc0d0e0f', '  aa:bb:cc:0d:0e:0f ';
is classify_query($_)->{mac}, undef, "classifyQuery__not_a_mac_${_}__none"
  for 'aa:bb:cc:0d:0e', 'aa:bb-cc:0d:0e:0f', 'gg:bb:cc:0d:0e:0f', 'aabb.cc0d', 'sw1';

is classify_query('10.1.2.3')->{ip}, '10.1.2.3', 'classifyQuery__ipv4__the_address';
is classify_query('010.001.002.003')->{ip}, '10.1.2.3', 'classifyQuery__ipv4_leading_zeros__as_postgres_reads_it';
is classify_query('10.1.2.256')->{ip}, undef, 'classifyQuery__octet_too_big__not_an_address';
is classify_query('10.1.2')->{ip}, undef, 'classifyQuery__three_octets__not_an_address';
is classify_query('FE80::1')->{ip}, 'fe80::1', 'classifyQuery__ipv6__lowercased';
is classify_query('aa:bb:cc:dd:ee:ff')->{ip}, undef, 'classifyQuery__mac__not_taken_for_ipv6';

is classify_query('40')->{vlan}, 40, 'classifyQuery__number__a_vlan';
is classify_query($_)->{vlan}, undef, "classifyQuery__${_}__not_a_vlan" for '0', '4095', '12345', '4a';

is classify_query('a')->{words}, 0, 'classifyQuery__one_character__too_little_to_look_for_in_names';
is classify_query('ab')->{words}, 1, 'classifyQuery__two_characters__looked_for';
is classify_query(undef)->{text}, '', 'classifyQuery__nothing__empty_text';
is length(classify_query('x' x 500)->{text}), 200, 'classifyQuery__very_long__cut';

is like_pattern('50%_\\x'), '%50\\%\\_\\\\x%', 'likePattern__metacharacters__taken_literally';

# ---- a node found ----

is_deeply normalize_node_hit(
  { mac => 'aa:bb', switch => '10.0.0.1', port => 'Gi1/0/5', vendor => 'Dell', vlan => '20', active => 1,
    _iso_time_last => '2026-10-17T09:00:00+02:00', oui => 'x' },
  { ip => '10.1.1.5', dns => 'pc5.lab' }, { dns => '', name => 'sw1' }),
  { mac => 'aa:bb', ip => '10.1.1.5', dns => 'pc5.lab', vendor => 'Dell', device_ip => '10.0.0.1',
    device_name => 'sw1', port => 'Gi1/0/5', vlan => 20, active => JSON::PP::true(), last_seen_at => '2026-10-17T09:00:00+02:00' },
  'normalizeNodeHit__node__where_and_as_what_nothing_else';
my $bare = normalize_node_hit({ mac => 'aa:bb' });
is_deeply [ @$bare{qw/ip device_ip vlan/} ], [ undef, undef, undef ], 'normalizeNodeHit__address_only__the_rest_null';

# ---- what the palette offers without asking ----

my %registry = (
  navbar_items => [ { tag => 'inventory', path => '/inventory', label => 'Inventory' },
                    { tag => 'xtphones', path => '/xtphones', label => 'Phones', icon => 'fa-phone' } ],
  report_order => [qw/Device Port/],
  reports_menu => { Device => ['devmissing'], Port => [qw/duplexmismatch hiddenone/] },
  reports      => { devmissing => { label => 'Missing Model' }, duplexmismatch => { label => 'Mismatched Duplex' },
                    hiddenone => { label => 'Hidden', hidden => 1 } },
  admin_order  => [qw/jobqueue divider users xtnoc/],
  admin_tasks  => { jobqueue => { label => 'Job Queue' }, users => { label => 'User Management' },
                    xtnoc => { label => 'NOC Task', roles => ['noc'] } },
  search_tabs  => [ { tag => 'node', label => 'Node' }, { tag => 'xtsearch', label => 'Plugin Search' }, { tag => 'gone', label => 'Gone', hidden => 1 } ],
);

my $admin = palette_index(\%registry, sub { grep { $_ eq 'admin' } @{ $_[0] } });
my $user  = palette_index(\%registry, sub { 0 });
my $noc   = palette_index(\%registry, sub { grep { $_ eq 'noc' } @{ $_[0] } });
my $labels = sub { [ map { $_->{label} } grep { $_->{group} eq $_[1] } @{ $_[0]{items} } ] };

is_deeply $labels->($admin, 'Pages'), [qw/Home Devices Inventory Phones/], 'paletteIndex__pages__the_core_then_every_navbar_item';
is( (grep { $_->{label} eq 'Phones' } @{ $admin->{items} })[0]{icon}, 'fa-phone', 'paletteIndex__navbar_item__keeps_its_icon');
is_deeply $labels->($admin, 'Reports'), [ 'Missing Model', 'Mismatched Duplex' ], 'paletteIndex__reports__in_menu_order_hidden_ones_left_out';
is( (grep { $_->{label} eq 'Mismatched Duplex' } @{ $admin->{items} })[0]{href}, '/report/duplexmismatch?firstsearch=on',
  'paletteIndex__report__opened_as_the_menu_opens_it');
is_deeply $labels->($admin, 'Admin'), [ 'Job Queue', 'User Management', 'NOC Task' ], 'paletteIndex__admin__every_task_no_divider';
is_deeply $labels->($user, 'Admin'), [], 'paletteIndex__no_role__no_task';
is_deeply $labels->($noc, 'Admin'), [ 'NOC Task' ], 'paletteIndex__task_with_roles__offered_to_who_has_one';
is_deeply [ map { $_->{tag} } @{ $admin->{search_tabs} } ], [qw/node xtsearch/], 'paletteIndex__search_tabs__plugin_ones_too_hidden_left_out';
is_deeply palette_index({}, undef)->{search_tabs}, [], 'paletteIndex__nothing_registered__still_the_core_pages';

done_testing;
