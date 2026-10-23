#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Temp ();
use File::Path 'make_path';
use File::Spec::Functions 'catfile';
use Template::AutoFilter;

use App::Netdisco::Web::UI::Modern::Data::Summary 'normalize_statistics';

# The modern Details and Modules tabs and the modern home page. Their routes
# are the classic ones, and so are the scripts that drive them (netdisco.js,
# netdisco-portcontrol.js): what is pinned is that every hook those scripts
# find their way by is still drawn, and that a plugin's device details are
# drawn with its own template. Rendered directly, without a database (xt/36).

my $plugins = File::Temp->newdir(CLEANUP => 1);
make_path(catfile("$plugins", 'plugin', 'xtdetail'));
open my $fh, '>', catfile("$plugins", 'plugin', 'xtdetail', 'device_details.tt') or die $!;
print $fh qq{<b class="xt-detail">[% d.ip %]:[% config.label %]</b>};
close $fh;

my $tt = Template::AutoFilter->new({
  INCLUDE_PATH => [ "$plugins", 'share/views-modern', 'share/views' ], ANYCASE => 1, ABSOLUTE => 1,
  PRE_CHOMP => 1, AUTO_FILTER => 'html_entity', ENCODING => 'utf8',
}) or die Template->error;
$Template::Stash::PRIVATE = undef;

sub render {
  my ($name, $vars) = @_;
  my $out = '';
  $tt->process($name, $vars, \$out) or die $tt->error;
  return $out;
}

# ---- Details ----

my %roles;
my %details = (
  d => { ip => '10.0.0.1', name => 'sw1', location => 'B<12>', contact => '', dns => 'sw1.lab',
         vendor => 'arista', model => 'cEOS', os => 'EOS', os_ver => '4.32', serial => 'S1', layers => '00000110',
         is_discoverable => 1, is_arpnipable => 0, is_macsuckable => 1, cf_asset => ['A-1'], cf_room => ['R1'] },
  p => [], interfaces => [ { alias => '10.0.0.2', dns => 'lo1' } ], has_snapshot => 0,
  filtered_tags => ['core'], serials => ['S1'],
  search_device => '/search?tab=device',
  uri_for => sub { $_[0] },
  user_has_role => sub { $roles{ $_[0] } },
  permitted_by_acl => sub { not $_[1]{only} },
  settings => {
    _extra_device_details => [
      { name => 'xtdetail', label => 'Plugin <Detail>', field => 'cf_xtdetail' },
      { name => 'asset', label => 'Asset', field => 'cf_asset', editable => 1 },
      { name => 'room', label => 'Room', field => 'cf_room', only => 'nothing' },
      { name => 'gone', label => 'Gone', field => 'cf_gone', hidden => 1 },
    ],
    external_links => { device => [] },
  },
);

my $ro = render('ajax/device/details.tt', \%details);
unlike $ro, qr{contenteditable}, 'details__without_port_control__nothing_editable';
like $ro, qr{href="/search\?tab=device&q=B%3C12%3E&location=B%3C12%3E">B&lt;12&gt;</a>}, 'details__location__a_search_for_similar_devices_escaped';
like $ro, qr{<b class="xt-detail">10\.0\.0\.1:Plugin &lt;Detail&gt;</b>}, 'details__plugin_device_details__drawn_with_its_own_template';
like $ro, qr{<td>Asset[^<]*</td>\s*<td>\s*A-1}, 'details__custom_field__its_value';
unlike $ro, qr{>Room<|>Gone<}, 'details__custom_field_left_out_by_its_acl_or_hidden__not_drawn';
unlike $ro, qr{nd_adminbutton|nd_nonadminbutton}, 'details__no_role__no_admin_actions';

%roles = (port_control => 1, admin => 1);
my $rw = render('ajax/device/details.tt', \%details);
like $rw, qr{<td class="nd_editable-cell nd2-editable" contenteditable="true"[^>]*\s+data-field="location" data-for-device="10\.0\.0\.1">B&lt;12&gt;</td>},
  'details__location__an_editable_cell_whose_text_is_the_value_classic_script_posts';
