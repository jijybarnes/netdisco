#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;

# Needs no database and no session: _deferred_node_params is free of
# param(), so this and the assertions below that call it directly belong
# outside any SKIP block, alongside xt/54's own param-free checks.
require App::Netdisco::Web::Plugin::Device::Ports;

# The deferred block itself, its attributes and where _deferred_node_params
# lands in its hx-get, is drawn by netdisco-ports.js now, and checked in
# xt/js/ports-table.test.js. What stays here is the querystring, which is
# built in Perl.

# Called directly, so that a regression inside the function (deleting its
# mac_format branch entirely, for instance) is caught here.
my $qs_some = App::Netdisco::Web::Plugin::Device::Ports::_deferred_node_params(
  1, 0, 1, 0, 1, 0, 0, 0, 'Cisco');
like $qs_some, qr/&n_ip4=1/,  'n_ip4 on is carried';
like $qs_some, qr/&n_dns=1/,  'n_dns on is carried';
like $qs_some, qr/&n_ssid=1/, 'n_ssid on is carried';
like $qs_some, qr/&mac_format=Cisco/, 'mac_format is carried';

for my $mac_format (undef, '') {
    my $qs_no_mac = App::Netdisco::Web::Plugin::Device::Ports::_deferred_node_params(
      1, 1, 1, 1, 1, 1, 1, 1, $mac_format);
    unlike $qs_no_mac, qr/mac_format/,
      'a ' . (defined $mac_format ? 'empty' : 'undef')
      . ' mac_format is omitted, not emitted empty';
}

# Every option carried when true, not just the ones the calls above happen
# to set truthy: one all-true call, checked in a loop over all eight, so a
# regression in any single option's line is caught rather than assumed
# covered by a different assertion's incidental truthy value.
my $qs_all = App::Netdisco::Web::Plugin::Device::Ports::_deferred_node_params(
  1, 1, 1, 1, 1, 1, 1, 1, 'IEEE');
for my $option (qw/n_ip4 n_ip6 n_dns n_age n_ssid n_vendor n_netbios n_archived/) {
    like $qs_all, qr/&\Q$option\E=1/, "$option on is carried";
}

# Truthiness as Perl itself defines it, not as HTML checkboxes happen to
# submit it: 'on' and 'off' are both non-empty strings, so both are true;
# only '0', '', and undef are false. The deferred fetch has to agree with
# every other truthiness check in Ports.pm's route handler, where param()
# results are used the same bare way, or its markup stops matching the
# eager path's.
my $qs_truthy = App::Netdisco::Web::Plugin::Device::Ports::_deferred_node_params(
  'on', 0, 1, '', 'off', '0', undef, 1, undef);
like   $qs_truthy, qr/&n_ip4=1/,     'a truthy string ("on") is carried';
unlike $qs_truthy, qr/&n_ip6=1/,     'the number 0 is not carried';
like   $qs_truthy, qr/&n_dns=1/,     'the number 1 is carried';
unlike $qs_truthy, qr/&n_age=1/,     'an empty string is not carried';
like   $qs_truthy, qr/&n_ssid=1/,    'the string "off" is still true and is carried';
unlike $qs_truthy, qr/&n_vendor=1/,  'the string "0" is not carried';
unlike $qs_truthy, qr/&n_netbios=1/, 'undef is not carried';
like   $qs_truthy, qr/&n_archived=1/, 'a truthy number (1) is carried';
is scalar(() = $qs_truthy =~ /&n_ip4=1/g), 1, 'a carried option appears exactly once';

done_testing;
