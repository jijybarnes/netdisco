#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;

use App::Netdisco::Web::UI::Modern::Shell 'device_tab_for';
use App::Netdisco::Web::Data::Device 'normalize_poe';
use App::Netdisco::Web::Data::Ports 'ports_overview';

# What the modern device page's Overview tab is built from. Pure, so pinned
# without a database (xt/36).

# ---- which tab the device page opens on ----

is device_tab_for('modern', undef), 'overview', 'deviceTabFor__modern_no_tab__opens_overview';
is device_tab_for('modern', ''), 'overview', 'deviceTabFor__modern_empty_tab__opens_overview';
is device_tab_for('classic', undef), 'details', 'deviceTabFor__classic_no_tab__opens_details_as_before';
is device_tab_for('classic', 'overview'), 'details',
  'deviceTabFor__classic_asked_for_overview__opens_details_which_it_has';
is device_tab_for('modern', 'overview'), 'overview', 'deviceTabFor__modern_asked_for_overview__opens_it';
is device_tab_for($_, 'ports'), 'ports', "deviceTabFor__${_}_asked_for_ports__opens_ports"
  for qw/classic modern/;
is device_tab_for(undef, undef), 'details', 'deviceTabFor__no_interface_known__classic_behaviour';

# ---- PoE totals ----

is normalize_poe([]), undef, 'normalizePoe__no_modules__no_poe';
is normalize_poe(undef), undef, 'normalizePoe__nothing_read__no_poe';

is_deeply normalize_poe([
  { power => 370, poe_power_committed => 22.4, poe_power_delivering => 13.26,
    poe_capable_ports => 24, poe_powered_ports => 3, poe_disabled_ports => 1, poe_errored_ports => 0 },
  { power => 370, poe_power_committed => 15.4, poe_power_delivering => undef,
    poe_capable_ports => 24, poe_powered_ports => 1, poe_disabled_ports => 0, poe_errored_ports => 1 },
]), {
  modules => 2, budget_watts => 740, committed_watts => 37.8, delivering_watts => 13.3,
  capable_ports => 48, powered_ports => 4, disabled_ports => 1, errored_ports => 1,
}, 'normalizePoe__two_modules__summed_to_a_tenth_of_a_watt_missing_values_as_zero';

# ---- ports at a glance ----

my @ports = (
  { port => 'Gi1/0/1', status => 'up', duplex => 'full', name => 'desk' },
  { port => 'Gi1/0/2', status => 'up', duplex => 'half', speed => '100 Mbps', name => 'printer' },
  { port => 'Gi1/0/3', status => 'down', duplex => 'half' },
  { port => 'Gi1/0/4', status => 'errdisabled', error_disable_cause => 'bpduguard', name => undef },
  { port => 'Gi1/0/5', status => 'disabled' },
  { port => 'Te1/1/1', status => 'blocking', neighbor => { ip => '10.0.0.3', id => 'x' } },
  { port => 'Gi1/0/6', status => 'errdisabled', error_disable_cause => undef },
);
my $o = ports_overview(\@ports);

is $o->{total}, 7, 'portsOverview__total__every_port';
is_deeply $o->{by_status}, { up => 2, down => 1, disabled => 1, blocking => 1, errdisabled => 2 },
  'portsOverview__by_status__each_status_counted';
is_deeply [ map {"$_->{kind}:$_->{port}"} @{ $o->{attention} } ],
  [ 'errdisabled:Gi1/0/4', 'errdisabled:Gi1/0/6', 'blocking:Te1/1/1', 'half_duplex:Gi1/0/2' ],
  'portsOverview__attention__worst_first_then_in_port_order';
is $o->{attention}[0]{detail}, 'bpduguard', 'portsOverview__errdisabled__carries_its_cause';
is $o->{attention}[2]{detail}, '10.0.0.3', 'portsOverview__blocking__names_the_neighbor';
is $o->{attention}[3]{detail}, '100 Mbps', 'portsOverview__half_duplex__carries_the_speed';
ok !grep({ $_->{port} eq 'Gi1/0/3' } @{ $o->{attention} }),
  'portsOverview__half_duplex_without_link__is_not_a_mismatch';

my $none = ports_overview([]);
is_deeply $none, { total => 0, attention => [],
  by_status => { up => 0, down => 0, disabled => 0, blocking => 0, errdisabled => 0 } },
  'portsOverview__no_ports__zeroes_not_missing_keys';

done_testing;