like $rw, qr{data-field="contact" data-for-device="10\.0\.0\.1"></td>}, 'details__empty_contact__an_empty_cell_not_a_dash_that_would_be_posted';
like $rw, qr{data-field="cf_asset" data-for-device="10\.0\.0\.1">}, 'details__editable_custom_field__editable_as_in_the_classic_tab';
like $rw, qr{<tr data-for-device="10\.0\.0\.1">}, 'details__admin_actions__in_a_row_naming_the_device_netdisco_js_reads';
for my $job (qw/discover macsuck nbtstat/) {
  like $rw, qr{<input type="hidden" data-form="$job" value="10\.0\.0\.1" name="device"/>\s*<button class="[^"]*nd_adminbutton" name="$job">},
    "details__${job}__its_form_input_and_button";
}
like $rw, qr{<button class="btn btn-outline-secondary btn-sm" disabled[^>]*>Arpnip</button>}, 'details__job_not_offered__a_disabled_button';
like $rw, qr{>NBTstat</button>}, 'details__nbtstat__named_as_classic_names_it';
like $rw, qr{id="nd_devdel".*name="delete".*id="nd_devrenumber".*name="renumber"}s, 'details__delete_and_renumber__their_dialogs_and_buttons';
like $rw, qr{data-form="delete"[^>]*name="extra"}, 'details__delete_dialog__its_log_field';
like $rw, qr{class="nd_snap_btn[^"]*".*data-form="snapshot_req".*class='nd_snap_func}s, 'details__snapshot__its_menu_as_netdisco_js_toggles_it';
like $rw, qr{<datalist id="interfaces">\s*<option value="10\.0\.0\.2">lo1</option>}, 'details__renumber__offers_the_interface_addresses';

