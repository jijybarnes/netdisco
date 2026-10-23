#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;

# A web interface replaces a pane by registering a route for the pane's own
# path in front of the core's one, and passing the request on when the browser
# uses another interface (App::Netdisco::Web::UI::Modern::Ports does this for
# the Ports tab). That leans on two things Dancer does, pinned here:
#
# - pass runs the next route that matches, whatever its options;
# - with route_cache on (share/config.yml), the cache keeps the first route
#   that matched a path, which is the interface's, and that route decides
#   again on every request: a classic browser after a modern one, or the other
#   way round, still gets its own pane.
#
# The probe routes are registered here so the test needs no database. They
# are under /ajax/, which a route registered after the app has loaded can
# still answer (see xt/145).

# The probe decides on a query parameter rather than on the nd_web_ui cookie,
# which Dancer::Test cannot send: what is pinned is how Dancer runs and caches
# the two routes, and the cache is keyed on the path alone, so the parameter
# does not change what it holds. xt/141 checks that the cookie picks the
# interface, through the whole app.

BEGIN { $ENV{DANCER_ENVIRONMENT} = 'testing' }

use App::Netdisco;
use App::Netdisco::Web;
use Dancer qw/:syntax :tests/;
use Dancer::Test;

setting('no_auth' => 1);
setting('route_cache' => 1);

# in front: answers only for the modern interface. Dancer::pass by its full
# name: Test::More exports a pass of its own, which would win here and record
# a passing test instead of passing the request on.
get '/ajax/xt/pane' => sub {
  Dancer::pass() unless (param('ui') // '') eq 'modern';
  return 'modern pane';
};
# the core's
get '/ajax/xt/pane' => sub { return 'classic pane' };

my @asked = qw/modern classic classic modern classic modern modern classic/;
my @answers = map {
  local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
  dancer_response(GET => "/ajax/xt/pane?ui=$_")->content
} @asked;
is_deeply \@answers, [ map { "$_ pane" } @asked ],
  'routeInFront__alternating_interfaces_with_route_cache__each_gets_its_own_pane';

# the real Ports tab: two routes for its path, the interface's first, because
# the interfaces are loaded before the web plugins
my @ports = grep { "$_->{pattern}" eq '/ajax/content/device/ports' }
            @{ Dancer::App->current->registry->routes('get') || [] };
is scalar @ports, 2, 'portsTab__two_routes__the_modern_interface_and_the_classic_tab';

my $web = do {
  local $/;
  open my $fh, '<', $INC{'App/Netdisco/Web.pm'} or die $!;
  <$fh>;
};
ok index($web, 'load_web_uis()') > 0 && index($web, 'load_web_uis()') < index($web, '_load_web_plugins( setting'),
  'webPm__interfaces__loaded_before_the_web_plugins';

done_testing;
