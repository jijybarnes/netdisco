#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use JSON::PP ();

use App::Netdisco::Web::UI qw/page_segments nav_for crumbs_for/;
use App::Netdisco::Web::Data::Device qw/normalize_health normalize_counts/;
use App::Netdisco::Web::Data::Ports 'normalize_last_node';
use App::Netdisco::Web::Data::Devices qw/clamp_limit sort_spec normalize_device_row word_conditions DEVICE_SORTS/;

# The modern shell's breadcrumb and rail, the device page's health and counts,
# and the Devices page's list. Pure, so pinned without a database (xt/36).

# ---- where a page is ----

is_deeply [ page_segments('/device', '/') ], ['device'], 'pageSegments__plain_path__its_segments';
is_deeply [ page_segments('/nd/report/duplexmismatch', '/nd') ], [qw/report duplexmismatch/],
  'pageSegments__under_a_base_path__the_base_is_dropped';
is_deeply [ page_segments('/nd/t/branch/device', '/nd') ], ['device'], 'pageSegments__tenant_prefix__is_dropped';
is_deeply [ page_segments('/t/branch', '/') ], [], 'pageSegments__tenant_front_page__no_segments';
is_deeply [ page_segments('/', '/') ], [], 'pageSegments__front_page__no_segments';
is_deeply [ page_segments('/ndx/device', '/nd') ], [qw/ndx device/],
  'pageSegments__base_is_only_a_prefix_of_a_word__not_dropped';

is nav_for([], undef), 'home', 'navFor__front_page__home';
is nav_for(['device'], undef), 'devices', 'navFor__a_device__devices';
is nav_for(['devices'], undef), 'devices', 'navFor__the_list__devices';
is nav_for(['search'], undef), 'devices', 'navFor__a_search__devices';
is nav_for(['report', 'x'], 'reports'), 'reports', 'navFor__a_report__what_the_route_says';
is nav_for(['inventory'], 'inventory'), 'inventory', 'navFor__inventory__what_the_route_says';
is nav_for(['password'], undef), undef, 'navFor__anything_else__nothing_lit';

my %ctx = (
  display_name => 'sw1.example',
  query        => 'aa:bb',
  reports      => { duplexmismatch => { category => 'Port', label => 'Mismatched Duplex' }, plain => { label => 'Plain' } },
  admin_tasks  => { users => { label => 'User Management' } },
);
is_deeply crumbs_for(['device'], \%ctx), [ { label => 'Devices', href => '/devices' }, { label => 'sw1.example' } ],
  'crumbsFor__device__devices_then_its_name';
is_deeply crumbs_for(['device'], { %ctx, display_name => '' }), [], 'crumbsFor__device_without_a_name__none';
is_deeply crumbs_for(['devices'], \%ctx), [ { label => 'Devices' } ], 'crumbsFor__the_list__itself';
is_deeply crumbs_for(['report', 'duplexmismatch'], \%ctx),
  [ { label => 'Reports' }, { label => 'Port' }, { label => 'Mismatched Duplex' } ],
  'crumbsFor__report__reports_its_category_and_its_name_none_a_link';
is_deeply crumbs_for(['report', 'plain'], \%ctx), [ { label => 'Reports' }, { label => 'Plain' } ],
  'crumbsFor__report_without_a_category__no_empty_crumb';
is_deeply crumbs_for(['report', 'nosuch'], \%ctx), [ { label => 'Reports' } ], 'crumbsFor__unknown_report__reports_only';
is_deeply crumbs_for(['admin', 'users'], \%ctx), [ { label => 'Admin' }, { label => 'User Management' } ],
  'crumbsFor__admin_task__admin_and_its_name';
is_deeply crumbs_for(['search'], \%ctx), [ { label => 'Search', href => '/search' }, { label => 'aa:bb' } ],
  'crumbsFor__search__search_and_what_was_asked';
is_deeply crumbs_for(['search'], { %ctx, query => undef }), [ { label => 'Search' } ], 'crumbsFor__empty_search__search_only';
is_deeply crumbs_for([], \%ctx), [], 'crumbsFor__front_page__none';
is_deeply crumbs_for(['statistics'], \%ctx), [], 'crumbsFor__page_with_no_crumbs__none';

# ---- health and counts ----

is_deeply normalize_health(undef), { state => 'ok', deferrals => 0, last_failure_at => undef },
  'normalizeHealth__no_failure_recorded__ok';
is_deeply normalize_health({ deferrals => 3, _iso_last_defer => '2026-10-16T09:00:00+02:00' }),
  { state => 'failing', deferrals => 3, last_failure_at => '2026-10-16T09:00:00+02:00' },
  'normalizeHealth__failures__failing_how_many_and_when';
is_deeply normalize_health({ deferrals => 0, _iso_last_defer => 'x' }), { state => 'ok', deferrals => 0, last_failure_at => undef },
  'normalizeHealth__failures_cleared__ok_and_no_date';
