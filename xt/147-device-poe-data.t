#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;

use App::Netdisco::Web::UI::Modern::Data::Device 'normalize_poe';

# What the modern device header's PoE figures are built from. Pure, so pinned
# without a database (xt/36).

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

done_testing;
