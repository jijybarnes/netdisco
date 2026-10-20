#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use Template::AutoFilter;
use JSON::PP ();

# The modern device page, rendered with the overlay in
# front of share/views as the app arranges it (see xt/143 for why directly).

my $tt = Template::AutoFilter->new({
  INCLUDE_PATH => [ 'share/views-modern', 'share/views' ],
  ANYCASE => 1, ABSOLUTE => 1, PRE_CHOMP => 1,
  AUTO_FILTER => 'html_entity', ENCODING => 'utf8',
}) or die Template->error;
# after new(), which loads Template::Stash and resets it (see xt/143)
$Template::Stash::PRIVATE = undef;

my %roles;
sub render {
  my ($view, $extra) = @_;
  my $out = '';
  $tt->process($view, {
    uri_for => sub { my ($p, $q) = @_; $q ? "$p?" . join('&', map {"$_=$q->{$_}"} sort keys %$q) : $p },
    user_has_role => sub { $roles{ $_[0] } },
    params => { tab => 'details', q => '10.0.0.1' },
    settings => { _device_tabs => [
      { tag => 'details',  label => 'Details',  render_if => sub { 1 } },
      { tag => 'hidden',   label => 'Hidden',   render_if => sub { 0 } },
    ] },
    %$extra,
  }, \$out) or die $tt->error;
  return $out;
}

my $device = {
  ip => '10.0.0.1', name => 'sw1', dns => 'sw1.example', vendor => 'arista', model => 'cEOSLab',
  os => 'EOS', os_version => '4.32', serial => 'X1', location => 'DC1 <rack 3>', contact => undef,
  layers => [2, 3], uptime_seconds => 81, snmp => { version => 2, class => 'SNMP::Info::Layer3::Arista' },
  last_discover_at => '2026-10-13T07:53:10+02:00', last_macsuck_at => undef, last_arpnip_at => '2026-10-13T07:53:13+02:00',
  poe => undef,
};

# ---- the page ----

%roles = (admin => 1);
my $page = render('device.tt', { nd2_device => $device, display_name => 'sw1.example',
                                 netdisco_device => { is_pseudo => 0 } });

like $page, qr{<h1>\s*sw1\.example}, 'devicePage__header__names_the_device';
like $page, qr{arista cEOSLab}, 'devicePage__header__vendor_and_model_with_a_space';
like $page, qr{DC1 &lt;rack 3&gt;}, 'devicePage__header__escapes_the_location';
like $page, qr{<time datetime="2026-10-13T07:53:10\+02:00" data-nd2-relative>},
  'devicePage__header__last_discover_as_a_machine_readable_time';
like $page, qr{data-nd2-device="10\.0\.0\.1".*data-nd2-job="discover"}s, 'devicePage__admin__gets_the_poll_buttons';
like $page, qr{id="details_form"[^>]*hx-get="/ajax/content/device/details"}s,
  'devicePage__details_tab__loads_through_the_classic_tab_machinery';
like $page, qr{class="nav-link active" id="details_link"}, 'devicePage__tab_param__marks_that_tab_active';
unlike $page, qr{hidden_link|hidden_form}, 'devicePage__tab_not_rendered__has_neither_link_nor_form';

like $page, qr{nd2-st nd2-st-up nd2-health"[^>]*><i aria-hidden="true"></i>Reachable}, 'devicePage__no_failure__reachable';

my $counted = render('device.tt', { nd2_device => { %$device,
    counts => { ports => 52, addresses => 0, vlans => 6, modules => 14, neighbors => 3 },
    health => { state => 'failing', deferrals => 4, last_failure_at => '2026-10-16T09:00:00+02:00' } },
  display_name => 'sw1', netdisco_device => {},
  settings => { _device_tabs => [ map {{ tag => $_, label => ucfirst, render_if => sub { 1 } }} qw/details ports addresses vlans netmap/ ] } });
like $counted, qr{id="ports_link"[^>]*>Ports<span class="nd2-n">52</span></a>}, 'devicePage__tab_counts__ports';
like $counted, qr{id="netmap_link"[^>]*>Netmap<span class="nd2-n">3</span></a>}, 'devicePage__tab_counts__the_neighbors_tab_is_the_netmap';
like $counted, qr{id="addresses_link"[^>]*>Addresses</a>}, 'devicePage__tab_counts__none_at_zero';
like $counted, qr{id="details_link"[^>]*>Details</a>}, 'devicePage__tab_counts__none_for_a_tab_that_lists_nothing';
like $counted, qr{nd2-st-errdisabled nd2-health" title="The backend could not reach this device 4 times in a row, the last on 2026-10-16T09:00:00\+02:00\. See Admin, SNMP Connect Failures\."><i aria-hidden="true"></i>Unreachable},
  'devicePage__failing__unreachable_says_how_often_and_where_to_look';

%roles = ();
unlike render('device.tt', { nd2_device => $device, display_name => 'sw1', netdisco_device => {} }),
  qr{data-nd2-job}, 'devicePage__not_admin__no_poll_buttons';

done_testing;
