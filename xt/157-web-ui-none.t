#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Spec::Functions qw/catdir catfile updir/;
use FindBin;
use File::Temp ();

# An interface is only there if web_uis names it. With none named, the app is
# the classic one alone: no modern route, no modern pane in front of the
# classic one, and a browser still carrying the modern cookie gets classic
# pages. The whole app is loaded, as in xt/141, with web_uis emptied.

my $envdir;
BEGIN {
  $ENV{DANCER_PUBLIC} ||= catdir($FindBin::Bin, updir(), 'share', 'public');
  $envdir = File::Temp->newdir(CLEANUP => 1);
  open my $env, '>', catfile("$envdir", 'testing.yml')
    or die "cannot write the test environment file: $!";
  print $env "default_web_ui: 'modern'\nweb_uis: []\n";
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
ok !App::Netdisco::Web::UI::valid_web_ui('modern'), 'noWebUis__modern__not_an_interface';
is Dancer::Config::setting('_default_web_ui'), 'classic',
  'noWebUis__default_naming_modern__falls_back_to_classic';
ok !$INC{'App/Netdisco/Web/UI/Modern.pm'}, 'noWebUis__modern_module__not_loaded';
# the normalized data is the modern interface's own: the core reads none of it
is_deeply [ grep { m{^App/Netdisco/Web/(?:UI/Modern|Data)\b} } keys %INC ], [],
  'noWebUis__modern_data_library__not_loaded';

my @routes = map { @{ Dancer::App->current->registry->routes($_) || [] } } qw/get post/;
is scalar(grep { "$_->{pattern}" =~ m{/ajax/data/v2} } @routes), 0, 'noWebUis__no_data_route';
is scalar(grep { "$_->{pattern}" eq '/ajax/content/device/ports' } @routes), 1, 'noWebUis__ports__the_classic_route_alone';
is scalar(grep { "$_->{pattern}" eq '/devices' } @routes), 0, 'noWebUis__no_devices_page';

test_psgi $app, sub {
  my $cb = shift;
  my $page = $cb->(GET '/login', Cookie => 'nd_web_ui=modern')->content;
  unlike $page, qr/data-nd-ui="modern"/, 'noWebUis__modern_cookie__gets_classic_pages';
  like $page, qr/class="navbar /, 'noWebUis__modern_cookie__the_classic_navbar';
  unlike $page, qr/nd_web-ui-switch/, 'noWebUis__no_other_interface__no_switch_offered';
};

done_testing;
