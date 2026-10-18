#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use JSON::PP ();

# The data the modern interface's scripts read: one handler per resource,
# served at /ajax/data/v2/... to a signed in XMLHttpRequest only, and nowhere
# else. These are the interface's own (App::Netdisco::Web::UI::Modern::Data),
# not an API: no /api/v2 route, nothing in the Swagger document.
#
# The real routes all read the database, which a test cannot have (xt/36), so
# the handler side is driven through an echo route registered the same way.
# Only an /ajax/ address can answer here: a route registered after the app has
# loaded comes after its catch-all for every other path.
#
# no_auth gives a guest session without a user row, as in xt/76. The XHR
# header goes in through the environment, see xt/57 for why.

BEGIN { $ENV{DANCER_ENVIRONMENT} = 'testing' }

use App::Netdisco;
use App::Netdisco::Web;
use App::Netdisco::Web::Data 'problem';
use App::Netdisco::Web::UI::Modern::Data 'data_route';
use Dancer qw/:syntax :tests/;
use Dancer::Test;

data_route(
  pattern => '/xt/echo/(?<thing>[^/]+)',
  code    => sub {
    my $c = shift;
    problem(418, 'No tea here', "no $c->{thing} today") if $c->{thing} eq 'tea';
    return { data => { thing => $c->{thing}, list => [], none => undef }, meta => { n => 1 } };
  },
);

setting('no_auth' => 1);

my $json = JSON::PP->new;
sub xhr_get { local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest'; dancer_response(GET => shift) }

subtest 'dataRoute__xhr_with_a_session__answers_the_envelope' => sub {
  my $r = xhr_get('/ajax/data/v2/xt/echo/hello');
  is $r->status, 200, 'answered';
  like $r->header('Content-Type'), qr{^application/json}, 'as JSON';
  is_deeply $json->decode($r->content),
    { data => { thing => 'hello', list => [], none => undef }, meta => { n => 1 } },
    'the handler data as returned, empty list and null kept';
};

subtest 'dataRoute__without_the_xhr_header__is_not_served' => sub {
  # the header is what another origin cannot send without CORS, so a page
  # elsewhere cannot read this through the user's cookie
  my $r = dancer_response(GET => '/ajax/data/v2/xt/echo/hello');
  isnt $r->status, 200, 'not answered';
  unlike $r->content // '', qr/"thing"/, 'and the data is not in the response';
};

subtest 'problem__raised_by_the_handler__becomes_an_error_document' => sub {
  my $r = xhr_get('/ajax/data/v2/xt/echo/tea');
  is $r->status, 418, 'with the status it names';
  like $r->header('Content-Type'), qr{^application/json}, 'as JSON';
  is_deeply $json->decode($r->content),
    { type => 'about:blank', title => 'No tea here', status => 418, detail => 'no tea today' },
    'in the RFC 9457 shape';
};

subtest 'dataRoutes__every_resource__is_routed_for_the_browser' => sub {
  local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
  foreach my $path ('/devices', '/summary', '/search', '/me/jobs', '/devices/10.0.0.1', '/devices/10.0.0.1/vlans',
                    '/devices/10.0.0.1/ports', '/devices/10.0.0.1/ports/Gi1/0/1',
                    '/devices/10.0.0.1/ports/Gi1/0/1/nodes', '/devices/10.0.0.1/ports/Gi1/0/1/log') {
    route_exists [ GET => "/ajax/data/v2$path" ], "GET /ajax/data/v2$path";
  }
};

subtest 'noApi__nothing_is_routed_or_documented_under_api_v2' => sub {
  # the catch-all answers any path, so what is checked is that no route of
  # its own was registered for /api/v2
  my @v2 = grep { "$_->{pattern}" =~ m{/api/v2} }
           map { @{ Dancer::App->current->registry->routes($_) || [] } } qw/get post put delete any/;
  is scalar @v2, 0, 'no /api/v2 route';
  my $doc = Dancer::Plugin::Swagger->instance->doc;
  is_deeply [ grep { m{^/api/v2/} } keys %{ $doc->{paths} } ], [], 'no /api/v2 path in the Swagger document';
  ok !grep({ $_->{name} eq 'Objects v2' } @{ $doc->{tags} || [] }), 'and no tag for one';
};

subtest 'devicesPage__is_routed' => sub {
  # Rendering a whole page reads the ACL names from the database in a hook that
  # runs for every page request, which a test cannot have (xt/36), so the page
  # is checked here by its route and in xt/152 by its template.
  route_exists [ GET => '/devices' ], 'GET /devices';
};

done_testing;
