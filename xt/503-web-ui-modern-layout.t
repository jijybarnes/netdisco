#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use Template::AutoFilter;

# xt/141 renders the modern layout through the app, but only signed out: the
# signed-in half needs a session the DBIC auth provider cannot give a test (see
# xt/36). That half is the rail, the menus and the choice of interface, so it
# is rendered here directly, with the overlay in front of share/views exactly
# as the app arranges it.

my $tt = Template::AutoFilter->new({
  INCLUDE_PATH => [ 'share/views-modern', 'share/views' ],
  START_TAG    => quotemeta('[%'),
  END_TAG      => quotemeta('%]'),
  ANYCASE      => 1,
  ABSOLUTE     => 1,
  PRE_CHOMP    => 1,
  AUTO_FILTER  => 'html_entity',
  ENCODING     => 'utf8',
}) or die Template->error;

# The layout reads settings._reports and friends, which Template Toolkit hides
# as private unless told otherwise, as lib/App/Netdisco/Web.pm does. After new()
# rather than before: building the engine loads Template::Stash, which resets it.
$Template::Stash::PRIVATE = undef;

my %roles = (admin => 1);
my $stash = {
  content   => '<div id="xt-page-content"></div>',
  session   => { logged_in_user => 'jdoe', logged_in_fullname => 'Jane Doe' },
  vars      => { nav => 'reports' },
  nd2_nav   => 'reports',
  nd2_crumbs => [ { label => 'Reports' }, { label => 'Port' }, { label => 'Mismatched <Duplex>' } ],
  request   => { request_uri => '/device?q=10.0.0.1&tab=ports' },
  uri_base  => '',
  web_ui    => 'modern',
  # what App::Netdisco::Web::UI hands over for a browser using modern when
  # compact is turned on too: every interface, the classic one first, the one
  # in use marked
  web_uis   => [
    { name => 'classic', short_label => 'Classic UI', current => 0,
      switch_title => 'Switch this browser back to the classic interface' },
    { name => 'compact', short_label => 'Compact UI', current => 0,
      switch_title => 'Switch this browser to the compact interface' },
    { name => 'modern', short_label => 'Modern UI', current => 1,
      switch_title => 'Switch this browser to the modern interface' },
  ],
  uri_for   => sub { $_[0] },
  user_has_role => sub { $roles{ $_[0] } },
  settings  => {
    branding_text  => 'Netdisco',
    _navbar_items  => [ { tag => 'inventory', path => '/inventory', label => 'Inventory' },
                        { tag => 'xtphones', path => '/xtphones', label => 'Phones', icon => 'fa-phone' },
                        { tag => 'xtbad', path => '/xtbad', label => 'Bad', icon => 'fa-x" onclick="x' },
                        { tag => 'xtplain', path => '/xtplain', label => 'Plain' } ],
    _additional_css => [ 'xtcss' ],
    _additional_javascript => [ 'xtjs' ],
    _report_order  => [ 'Port', 'Node' ],
    _reports_menu  => { Port => [ 'duplexmismatch', 'hiddenone' ], Node => [] },
    _reports       => {
      duplexmismatch => { label => 'Mismatched Duplex' },
      hiddenone      => { label => 'Hidden One', hidden => 1 },
    },
    _admin_order   => [ 'jobqueue', 'divider', 'users' ],
    _admin_tasks   => { jobqueue => { label => 'Job Queue' }, users => { label => 'User Management' } },
  },
};

my $html = '';
$tt->process('layouts/main.tt', $stash, \$html) or die $tt->error;

like $html, qr/<html [^>]*data-nd-ui="modern"/, 'modernLayout__signed_in__marks_the_page_modern';

# what web plugins put in the layout, as the classic one has it
like $html, qr{href="/xtphones">\s*<i class="fas fa-phone"></i><span>Phones</span>}, 'modernLayout__plugin_navbar_item__on_the_rail_with_its_icon';
like $html, qr{href="/xtbad">\s*<i class="fas fa-circle-dot"></i>}, 'modernLayout__plugin_icon_not_a_plain_name__the_default_icon';
like $html, qr{href="/xtplain">\s*<i class="fas fa-circle-dot"></i><span>Plain</span>}, 'modernLayout__plugin_navbar_item_without_icon__the_default_icon';
like $html, qr{/plugin/xtcss/xtcss\.css}, 'modernLayout__plugin_css__linked';
like $html, qr{/plugin/xtjs/xtjs\.js}, 'modernLayout__plugin_javascript__loaded';
like $html, qr/<body class="nd2 nd2-signed-in"/, 'modernLayout__signed_in__marks_the_body_for_the_rail_offset';
like $html, qr/id="xt-page-content"/, 'modernLayout__signed_in__renders_the_page_content';

like $html, qr{class="nd2-rail-item" href="/inventory"}, 'modernLayout__navbar_item__becomes_a_rail_item';
like $html, qr{class="nd2-rail-item active"[^>]*>\s*<i class="fas fa-chart-column"}s,
  'modernLayout__nav_reports__marks_the_reports_rail_item_active';
like $html, qr{href="/report/duplexmismatch\?firstsearch=on">Mismatched Duplex</a>},
  'modernLayout__visible_report__is_listed_in_the_reports_menu';
unlike $html, qr/Hidden One/, 'modernLayout__hidden_report__is_left_out';
unlike $html, qr{<h6>Node</h6>}, 'modernLayout__empty_report_category__has_no_heading';

like $html, qr{action="/admin/discoverall"}, 'modernLayout__admin__gets_the_run_on_all_devices_forms';
like $html, qr{href="/admin/users\?firstsearch=on">User Management</a>}, 'modernLayout__admin__lists_the_admin_tasks';

