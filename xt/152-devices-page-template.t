#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use Template::AutoFilter;
use File::Spec::Functions qw/catfile updir/;
use FindBin;

# The Devices page (App::Netdisco::Web::DevicesPage): its template, rendered
# with the overlay in front of share/views as the app arranges it (see xt/143),
# and the one decision its route makes, read from the source because a page
# request needs a database (see xt/145).

my $tt = Template::AutoFilter->new({
  INCLUDE_PATH => [ 'share/views-modern', 'share/views' ],
  ANYCASE => 1, ABSOLUTE => 1, PRE_CHOMP => 1, AUTO_FILTER => 'html_entity', ENCODING => 'utf8',
}) or die Template->error;

my $html = '';
$tt->process('devices.tt', { uri_base => '/nd' }, \$html) or die $tt->error;

like $html, qr{<h1>Devices</h1>}, 'devicesPage__heading';
like $html, qr{data-nd2-devices data-nd2-src="/nd/ajax/data/v2/devices"}, 'devicesPage__reads_the_list_from_v2_under_the_site_base';
like $html, qr{class="nd2-devices-search"[^>]*aria-label="Filter devices"}s, 'devicesPage__filter_has_a_name';
like $html, qr{data-chip="failing" aria-pressed="false"}, 'devicesPage__unreachable_filter_starts_off';
like $html, qr{class="nd2-muted nd2-dev-summary" aria-live="polite"},
  'devicesPage__summary_is_announced_as_it_changes';
like $html, qr{class="btn btn-outline-secondary btn-sm nd2-devices-more" hidden}, 'devicesPage__show_more_hidden_until_there_is_more';

# the layout loads the page's script only on this page
my $layout = do { local $/; open my $fh, '<', 'share/views-modern/layouts/main.tt' or die $!; <$fh> };
like $layout, qr{\[% IF page_devices %\]<script type="module" src="[^"]*/modern/js/devices\.js}, 'layout__devices_script__only_where_asked';

my $src = do {
  local $/;
  open my $fh, '<', catfile($FindBin::Bin, updir(), qw/lib App Netdisco Web DevicesPage.pm/) or die $!;
  <$fh>;
};
like $src, qr{return redirect uri_for\('/inventory'\)->path\s+unless current_web_ui\(\) eq 'modern';},
  'devicesRoute__classic_interface__goes_to_the_inventory_it_has_instead';
like $src, qr{template 'devices', \{ page_devices => 1 \}, \{ layout => 'main' \};},
  'devicesRoute__modern_interface__renders_the_page_and_asks_for_its_script';

done_testing;
