#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Spec::Functions qw/catdir catfile updir/;
use FindBin;
use File::Temp ();

# The interface a page renders in comes from the nd_web_ui cookie, else from
# default_web_ui. The pages that need a session cannot be driven here (the auth
# provider is DBIC, see xt/36), so this goes through the login page, which is
# rendered in the same main layout and is the one page every browser sees.
my $envdir;
BEGIN {
  $ENV{DANCER_PUBLIC} ||= catdir($FindBin::Bin, updir(), 'share', 'public');

  $envdir = File::Temp->newdir(CLEANUP => 1);
  open my $env, '>', catfile("$envdir", 'testing.yml')
    or die "cannot write the test environment file: $!";
  print $env "default_web_ui: 'classic'\n";
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

sub setting { return Dancer::Config::setting(@_) }

is setting('_default_web_ui'), 'classic',
  'resolveDefaultWebUi__configured_classic__is_recorded_at_startup';

my $MODERN = qr/<html [^>]*data-nd-ui="modern"/;

test_psgi $app, sub {
  my $cb = shift;
  my $page = sub { $cb->(GET '/login', (@_ ? (Cookie => shift) : ()))->content };

  my $plain = $page->();
  unlike $plain, $MODERN, 'loginPage__no_cookie_default_classic__renders_classic';
  like $plain, qr/class="navbar /, 'loginPage__no_cookie_default_classic__has_the_classic_navbar';

  my $modern = $page->('nd_web_ui=modern');
  like $modern, $MODERN, 'loginPage__cookie_modern__renders_the_modern_layout';
  like $modern, qr/class="nd2-topbar"/, 'loginPage__cookie_modern__has_the_modern_top_bar';
  like $modern, qr{/modern/css/modern\.css\?v=}, 'loginPage__cookie_modern__links_the_modern_stylesheet';
  # the modern index.tt, with the hooks netdisco.js signs in through
  like $modern, qr/<form class="nd_login-form nd2-login-form" method="post" action="[^"]*\/login">/,
    'loginPage__cookie_modern__shows_the_modern_login_form';
  like $modern, qr/id="loginuser"[^>]*name="username"/, 'loginPage__cookie_modern__keeps_the_username_field_netdisco_js_focuses';

  unlike $page->('nd_web_ui=../views-modern'), $MODERN,
    'loginPage__cookie_not_an_interface_name__falls_back_to_the_default';
  unlike $page->('nd_web_ui=classic'), $MODERN,
    'loginPage__cookie_classic__renders_classic';

  # Resolution happens once at startup; the per-request choice reads the
  # result, so changing it here stands in for a deployment that set modern.
  setting('_default_web_ui' => 'modern');
  like $page->(), $MODERN, 'loginPage__no_cookie_default_modern__renders_modern';
  unlike $page->('nd_web_ui=classic'), $MODERN,
    'loginPage__cookie_classic_default_modern__the_browser_choice_wins';
  like $page->('nd_web_ui=bogus'), $MODERN,
    'loginPage__bad_cookie_default_modern__falls_back_to_modern';
  setting('_default_web_ui' => 'classic');

  my $css = $cb->(GET '/modern/css/modern.css');
  is $css->code, 200, 'modernStylesheet__no_session__is_served';
  like $css->header('Content-Type'), qr{^text/css}, 'modernStylesheet__no_session__is_served_as_css';

  # The switch needs a session; without one AuthN sends the browser to log in
  # and no interface cookie is set.
  my $switch = $cb->(POST '/web_ui', [ ui => 'modern' ]);
  unlike join("\n", $switch->header('Set-Cookie')), qr/nd_web_ui=/,
    'webUiSwitch__no_session__sets_no_interface_cookie';
};

done_testing;