is normalize_health({ deferrals => 'lots' })->{state}, 'ok', 'normalizeHealth__nonsense_count__not_claimed_failing';

is_deeply normalize_counts({ num_ports => '52' }, { addresses => 4, vlans => '3', modules => 11, neighbors => 2 }),
  { ports => 52, addresses => 4, vlans => 3, modules => 11, neighbors => 2 }, 'normalizeCounts__numbers__as_numbers';
is_deeply normalize_counts({}, {}), { ports => 0, addresses => 0, vlans => 0, modules => 0, neighbors => 0 },
  'normalizeCounts__nothing_known__zeroes_not_nulls';

# ---- the last node of a port ----

is normalize_last_node(undef), undef, 'normalizeLastNode__none__null';
is normalize_last_node({ mac => '' }), undef, 'normalizeLastNode__no_mac__null';
is_deeply normalize_last_node({ mac => 'aa:bb', ip => '10.0.0.5', dns => '', vendor => 'Dell', _iso_time_last => 't', port => 'x' }),
  { mac => 'aa:bb', ip => '10.0.0.5', dns => undef, vendor => 'Dell', last_seen_at => 't' },
  'normalizeLastNode__node__its_fields_empty_as_null_nothing_else';

# ---- the list of devices ----

is clamp_limit(undef), 100, 'clampLimit__none__a_hundred';
is clamp_limit('25'), 25, 'clampLimit__asked__given';
is clamp_limit(5000), 1000, 'clampLimit__too_many__a_thousand';
is clamp_limit($_), 100, "clampLimit__${\ (defined $_ ? $_ : 'undef')}__the_default" for ('0', '-3', 'abc', '1e3', '');

is_deeply [ sort_spec('ports', 'desc') ], [ 'ports', 'desc' ], 'sortSpec__offered_key__kept';
is_deeply [ sort_spec('name; DROP TABLE device', 'sideways') ], [ 'name', 'asc' ],
  'sortSpec__anything_else__the_default_never_the_request';
is_deeply [ sort_spec(undef, 'DESC') ], [ 'name', 'desc' ], 'sortSpec__direction__any_case';
is_deeply [ sort keys %{ +DEVICE_SORTS } ], [qw/ip last_discover location model name os ports/],
  'deviceSorts__the_orders_the_api_documents';
ok !grep({ /\?|\$|;/ } map { @$_ } values %{ +DEVICE_SORTS }), 'deviceSorts__fixed_sql_with_nothing_bound';

is_deeply [ word_conditions(undef) ], [], 'wordConditions__nothing__no_condition';
is_deeply [ word_conditions('   ') ], [], 'wordConditions__blank__no_condition';
my @c = word_conditions('sw1  arista');
is scalar @c, 2, 'wordConditions__two_words__two_conditions_all_must_hold';

# what each word is matched as: a LIKE pattern where the word's own % _ and \
# are literal characters
sub patterns_of {
  my $cond = shift;
  my @or = @{ $cond->{-or} };
  my ($host) = grep { ref $_ eq 'REF' } @or;
  my @likes = map { (values %$_)[0]->{-ilike} } grep { ref $_ eq 'HASH' } @or;
  return { host => $$host->[1][1], likes => \@likes, columns => [ map { (keys %$_)[0] } grep { ref $_ eq 'HASH' } @or ] };
}
my $p = patterns_of((word_conditions('50%_\\x'))[0]);
is $p->{likes}[0], '%50\%\_\\\\x%', 'wordConditions__metacharacters__escaped_so_they_match_themselves';
is $p->{host}, '%50\%\_\\\\x%', 'wordConditions__address__matched_with_the_same_pattern';
is_deeply [ sort @{ $p->{columns} } ],
  [ sort qw/me.dns me.name me.model me.vendor me.os me.os_ver me.location me.serial me.description/ ],
  'wordConditions__a_word__looked_for_in_every_documented_field';

my $row = normalize_device_row({
  ip => '10.0.0.1', name => 'sw1', dns => '', vendor => 'arista', model => 'cEOSLab', os => 'EOS', os_ver => '4.32',
  location => undef, num_ports => '52', snmp_comm => 'secret', _iso_last_discover => '2026-10-13T07:53:11+02:00',
  _iso_last_macsuck => undef,
}, 1);
is_deeply $row, {
  ip => '10.0.0.1', name => 'sw1', dns => undef, vendor => 'arista', model => 'cEOSLab', os => 'EOS', os_version => '4.32',
  location => undef, num_ports => 52, last_discover_at => '2026-10-13T07:53:11+02:00', last_macsuck_at => undef,
  health => 'failing',
}, 'normalizeDeviceRow__a_device__the_documented_fields_only';
unlike(JSON::PP->new->encode($row), qr/secret/, 'normalizeDeviceRow__snmp_community__never_appears');
is normalize_device_row({ ip => '10.0.0.2' }, 0)->{health}, 'ok', 'normalizeDeviceRow__no_failure__ok';

done_testing;
