#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Temp ();
use File::Path 'make_path';
use File::Basename 'dirname';
use File::Spec::Functions 'catfile';
use Template::AutoFilter;

# The web plugin system under the modern interface. Plugins and sites extend
# the web UI through App::Netdisco::Web::Plugin (template paths, port columns,
# external links) and template_paths; the modern interface must keep every one
# of those working, and say so when it cannot use a classic override. Built
# from files and direct renders, without a database (xt/36).

sub write_file {
  my ($file, $text) = @_;
  make_path(dirname($file));
  open my $fh, '>', $file or die "cannot write $file: $!";
  print $fh $text;
  close $fh;
}

# ---- where an interface looks for its templates ----

# Any interface, not only the modern one: a throwaway "xtui" is registered here
# and found through the same paths the modern one is.

{
  package XtPluginUser;
  use Dancer ':syntax';
  use App::Netdisco::Web::Plugin;
}

my $plugin = File::Temp->newdir(CLEANUP => 1);
write_file(catfile("$plugin", 'views', 'plugin', 'xtcol', 'device_port_column.tt'), "x\n");
write_file(catfile("$plugin", 'views-xtui', 'device.tt'), "x\n");
my $plain = File::Temp->newdir(CLEANUP => 1);
write_file(catfile("$plain", 'views', 'x.tt'), "x\n");

XtPluginUser::register_template_path("$plugin");
XtPluginUser::register_template_path("$plain");
is_deeply Dancer::setting('_plugin_template_roots'), [ "$plain", "$plugin" ],
  'registerTemplatePath__root__recorded_last_registered_first';
ok scalar(grep { $_ eq "$plugin/views" } @{ Dancer::config()->{engines}{netdisco_template_toolkit}{INCLUDE_PATH} }),
  'registerTemplatePath__views__still_on_the_engine_path_as_before';

use App::Netdisco::Web::UI qw/register_web_ui web_ui web_ui_names valid_web_ui web_ui_module
                              ui_dirs_for ui_shadowed_overrides ui_include_paths/;

is web_ui_module('Modern'), 'App::Netdisco::Web::UI::Modern', 'webUiModule__core_name__under_web_ui';
is web_ui_module('X::Mine'), 'App::NetdiscoX::Web::UI::Mine', 'webUiModule__x_name__site_local_like_plugins';
is web_ui_module('+Some::Module'), 'Some::Module', 'webUiModule__plus__the_module_as_written';
is web_ui_module(''), undef, 'webUiModule__nothing__none';

ok !eval { register_web_ui({ name => 'classic' }); 1 }, 'registerWebUi__classic__is_built_in';
ok !eval { register_web_ui({ name => 'Bad Name' }); 1 }, 'registerWebUi__odd_name__refused';
ok !valid_web_ui('xtui'), 'validWebUi__not_registered__not_valid';

my $core = File::Temp->newdir(CLEANUP => 1);
write_file(catfile("$core", $_), "x\n") for 'device.tt', 'ajax/device/ports.tt', 'layouts/main.tt';
my $ui = register_web_ui({ name => 'xtui', views => "$core" });
ok valid_web_ui('xtui'), 'registerWebUi__name__now_valid';
is_deeply [ web_ui_names() ], [ sort 'classic', 'xtui' ], 'webUiNames__classic_and_what_registered';
is $ui->{switch_label}, 'Try the xtui interface', 'registerWebUi__no_label__a_default_for_the_classic_menu';

my $site = File::Temp->newdir(CLEANUP => 1);
make_path(catfile("$site", 'share', 'views'), catfile("$site", 'share', 'views-xtui'), catfile("$site", 'mine', 'views-xtui'));
is_deeply [ ui_dirs_for('xtui', "$site/share/views", "$site/share", "$site/mine", "$site/none", undef) ],
  [ "$site/share/views-xtui", "$site/mine/views-xtui" ],
  'uiDirsFor__template_paths__beside_views_else_inside_existing_ones_once';
is_deeply [ ui_dirs_for('other', "$site/share/views") ], [], 'uiDirsFor__another_interface__its_own_name_only';