# the interfaces to choose from, in the account menu rather than the top bar
my ($menu) = $html =~ m{(<h6 class="dropdown-header">Interface</h6>.*?)<li><a class="dropdown-item" href="/logout">}s;
ok defined $menu, 'modernLayout__account_menu__has_the_interface_section_before_log_out';
$menu //= '';
like $menu, qr{<span class="dropdown-item-text fw-semibold" aria-current="true"><i class="fas fa-check fa-fw"></i> Modern UI</span>},
  'modernLayout__interface_in_use__is_ticked_and_not_a_button';
like $menu, qr{name="ui" value="classic">\s*<button type="submit" class="dropdown-item" title="Switch this browser back to the classic interface"><i class="fas fa-fw"></i> Classic UI</button>}s,
  'modernLayout__other_interface__is_a_menu_button_to_switch_to_it';
like $menu, qr{name="ui" value="compact">\s*<button type="submit" class="dropdown-item" title="Switch this browser to the compact interface"><i class="fas fa-fw"></i> Compact UI</button>}s,
  'modernLayout__a_third_interface__is_offered_the_same_way';
ok index($menu, 'value="classic"') < index($menu, 'value="compact"'),
  'modernLayout__interfaces__in_the_order_given';
unlike $menu, qr{name="ui" value="modern"}, 'modernLayout__interface_in_use__has_no_switch_to_itself';
unlike $html, qr{nd2-topbar-btn[^>]*title="Switch this browser}, 'modernLayout__top_bar__has_no_switch_buttons_any_more';
# the route returns to the Referer; a field would echo the request URI (xt/76)
unlike $html, qr{/device\?q=10\.0\.0\.1}, 'modernLayout__switch__does_not_echo_the_request_uri';
# only the account menu's: the rest of the page has dividers of its own
my $dividers = sub { my ($account) = $_[0] =~ m{(class="nd2-avatar".*?</ul>)}s; return scalar(() = ($account // '') =~ m{<hr class="dropdown-divider">}g) };
is $dividers->($html), 2,
  'modernLayout__account_menu__interface_section_between_dividers_and_no_double_divider_before_log_out';

# the classic interface alone cannot choose: no section, and the divider before
# Log Out is the one it always had
{
  my $alone = '';
  $tt->process('layouts/main.tt', { %$stash, web_uis => [ { %{ $stash->{web_uis}[0] }, current => 1 } ] }, \$alone)
    or die $tt->error;
  unlike $alone, qr{Interface</h6>}, 'modernLayout__one_interface__no_interface_section';
  is $dividers->($alone), 1, 'modernLayout__one_interface__log_out_keeps_its_divider';
}

like $html, qr{data-nd-role="admin"[^>]*>\s*JA\s*</button>}s, 'modernLayout__avatar__shows_two_initials_and_the_role';

like $html, qr{<div class="dropdown nd2-jobs" data-nd2-jobs data-nd2-src="/ajax/data/v2/me/jobs\?limit=10">},
  'modernLayout__signed_in__has_the_jobs_list_reading_the_users_own_jobs';
like $html, qr{class="nd2-badge" hidden}, 'modernLayout__jobs_badge__hidden_until_something_is_running';
like $html, qr{<a href="/admin/jobqueue\?firstsearch=on">Whole queue</a>}, 'modernLayout__admin__links_the_whole_queue';
like $html, qr{/modern/js/jobs\.js\?v=}, 'modernLayout__signed_in__loads_the_jobs_script';

like $html, qr{class="nd2-rail-item" href="/devices">\s*<i class="fas fa-server"></i><span>Devices</span>},
  'modernLayout__rail__has_the_devices_list';
like $html, qr{<button type="button" class="nd2-rail-item nd2-rail-btn" data-nd2-theme},
  'modernLayout__rail__has_the_theme_button';
like $html, qr{netdisco-theme\.js\?v=[^"]*"></script>\s*<script src="/modern/js/theme-pref\.js},
  'modernLayout__head__puts_the_browsers_theme_in_force_right_after_the_resolver';
like $html, qr{<nav class="nd2-crumbs" aria-label="Breadcrumb"><ol>},
  'modernLayout__crumbs__a_breadcrumb_landmark';
like $html, qr{<li aria-current="page">Mismatched &lt;Duplex&gt;</li>},
  'modernLayout__crumbs__the_last_is_the_page_escaped';
unlike $html, qr{<a href="[^"]*">Reports</a>}, 'modernLayout__crumbs__a_crumb_with_no_page_is_not_a_link';

my $device_page = '';
$tt->process('layouts/main.tt', { %$stash, nd2_nav => 'devices',
  nd2_crumbs => [ { label => 'Devices', href => '/devices' }, { label => 'sw1' } ] }, \$device_page) or die $tt->error;
like $device_page, qr{class="nd2-rail-item active" href="/devices"}, 'modernLayout__on_a_device__devices_lit';
like $device_page, qr{<li><a href="/devices">Devices</a></li>}, 'modernLayout__crumbs__a_crumb_with_a_page_links_to_it';

%roles = ();
my $plain = '';
$tt->process('layouts/main.tt', $stash, \$plain) or die $tt->error;
unlike $plain, qr{/admin/discoverall}, 'modernLayout__not_admin__has_no_admin_menu';
unlike $plain, qr{Whole queue}, 'modernLayout__not_admin__no_link_to_the_whole_queue';
like $plain, qr{data-nd2-jobs}, 'modernLayout__not_admin__still_has_their_own_jobs';

my $anon = '';
$tt->process('layouts/main.tt', { %$stash, session => {} }, \$anon) or die $tt->error;
unlike $anon, qr{data-nd2-jobs|jobs\.js}, 'modernLayout__signed_out__no_jobs_list_and_no_script_to_poll_it';

done_testing;
