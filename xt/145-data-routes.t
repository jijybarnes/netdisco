#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use JSON::PP ();

# register_data_route serves one handler at two addresses, and that is what
# lets the modern interface and an API client see the same JSON. The real v2
# routes all read the database, which a test cannot have (xt/36), so the
# handler side is driven through an echo route registered the same way.
#
# Only the echo's /ajax/ address can answer here: a route registered after the
# app has loaded comes after its catch-all for every non-/ajax/ path, and one
# registered before it does not survive the load. The /api/v2 side is checked
# on the real routes instead, by their being routed and documented.
#
# no_auth gives a guest session without a user row, as in xt/76. The XHR
# header goes in through the environment, see xt/57 for why.

BEGIN { $ENV{DANCER_ENVIRONMENT} = 'testing' }

use App::Netdisco;
use App::Netdisco::Web;
use App::Netdisco::Web::Data qw/register_data_route problem/;
use Dancer qw/:syntax :tests/;
use Dancer::Test;

register_data_route(
  pattern  => '/xt/echo/(?<thing>[^/]+)',
  doc_path => '/xt/echo/{thing}',
  doc      => { description => 'xt echo', responses => { default => {} } },
  code     => sub {
    my $c = shift;
    problem(418, 'No tea here', "no $c->{thing} today") if $c->{thing} eq 'tea';
    return { data => { thing => $c->{thing}, list => [], none => undef }, meta => { n => 1 } };
  },
);

setting('no_auth' => 1);

my $json = JSON::PP->new;
sub xhr_get { local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest'; dancer_response(GET => shift) }

subtest 'ajaxAddress__xhr_with_a_session__answers_the_envelope' => sub {
  my $r = xhr_get('/ajax/data/v2/xt/echo/hello');
  is $r->status, 200, 'answered';
  like $r->header('Content-Type'), qr{^application/json}, 'as JSON';
  is_deeply $json->decode($r->content),
    { data => { thing => 'hello', list => [], none => undef }, meta => { n => 1 } },
    'the handler data as returned, empty list and null kept';
};

subtest 'ajaxAddress__without_the_xhr_header__is_not_served' => sub {
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

subtest 'swagger__v2_routes__are_documented_under_their_own_tag' => sub {
  my $doc = Dancer::Plugin::Swagger->instance->doc;
  my @v2 = sort grep { m{^/api/v2/} } keys %{ $doc->{paths} };
  is_deeply [ grep { m{/devices/} } @v2 ], [
    '/api/v2/devices/{ip}',
    '/api/v2/devices/{ip}/ports',
    '/api/v2/devices/{ip}/ports/{port}',
    '/api/v2/devices/{ip}/ports/{port}/log',
    '/api/v2/devices/{ip}/ports/{port}/nodes',
    '/api/v2/devices/{ip}/vlans',
  ], 'the device and port resources, braces unencoded';
  is_deeply $doc->{paths}{'/api/v2/xt/echo/{thing}'}{get}{tags}, ['Objects v2'],
    'tagged Objects v2';
  ok scalar(grep { $_->{name} eq 'Objects v2' } @{ $doc->{tags} }), 'and the tag is declared';
};

subtest 'jobsRoute__both_addresses__are_routed_and_documented' => sub {
  route_exists [ GET => '/api/v2/me/jobs' ], 'GET /api/v2/me/jobs';
  { local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
    route_exists [ GET => '/ajax/data/v2/me/jobs' ], 'GET /ajax/data/v2/me/jobs'; }
  my $doc = Dancer::Plugin::Swagger->instance->doc;
  ok $doc->{paths}{'/api/v2/me/jobs'}{get}, 'documented, with its path as the API shows it';
  is_deeply [ map { $_->{name} } grep { ref {} eq ref $_ } @{ $doc->{paths}{'/api/v2/me/jobs'}{get}{parameters} } ],
    ['limit'], 'with its limit parameter';
};

subtest 'searchRoute__both_addresses__are_routed_and_documented' => sub {
  route_exists [ GET => '/api/v2/search' ], 'GET /api/v2/search';
  { local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
    route_exists [ GET => '/ajax/data/v2/search' ], 'GET /ajax/data/v2/search'; }
  my $doc = Dancer::Plugin::Swagger->instance->doc;
  is_deeply [ map { $_->{name} } grep { ref {} eq ref $_ } @{ $doc->{paths}{'/api/v2/search'}{get}{parameters} } ],
    ['q'], 'documented with its q parameter';
};

subtest 'devicesListRoute__both_addresses__are_routed_and_documented' => sub {
  route_exists [ GET => '/api/v2/devices' ], 'GET /api/v2/devices';
  { local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
    route_exists [ GET => '/ajax/data/v2/devices' ], 'GET /ajax/data/v2/devices'; }
  my $get = Dancer::Plugin::Swagger->instance->doc->{paths}{'/api/v2/devices'}{get};
  ok $get, 'documented';
  is_deeply [ map { $_->{name} } grep { ref {} eq ref $_ } @{ $get->{parameters} } ],
    [qw/q health sort dir limit offset/], 'with every parameter it reads';
};

subtest 'devicesPage__is_routed' => sub {
  # Rendering a whole page reads the ACL names from the database in a hook that
  # runs for every page request, which a test cannot have (xt/36), so the page
  # is checked here by its route and in xt/152 by its template.
  route_exists [ GET => '/devices' ], 'GET /devices';
};

subtest 'deviceRoutes__both_addresses__are_routed' => sub {
  foreach my $path ('/devices/10.0.0.1', '/devices/10.0.0.1/ports',
                    '/devices/10.0.0.1/ports/Gi1/0/1', '/devices/10.0.0.1/ports/Gi1/0/1/nodes') {
    route_exists [ GET => "/api/v2$path" ], "GET /api/v2$path";
    { local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
      route_exists [ GET => "/ajax/data/v2$path" ], "GET /ajax/data/v2$path"; }
  }
};

done_testing;