{
  my @warnings;
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  App::Netdisco::Web::UI::setup_web_uis([ "$site/share/views" ]);
  is_deeply web_ui('xtui')->{overrides}, [ "$site/share/views-xtui", "$plugin/views-xtui" ],
    'setupWebUis__overrides__the_sites_then_the_plugins_views_NAME';
  is ref(Dancer::config()->{engines}{netdisco_template_toolkit}{INCLUDE_PATH}[0]), 'CODE',
    'setupWebUis__overlay__in_front_of_every_template_path';

  Dancer::set('_default_web_ui' => 'xtui');
  is_deeply ui_include_paths(), [ "$site/share/views-xtui", "$plugin/views-xtui", "$core" ],
    'uiIncludePaths__an_interface__its_overrides_then_its_own_views';
  Dancer::set('_default_web_ui' => 'classic');
  is_deeply ui_include_paths(), [], 'uiIncludePaths__classic__nothing_in_front_of_the_classic_chain';
}

# a classic override of a template an interface draws itself
my $classic = File::Temp->newdir(CLEANUP => 1);
write_file(catfile("$classic", $_), "x\n") for 'device.tt', 'ajax/device/ports.tt', 'ajax/device/details.tt', 'layouts/main.tt';
my $own = File::Temp->newdir(CLEANUP => 1);
write_file(catfile("$own", 'device.tt'), "x\n");

is_deeply [ map { $_->[1] } ui_shadowed_overrides([ "$classic" ], [], "$core") ],
  [ 'ajax/device/ports.tt', 'device.tt' ],
  'uiShadowedOverrides__classic_override_of_an_interface_template__reported';
is_deeply [ map { $_->[1] } ui_shadowed_overrides([ "$classic" ], [ "$own" ], "$core") ],
  [ 'ajax/device/ports.tt' ],
  'uiShadowedOverrides__with_its_own_version_for_the_interface__not_reported';
ok !grep({ $_->[1] =~ m/details|layouts/ } ui_shadowed_overrides([ "$classic" ], [], "$core")),
  'uiShadowedOverrides__template_it_does_not_draw_or_a_layout__not_reported';
is_deeply [ ui_shadowed_overrides([ "$classic" ], [], "$core/none") ], [],
  'uiShadowedOverrides__no_views__nothing';

# the real tree: the modern interface redraws these classic pages
my %redrawn = map {( $_->[1] => 1 )} ui_shadowed_overrides([ 'share/views' ], [], 'share/views-modern');
ok $redrawn{'device.tt'} && $redrawn{'ajax/device/ports.tt'},
  'uiShadowedOverrides__share_views_against_share_views_modern__finds_the_pages_modern_redraws';

# ---- plugin port columns in the modern Ports tab ----

use App::Netdisco::Web::UI::Modern::Ports qw/server_port_columns port_column_offer/;

my %has = map {( $_ => 1 )} 'plugin/xtcol/device_port_column.tt';
my $has = sub { $has{ shift() } };
is_deeply server_port_columns([ { name => 'xtcol' }, { name => 'nofile' }, { name => 'xthidden', hidden => 1 } ], $has, 0),
  ['xtcol'], 'serverPortColumns__plugin_with_a_template__drawn_by_the_server_others_not';
is_deeply server_port_columns([], $has, 2), ['c_links'], 'serverPortColumns__external_links__drawn_by_the_server';

my $offer = port_column_offer([ { name => 'c_port', label => 'Port' }, { name => 'xtcol', label => 'XT' },
                                { name => 'xthidden', label => 'H', hidden => 1 } ], ['xtcol']);
is_deeply [ map {[ $_->{name}, ($_->{server} ? 1 : 0) ]} @$offer ], [ [ 'c_port', 0 ], [ 'xtcol', 1 ] ],
  'portColumnOffer__server_columns__marked_hidden_ones__not_offered';

{
  package XtRow;
  sub new { my ($c, %a) = @_; bless {%a}, $c }
  sub port { $_[0]{port} }
  sub get_column { my ($s, $c) = @_; die "no column $c\n" unless exists $s->{$c}; $s->{$c} }
}

my $views = File::Temp->newdir(CLEANUP => 1);
write_file(catfile("$views", 'plugin', 'xtcol', 'device_port_column.tt'),
  qq{<b class="xt">[% row.port %]@[% device.ip %]:[% config.label %]</b>});
