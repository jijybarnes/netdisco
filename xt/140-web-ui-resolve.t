#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Temp ();
use File::Spec::Functions 'catfile';

use App::Netdisco::Web::UI qw/web_ui_names valid_web_ui safe_back_path back_from_referer/;
use Dancer::Template::NetdiscoTemplateToolkit;

# The interface is chosen by a cookie the browser sends, so everything that
# reads it has to treat it as untrusted: a value that is not a known interface
# name must never pick a views directory.

is_deeply [ web_ui_names() ], [qw/classic modern/],
  'webUiNames__shipped__are_classic_and_modern_in_order';

ok valid_web_ui($_), "validWebUi__${_}__is_accepted" for qw/classic modern/;

foreach my $bad (undef, '', 'Modern', 'modern ', '../modern', 'views-modern', "modern\n") {
  my $label = defined $bad ? ($bad =~ s/\n/\\n/r) : 'undef';
  ok !valid_web_ui($bad), "validWebUi__${label}__is_refused";
}
ok !valid_web_ui(['modern']), 'validWebUi__array_ref__is_refused';

# The switch redirects to this after setting the cookie, so anything that
# leaves the site would make the switch an open redirect.
is safe_back_path('/device?q=10.0.0.1&tab=ports'), '/device?q=10.0.0.1&tab=ports',
  'safeBackPath__local_path_with_query__is_kept';
is safe_back_path('/t/branch/inventory'), '/t/branch/inventory',
  'safeBackPath__tenant_path__is_kept';
foreach my $bad (undef, '', 'device', '//evil.example/x', '/\\evil.example',
                 'https://evil.example/', "/ok\r\nSet-Cookie: x=1") {
  my $label = defined $bad ? ($bad =~ s/[\r\n]/_/gr) : 'undef';
  is safe_back_path($bad), undef, "safeBackPath__${label}__is_refused";
}

# The page to return to comes from the Referer of the switch's POST, and only
# when that page is on this site.
my $base = 'http://nd.example:5000/';
is back_from_referer('http://nd.example:5000/device?q=10.0.0.1&tab=ports', $base),
  '/device?q=10.0.0.1&tab=ports', 'backFromReferer__page_of_this_site__returns_its_path_and_query';
is back_from_referer('https://ND.example/t/branch/inventory', $base), '/t/branch/inventory',
  'backFromReferer__same_host_other_scheme_and_port__is_still_this_site';
foreach my $case (
  [ 'http://evil.example:5000/device', 'another_host' ],
  [ 'http://nd.example.evil.example/device', 'a_host_ending_like_ours' ],
  [ 'nd.example/device', 'not_absolute' ],
  [ 'javascript:alert(1)', 'not_http' ],
  [ '', 'empty' ],
  [ undef, 'absent' ],
) {
  is back_from_referer($case->[0], $base), undef, "backFromReferer__$case->[1]__is_refused";
}

my $msg = App::Netdisco::Web::UI::default_web_ui_message('shiny');
like $msg, qr/default_web_ui/, 'defaultWebUiMessage__unknown_name__names_the_setting';
like $msg, qr/'shiny'/, 'defaultWebUiMessage__unknown_name__quotes_the_value';
like $msg, qr/classic, modern/, 'defaultWebUiMessage__unknown_name__lists_the_valid_names';

# The engine resolves the top-level view itself, before Template Toolkit sees
# it, so it has to expand a code ref in INCLUDE_PATH the way Template Toolkit
# does for INCLUDE: in order, in place, and an empty answer adds nothing.
my $overlay = File::Temp->newdir(CLEANUP => 1);
my $classic = File::Temp->newdir(CLEANUP => 1);
foreach my $file (catfile("$overlay", 'device.tt'),
                  catfile("$classic", 'device.tt'),
                  catfile("$classic", 'search.tt')) {
  open my $fh, '>', $file or die "cannot write $file: $!";
  print $fh "x\n";
  close $fh;
}

my $overlay_on = 1;
my $engine = bless { config => { INCLUDE_PATH => [
  sub { $overlay_on ? [ "$overlay" ] : [] },
  "$classic",
] } }, 'Dancer::Template::NetdiscoTemplateToolkit';

is_deeply [ $engine->_search_paths ], [ "$overlay", "$classic" ],
  'searchPaths__code_ref_entry__is_expanded_in_place';
is $engine->view('device'), catfile("$overlay", 'device.tt'),
  'view__template_in_the_overlay__is_taken_from_the_overlay';
is $engine->view('search'), catfile("$classic", 'search.tt'),
  'view__template_missing_from_the_overlay__falls_through_to_classic';

$overlay_on = 0;
is_deeply [ $engine->_search_paths ], [ "$classic" ],
  'searchPaths__code_ref_returning_nothing__adds_nothing';
is $engine->view('device'), catfile("$classic", 'device.tt'),
  'view__overlay_switched_off__resolves_the_classic_template';

done_testing;
