#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Spec::Functions qw/catdir catfile updir/;
use File::Path 'make_path';
use FindBin;
use File::Temp ();

# A site's own web interface, `mine`, made the way site-local files are: a
# views-mine directory in nd-site-local/share, its public files beside it, and a
# web plugin in site_plugins. Nothing of it is in the distribution.
#
# The interface a page renders in comes from the nd_web_ui cookie, else from
# default_web_ui. The pages that need a session cannot be driven here (the auth
# provider is DBIC, see xt/36), so this goes through the login page, which is
# rendered in the same main layout and is the one page every browser sees.
my ($envdir, $home);
BEGIN {
  $ENV{DANCER_PUBLIC} ||= catdir($FindBin::Bin, updir(), 'share', 'public');

  $home = File::Temp->newdir(CLEANUP => 1);
  my $share = catdir("$home", 'nd-site-local', 'share');
  make_path(catdir($share, 'views-mine', 'layouts'), catdir($share, 'public', 'mine'),
            catdir("$home", 'site_plugins'));
  open my $layout, '>', catfile($share, 'views-mine', 'layouts', 'main.tt')
    or die "cannot write the layout: $!";
  print $layout qq{<html data-nd-ui="mine"><body>[% content | none %]</body></html>\n};
  close $layout;
  open my $css, '>', catfile($share, 'public', 'mine', 'mine.css')
    or die "cannot write the style sheet: $!";
  print $css "body { color: #123456; }\n";
  close $css;

  $envdir = File::Temp->newdir(CLEANUP => 1);
  open my $env, '>', catfile("$envdir", 'testing.yml')
    or die "cannot write the test environment file: $!";
  print $env "default_web_ui: 'classic'\nweb_uis: ['mine']\nsite_local_files: true\ntemplate_paths: []\n";
  close $env;

  $ENV{NETDISCO_HOME} = "$home";
  $ENV{DANCER_ENVDIR} = "$envdir";
  $ENV{DANCER_ENVIRONMENT} = 'testing';
  # where the site's plugin would sit in site_plugins
  unshift @INC, catdir($FindBin::Bin, 'lib');
}

use Plack::Test;
use Plack::Util;
use HTTP::Request::Common;

my $psgi = catfile($FindBin::Bin, updir(), 'bin', 'netdisco-web-fg');
my $app  = eval { Plack::Util::load_psgi($psgi) };
BAIL_OUT("could not load $psgi: $@") unless $app;

sub setting { return Dancer::Config::setting(@_) }

is setting('_default_web_ui'), 'classic',
  'resolveDefaultWebUi__configured_classic__is_recorded_at_startup';
is_deeply [ App::Netdisco::Web::UI::web_ui_names() ], [qw/classic mine/],
  'setupWebUis__views_dir_in_nd_site_local__declares_the_interface';

my $mine = App::Netdisco::Web::UI::web_ui('mine');
is $mine->{switch_label}, 'Try mine', 'setupWebUis__plugin_registered_labels__are_used';
is $mine->{switch_title}, 'Switch this browser to mine', 'setupWebUis__plugin_registered_title__is_used';
ok !defined $mine->{views}, 'setupWebUis__nothing_shipped__the_site_dir_is_the_interface';
is_deeply $mine->{overrides}, [ catdir("$home", 'nd-site-local', 'share', 'views-mine') ],
  'setupWebUis__site_local_and_its_views_dir__find_the_one_directory_once';

my $MINE = qr/<html data-nd-ui="mine"/;

test_psgi $app, sub {
  my $cb = shift;
  my $page = sub { $cb->(GET '/login', (@_ ? (Cookie => shift) : ()))->content };

  my $plain = $page->();
  unlike $plain, $MINE, 'loginPage__no_cookie_default_classic__renders_classic';
  like $plain, qr/class="navbar /, 'loginPage__no_cookie_default_classic__has_the_classic_navbar';

  like $page->('nd_web_ui=mine'), $MINE, 'loginPage__cookie_mine__renders_the_sites_layout';
  like $page->('nd_web_ui=mine'), qr/id=.loginuser.[^>]*name="username"/,
    'loginPage__cookie_mine__falls_through_to_the_classic_login_form';

  unlike $page->('nd_web_ui=../views-mine'), $MINE,
    'loginPage__cookie_not_an_interface_name__falls_back_to_the_default';
  unlike $page->('nd_web_ui=classic'), $MINE, 'loginPage__cookie_classic__renders_classic';

  # Resolution happens once at startup; the per-request choice reads the
  # result, so changing it here stands in for a deployment that set mine.
  setting('_default_web_ui' => 'mine');
  like $page->(), $MINE, 'loginPage__no_cookie_default_mine__renders_mine';
  unlike $page->('nd_web_ui=classic'), $MINE,
    'loginPage__cookie_classic_default_mine__the_browser_choice_wins';
  like $page->('nd_web_ui=bogus'), $MINE, 'loginPage__bad_cookie_default_mine__falls_back_to_mine';
  setting('_default_web_ui' => 'classic');

  my $css = $cb->(GET '/mine/mine.css');
  is $css->code, 200, 'siteLocalPublic__interface_directory__is_served';
  like $css->content, qr/#123456/, 'siteLocalPublic__interface_directory__is_the_sites_file';
  like $css->header('Content-Type'), qr{^text/css}, 'siteLocalPublic__interface_directory__is_served_as_css';

  # the interface's plugin brought a route
  local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';

  # The switch needs a session; without one AuthN sends the browser to log in
  # and no interface cookie is set.
  my $switch = $cb->(POST '/web_ui', [ ui => 'mine' ]);
  unlike join("\n", $switch->header('Set-Cookie')), qr/nd_web_ui=/,
    'webUiSwitch__no_session__sets_no_interface_cookie';
};

ok( (grep { m{^/ajax/xt/mine$} } map { "$_->{pattern}" }
      @{ Dancer::App->current->registry->routes('get') || [] }),
  'loadWebUis__site_plugin_of_the_interface__is_loaded' );

done_testing;