write_file(catfile("$views", 'plugin', 'xtbroken', 'device_port_column.tt'), qq{before[% THROW xt "broken" %]});
write_file(catfile("$views", 'plugin', 'xtcol', 'device_port_column_csv.tt'), qq{[% myport.push('csv-' _ row.port) %]});

sub engine {
  return Template::AutoFilter->new({
    INCLUDE_PATH => [ "$views", 'share/views-modern', 'share/views' ], ANYCASE => 1, ABSOLUTE => 1,
    PRE_CHOMP => 1, AUTO_FILTER => shift, ENCODING => 'utf8',
    PLUGINS => { csv => 'App::Netdisco::Template::Plugin::CSV' },
  }) or die Template->error;
}

my @rows = (XtRow->new(port => 'Gi1/0/1'), XtRow->new(port => 'Gi<2>'));
my $out = '';
engine('html_entity')->process('ajax/device/ports.tt', {
  uri_base => '', device_ip => '10.0.0.1', columns => '[]', reasons => '[]',
  device => { ip => '10.0.0.1' },
  server_rows => \@rows,
  server_columns => [ { name => 'xtcol', label => 'XT' }, { name => 'xtbroken', label => 'B' },
                      { name => 'xtacl', label => 'A', only => 'nothing' } ],
  permitted_by_acl => sub { not $_[1]{only} },
  settings => { external_links => { device_port => [] } },
}, \$out) or die engine('html_entity')->error;

my ($tpl) = $out =~ m{<template class="nd2-server-cells">(.*?)</template>}s;
ok defined $tpl, 'portsPane__plugin_columns__drawn_into_an_inert_template';
like $tpl, qr{<div data-port="Gi1/0/1" data-col="xtcol"><b class="xt">Gi1/0/1\@10\.0\.0\.1:XT</b></div>},
  'portsPane__plugin_cell__the_plugins_own_template_with_row_device_and_config';
like $tpl, qr{data-port="Gi&lt;2&gt;" data-col="xtcol"><b class="xt">Gi&lt;2&gt;\@}, 'portsPane__port_names__escaped_in_and_out';
like $tpl, qr{<div data-port="Gi1/0/1" data-col="xtbroken"></div>}, 'portsPane__failing_plugin_template__an_empty_cell_not_a_broken_tab';
unlike $tpl, qr{data-col="xtacl"}, 'portsPane__column_its_acl_leaves_out__not_drawn_for_that_port';

$out = '';
engine('html_entity')->process('ajax/device/ports.tt', {
  uri_base => '', device_ip => '10.0.0.1', columns => '[]', reasons => '[]', server_columns => [], server_rows => [],
}, \$out) or die engine('html_entity')->error;
unlike $out, qr{nd2-server-cells}, 'portsPane__no_plugin_columns__no_template';

# ---- the CSV, as the classic one writes plugin and custom field columns ----

my $csv = '';
engine('none')->process('ajax/device/ports_csv.tt', {
  ports => [ { port => 'Gi1/0/1', status => 'up', vlans => [] }, { port => 'Gi1/0/2', status => 'down', vlans => [] } ],
  extra_columns => [ { name => 'xtcol', label => 'XT' }, { name => 'room', label => 'Room', field => 'cf_room' },
                     { name => 'gone', label => 'Gone', field => 'cf_gone' } ],
  rows_by_port => { 'Gi1/0/1' => XtRow->new(port => 'Gi1/0/1', cf_room => '2.14'),
                    'Gi1/0/2' => XtRow->new(port => 'Gi1/0/2', cf_room => '=1+1') },
}, \$csv) or die engine('none')->error;
my @lines = grep { length } split /\n/, $csv;
is scalar @lines, 3, 'portsCsv__plugin_columns__still_a_line_per_port';
like $lines[0], qr/,"Last Comment",XT,Room,Gone$/, 'portsCsv__header__plugin_and_custom_field_columns_after_the_rest';
like $lines[1], qr/,csv-Gi1\/0\/1,2\.14,$/, 'portsCsv__plugin_csv_template_then_the_field_then_empty_when_missing';
like $lines[2], qr/,'=1\+1,$/, 'portsCsv__custom_field_value__neutralized_like_every_value';

done_testing;
