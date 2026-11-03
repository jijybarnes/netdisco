#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Spec::Functions qw/catdir catfile updir/;
use File::Path 'make_path';
use FindBin;
use File::Temp ();

# Three interfaces at once: classic, modern, and compact, which Netdisco ships
# but does not turn on. What is pinned is that a browser gets the interface its
# cookie names whatever the others, that compact is the classic page wrapped
# (so a site's own layout in template_paths is the one it wraps), and that its
# plugin and style sheet are there. What the account menu offers is in xt/500
# (the list), xt/503 (modern's menu) and xt/40 (the classic one).
#
# Through the login page, as in xt/501: it is rendered in the same main layout
# and is the one page every browser sees.
my ($envdir, $site);
BEGIN {
  $ENV{DANCER_PUBLIC} ||= catdir($FindBin::Bin, updir(), 'share', 'public');

  $site = File::Temp->newdir(CLEANUP => 1);
  make_path(catdir("$site", 'views', 'layouts'));
  open my $layout, '>', catfile("$site", 'views', 'layouts', 'main.tt')
    or die "cannot write the layout: $!";
  # a site's layout, with a plain <html> and a </head>, as compact finds them
  print $layout qq{<html><head><title>xt</title></head><body data-xt-site-layout="1">[% content | none %]</body></html>\n};
  close $layout;

  $envdir = File::Temp->newdir(CLEANUP => 1);
  open my $env, '>', catfile("$envdir", 'testing.yml')
    or die "cannot write the test environment file: $!";
  print $env "default_web_ui: 'classic'\nweb_uis: ['modern', 'compact']\n"
           . "template_paths: ['" . catdir("$site", 'views') . "']\n";
  close $env;

  $ENV{DANCER_ENVDIR} = "$envdir";
  $ENV{DANCER_ENVIRONMENT} = 'testing';
}

use Plack::Test;
use Plack::Util;
use HTTP::Request::Common;

my $psgi = catfile($FindBin::Bin, updir(), 'bin', 'netdisco-web-fg');
my $app  = eval { Plack::Util::load_psgi($psgi) };
BAIL_OUT("could not load $psgi: $@") unless $app;

is_deeply [ App::Netdisco::Web::UI::web_ui_names() ], [qw/classic compact modern/],
  'setupWebUis__modern_and_compact_named__both_declared';
ok $INC{'App/Netdisco/Web/Plugin/UI/Compact.pm'}, 'loadWebUis__compact__its_plugin_is_loaded';
is App::Netdisco::Web::UI::web_ui('compact')->{short_label}, 'Compact UI',
  'setupWebUis__compact_plugin_label__is_used';
is_deeply [ map { "$_->{name}:$_->{current}" } App::Netdisco::Web::UI::web_uis_for('compact') ],
  [qw/classic:0 compact:1 modern:0/], 'webUisFor__using_compact__all_three_compact_ticked';

my $COMPACT = qr/<html [^>]*data-nd-ui="compact"/;
my $MODERN  = qr/<html [^>]*data-nd-ui="modern"/;
my $SITE    = qr/data-xt-site-layout="1"/;

test_psgi $app, sub {
  my $cb = shift;
  my $page = sub { $cb->(GET '/login', (@_ ? (Cookie => shift) : ()))->content };

  my $classic = $page->();
  unlike $classic, $COMPACT, 'loginPage__no_cookie__not_compact';
  unlike $classic, $MODERN, 'loginPage__no_cookie__not_modern';
  like $classic, $SITE, 'loginPage__site_layout_in_template_paths__is_the_classic_layout';

  my $compact = $page->('nd_web_ui=compact');
  like $compact, $COMPACT, 'loginPage__cookie_compact__marks_the_page_compact';
  like $compact, $SITE, 'loginPage__cookie_compact__wraps_the_sites_layout_not_the_shipped_one';
  like $compact, qr{<link rel="stylesheet" href="/compact/css/compact\.css\?v=[^"]*"/>\s*</head>},
    'loginPage__cookie_compact__links_the_compact_style_sheet_at_the_end_of_the_head';
  like $compact, qr/Welcome to Netdisco/, 'loginPage__cookie_compact__keeps_the_page_content';
  unlike $compact, $MODERN, 'loginPage__cookie_compact__not_modern';
  is scalar(() = $compact =~ m{<html}g), 1, 'loginPage__cookie_compact__one_html_element';

  my $modern = $page->('nd_web_ui=modern');
  like $modern, $MODERN, 'loginPage__cookie_modern__still_modern_with_compact_turned_on';
  unlike $modern, $COMPACT, 'loginPage__cookie_modern__not_compact';

  # the choice is per request: going round the three leaves each as it is
  my @seen = map { my $p = $page->($_); $p =~ $COMPACT ? 'compact' : $p =~ $MODERN ? 'modern' : 'classic' }
             qw(nd_web_ui=compact nd_web_ui=classic nd_web_ui=modern nd_web_ui=compact nd_web_ui=modern nd_web_ui=classic);
  is_deeply \@seen, [qw/compact classic modern compact modern classic/],
    'loginPage__cookies_in_turn__each_browser_gets_the_interface_it_picked';

  my $css = $cb->(GET '/compact/css/compact.css');
  is $css->code, 200, 'compactStylesheet__no_session__is_served';
  like $css->header('Content-Type'), qr{^text/css}, 'compactStylesheet__no_session__is_served_as_css';
  like $css->content, qr/html\[data-nd-ui="compact"\]/, 'compactStylesheet__is_scoped_to_the_compact_page';
};

done_testing;