%roles = ();
my $nonadmin = render('ajax/device/details.tt', { %details, settings => { %{ $details{settings} }, enable_nonadmin_actions => 1 } });
like $nonadmin, qr{nd_nonadminbutton" name="discover"}, 'details__nonadmin_actions_enabled__the_nonadmin_buttons';
unlike $nonadmin, qr{nd_devdel}, 'details__nonadmin__no_delete';

# ---- Modules ----

{
  package XtModule;
  sub new { my ($c, %a) = @_; bless {%a}, $c }
  our $AUTOLOAD;
  sub AUTOLOAD { my $s = shift; (my $n = $AUTOLOAD) =~ s/.*:://; return if $n eq 'DESTROY'; $s->{$n} }
}
my %nodes = (
  root => [1],
  1 => { module => XtModule->new(description => 'Chassis <1>', class => 'chassis', serial => 'S1', model => 'M1', fru => 1, sw_ver => '4.32'),
         children => { port => [2], fan => [3] } },
  2 => { module => XtModule->new(description => 'Port Container', class => 'container'), children => { port => [4] } },
  3 => { module => XtModule->new(description => 'Fan 1', class => 'fan') },
  4 => { module => XtModule->new(description => 'Ethernet1', class => 'port') },
);
my $mods = render('ajax/device/modules.tt', { nodes => \%nodes, uri_for => sub { $_[0] } });
like $mods, qr{<details open>\s*<summary>.*Chassis &lt;1&gt;}s, 'modules__top_level__open';
like $mods, qr{href="/report/moduleinventory\?serial=S1">S1</a>}, 'modules__serial__links_to_the_module_inventory';
like $mods, qr{>FRU<}, 'modules__fru__marked';
like $mods, qr{sw 4\.32}, 'modules__versions__shown';
is scalar(() = $mods =~ /<details/g), 2, 'modules__a_module_with_children__a_details_each';
like $mods, qr{<div class="nd2-mod-leaf">.*Fan 1}s, 'modules__leaf__no_details';
is scalar(() = $mods =~ /<details open>/g), 2, 'modules__second_level__open_too';

# ---- home ----

my %home = (
  uri_for => sub { $_[0] }, uri_base => '', user_has_role => sub { $roles{ $_[0] } },
  settings => { _search_tabs => [ { tag => 'device', label => 'Device' }, { tag => 'xtphone', label => 'Phone' } ] },
);

my $out = render('index.tt', { %home, params => { return_url => '/device?q=x"y', login_failed => 1 },
  settings => { login_banner_message => 'Be <b>nice</b>', suggest_guest => 1 } });
like $out, qr{<form class="nd_login-form[^"]*" method="post" action="/login">}, 'home__signed_out__the_login_form';
like $out, qr{id="loginuser"[^>]*name="username"}, 'home__signed_out__username_where_netdisco_js_focuses';
like $out, qr{name="password" type="password"}, 'home__signed_out__password';
like $out, qr{name="return_url" value="/device\?q=x&quot;y"}, 'home__signed_out__return_url_escaped';
like $out, qr{Incorrect username or password}, 'home__failed_login__said';
like $out, qr{Be <b>nice</b>}, 'home__login_banner__as_configured_markup_as_in_classic';
like $out, qr{Guest access is available}, 'home__guest__suggested';

%roles = (admin => 1);
my $summary = {
  devices => { total => 12, failing => 7, unreachable => [ { ip => '10.0.0.9', dns => 'edge<1>' } ], stale => 2, stale_days => 7 },
  ports => { total => 400, up => 120, errdisabled => 1, half_duplex => 3 },
  jobs => { queued => 4, running => 1, failed_today => 2 },
  statistics => { day => '2026-10-16', nodes_active => 5000 },
  reports => { half_duplex => 'halfduplex' },
};
$out = render('index.tt', { %home, session => { logged_in_user => 'jdoe' }, params => {}, nd2_home => $summary });
like $out, qr{id="nqbody"[^>]*data-nd-typeahead=}, 'home__search__the_classic_box_and_its_typeahead';
like $out, qr{data-tab="device">Search Devices</a>.*data-tab="xtphone">Search Phones</a>}s, 'home__search_menu__every_search_tab_plugins_too';
like $out, qr{<small>Unreachable</small><b>7</b>}, 'home__tiles__the_unreachable_devices';
like $out, qr{nd2-tile nd2-tile-bad[^>]*\?health=failing}, 'home__unreachable__flagged_and_linked_to_the_list';
like $out, qr{as of 2026-10-16}, 'home__node_count__says_when_it_was_counted';
like $out, qr{<b>edge&lt;1&gt;</b></a> is unreachable}, 'home__attention__an_unreachable_device_by_name';
like $out, qr{and <a href="/devices\?health=failing">6 more unreachable</a>}, 'home__attention__how_many_more';
like $out, qr{<b>3</b> linked ports run half duplex.*href="/report/halfduplex\?firstsearch=on"}s, 'home__attention__half_duplex_linked_to_its_report';
like $out, qr{<b>1</b> port is error disabled}, 'home__attention__one_port__singular';
like $out, qr{id="discodevs"[^>]*name="device"}, 'home__admin__the_discover_form';
like $out, qr{data-action="pingsweep" data-timeout="0\.1"}, 'home__admin__the_ping_sweeps';
like $out, qr{id="nd_stats" data-nd-url="/ajax/content/statistics"}, 'home__system_information__the_panel_netdisco_js_fills';
like $out, qr{data-nd2-recent}, 'home__recent_devices__a_list_for_home_js';

%roles = ();
$out = render('index.tt', { %home, session => { logged_in_user => 'jdoe' }, params => {}, nd2_home => {
  %$summary, devices => { %{ $summary->{devices} }, failing => 0, unreachable => [], stale => 0 },
  ports => { total => 1, up => 1, errdisabled => 0, half_duplex => 0 }, jobs => { queued => 0, running => 0, failed_today => 0 } } });
like $out, qr{Nothing: every device is reachable}, 'home__nothing_to_look_at__said';
unlike $out, qr{discodevs}, 'home__not_admin__no_discover_form';

$out = render('index.tt', { %home, session => { logged_in_user => 'jdoe' }, params => {}, vars => { notfound => 1 } });
like $out, qr{Sorry, page not found}, 'home__not_found__said';
unlike $out, qr{nd2-tile}, 'home__no_figures__no_tiles_but_the_rest_of_the_page';
like $out, qr{id="nqbody"}, 'home__not_found__still_the_search';

# ---- the statistics, normalized ----

is normalize_statistics(undef), undef, 'normalizeStatistics__never_compiled__null';
is_deeply normalize_statistics({ day => '2026-10-16', node_active_count => '12', device_count => '3', pg_ver => '18' }),
  { day => '2026-10-16', devices => 3, device_ips => undef, links => undef, ports => undef, ports_up => undef,
    ips => undef, ips_active => undef, nodes => undef, nodes_active => 12, phones => undef, waps => undef },
  'normalizeStatistics__row__counts_as_numbers_versions_left_out';

done_testing;
