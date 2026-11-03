#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Spec::Functions qw/catdir catfile updir/;
use FindBin;
use File::Temp ();

# An interface is only there if web_uis names it. With none named, the app is
# the classic one alone: no switch offered, and a browser still carrying an
# interface cookie gets classic pages. The whole app is loaded, as in xt/501,
# with web_uis emptied and a default that names an interface.

my $envdir;
BEGIN {
  $ENV{DANCER_PUBLIC} ||= catdir($FindBin::Bin, updir(), 'share', 'public');
  $envdir = File::Temp->newdir(CLEANUP => 1);
  open my $env, '>', catfile("$envdir", 'testing.yml')
    or die "cannot write the test environment file: $!";
  print $env "default_web_ui: 'mine'\nweb_uis: []\n";
  close $env;
  $ENV{DANCER_ENVDIR} = "$envdir";
  $ENV{DANCER_ENVIRONMENT} = 'testing';
}

use Plack::Test;
use Plack::Util;
use HTTP::Request::Common;

my $app = eval { Plack::Util::load_psgi(catfile($FindBin::Bin, updir(), 'bin', 'netdisco-web-fg')) };
BAIL_OUT("could not load the app: $@") unless $app;

# by their full names, after the load: a use here would load the module, and
# Dancer's auth plugin with it, before the app has read its configuration
is_deeply [ App::Netdisco::Web::UI::web_ui_names() ], ['classic'], 'noWebUis__names__classic_alone';
ok !App::Netdisco::Web::UI::valid_web_ui('mine'), 'noWebUis__mine__not_an_interface';
is Dancer::Config::setting('_default_web_ui'), 'classic',
  'noWebUis__default_naming_an_interface__falls_back_to_classic';
is_deeply Dancer::Config::setting('web_uis'), [], 'noWebUis__shipped_config__bundles_no_interface';

test_psgi $app, sub {
  my $cb = shift;
  my $page = $cb->(GET '/login', Cookie => 'nd_web_ui=mine')->content;
  like $page, qr/class="navbar /, 'noWebUis__interface_cookie__gets_classic_pages';
  unlike $page, qr/nd_web-ui-switch/, 'noWebUis__no_other_interface__no_switch_offered';
};

done_testing;
