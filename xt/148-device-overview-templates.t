#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use Template::AutoFilter;
use JSON::PP ();

# The modern device page and its Overview tab, rendered with the overlay in
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
    params => { tab => 'overview', q => '10.0.0.1' },
    settings => { _device_tabs => [
      { tag => 'overview', label => 'Overview', render_if => sub { 1 } },
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
like $page, qr{id="overview_form"[^>]*hx-get="/ajax/content/device/overview"}s,
  'devicePage__overview_tab__loads_through_the_classic_tab_machinery';
like $page, qr{class="nav-link active" id="overview_link"}, 'devicePage__tab_param__marks_that_tab_active';
unlike $page, qr{hidden_link|hidden_form}, 'devicePage__tab_not_rendered__has_neither_link_nor_form';

like $page, qr{nd2-st nd2-st-up nd2-health"[^>]*><i aria-hidden="true"></i>Reachable}, 'devicePage__no_failure__reachable';

my $counted = render('device.tt', { nd2_device => { %$device,
    counts => { ports => 52, addresses => 0, vlans => 6, modules => 14, neighbors => 3 },
    health => { state => 'failing', deferrals => 4, last_failure_at => '2026-10-16T09:00:00+02:00' } },
  display_name => 'sw1', netdisco_device => {},
  settings => { _device_tabs => [ map {{ tag => $_, label => ucfirst, render_if => sub { 1 } }} qw/overview details ports addresses vlans netmap/ ] } });
like $counted, qr{id="ports_link"[^>]*>Ports<span class="nd2-n">52</span></a>}, 'devicePage__tab_counts__ports';
like $counted, qr{id="netmap_link"[^>]*>Netmap<span class="nd2-n">3</span></a>}, 'devicePage__tab_counts__the_neighbors_tab_is_the_netmap';
like $counted, qr{id="addresses_link"[^>]*>Addresses</a>}, 'devicePage__tab_counts__none_at_zero';
like $counted, qr{id="details_link"[^>]*>Details</a>}, 'devicePage__tab_counts__none_for_a_tab_that_lists_nothing';
like $counted, qr{nd2-st-errdisabled nd2-health" title="The backend could not reach this device 4 times in a row, the last on 2026-10-16T09:00:00\+02:00\. See Admin, SNMP Connect Failures\."><i aria-hidden="true"></i>Unreachable},
  'devicePage__failing__unreachable_says_how_often_and_where_to_look';

%roles = ();
unlike render('device.tt', { nd2_device => $device, display_name => 'sw1', netdisco_device => {} }),
  qr{data-nd2-job}, 'devicePage__not_admin__no_poll_buttons';

# the classic page renders no tab whose render_if says no, which is how the
# Overview stays out of it
my $classic = '';
Template::AutoFilter->new({ INCLUDE_PATH => [ 'share/views' ], ANYCASE => 1, ABSOLUTE => 1,
  PRE_CHOMP => 1, AUTO_FILTER => 'html_entity', ENCODING => 'utf8' })
  ->process('device.tt', { settings => { _device_tabs => [
      { tag => 'overview', label => 'Overview', render_if => sub { 0 } },
      { tag => 'details', label => 'Details', render_if => sub { 1 } } ] },
    params => { tab => 'details' }, uri_for => sub { $_[0] }, user_has_role => sub { 0 } }, \$classic);
$Template::Stash::PRIVATE = undef;
unlike $classic, qr{id="overview_link"|id="overview_pane"}, 'classicDevicePage__overview_render_if_false__no_overview_tab';
like $classic, qr{id="details_link"}, 'classicDevicePage__other_tabs__still_there';

# ---- the Overview tab ----

%roles = (admin => 1);
my $quiet = render('ajax/device/overview.tt', { device => $device,
  overview => { total => 5, by_status => { up => 5, down => 0, disabled => 0, blocking => 0, errdisabled => 0 },
                attention => [] } });
like $quiet, qr{<span class="nd2-big">5</span>\s*<span class="nd2-muted">of 5 ports up &middot; 100%},
  'overview__all_up__headline_count_and_share';
like $quiet, qr{Nothing: no port}, 'overview__no_attention__says_so';
like $quiet, qr{This device reports no PoE}, 'overview__no_poe__says_so';
like $quiet, qr{data-nd2-duration="81"}, 'overview__uptime__left_for_the_browser_to_format';
like $quiet, qr{<span>Macsuck</span>\s*<span class="nd2-muted">never</span>}, 'overview__never_polled__never';
is scalar(() = $quiet =~ /data-nd2-job="/g), 3, 'overview__admin__one_run_button_per_poll';
unlike $quiet, qr{nd2-seg-down}, 'overview__zero_count__draws_no_empty_segment';

my $busy = render('ajax/device/overview.tt', {
  device => { %$device, poe => { modules => 1, budget_watts => 370, committed_watts => 37.8,
    delivering_watts => 13.3, capable_ports => 24, powered_ports => 3, disabled_ports => 0, errored_ports => 1 } },
  overview => { total => 4, by_status => { up => 2, down => 0, disabled => 1, blocking => 0, errdisabled => 1 },
    attention => [ { port => 'Gi1/0/4', kind => 'errdisabled', detail => '<script>x</script>', descr => 'desk & co' },
                   { port => 'Gi1/0/2', kind => 'half_duplex', detail => '100 Mbps' } ] },
});
like $busy, qr{aria-label="Up 2, Disabled 1, Err-disabled 1"}, 'overview__meter__has_a_text_equivalent';
like $busy, qr{nd2-st nd2-st-errdisabled"><i aria-hidden="true"></i>Err-disabled <b>1</b>},
  'overview__legend__shape_word_and_count';
like $busy, qr{<span class="nd2-count">2</span>}, 'overview__attention__counted_in_the_heading';
like $busy, qr{is error disabled: &lt;script&gt;x&lt;/script&gt;}, 'overview__attention__escapes_the_cause';
like $busy, qr{desk &amp; co}, 'overview__attention__escapes_the_port_name';
like $busy, qr{href="/device\?f=Gi1/0/4&q=10\.0\.0\.1&tab=ports">Open port}, 'overview__attention__links_to_the_port';
like $busy, qr{runs half duplex at 100 Mbps}, 'overview__half_duplex__says_at_what_speed';
like $busy, qr{13\.3 W</span>\s*<span class="nd2-muted">delivered of 370 W budget}, 'overview__poe__delivered_against_budget';
like $busy, qr{width: 3\.6%}, 'overview__poe__track_filled_to_the_share_delivered';
like $busy, qr{1 in fault}, 'overview__poe__faults_shown';

%roles = ();
unlike render('ajax/device/overview.tt', { device => $device,
  overview => { total => 0, by_status => {}, attention => [] } }), qr{data-nd2-job},
  'overview__not_admin__no_run_buttons';

done_testing;
