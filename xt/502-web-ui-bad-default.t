#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Spec::Functions qw/catdir catfile updir/;
use FindBin;
use File::Temp ();

# A default_web_ui that names no interface, a web_uis entry that is no
# interface name, and one whose views-NAME directory is nowhere must not stop
# the web frontend from starting: each warns once at startup and the classic
# interface is what every browser without a cookie gets, as if the setting were
# absent.
my $envdir;
BEGIN {
  $ENV{DANCER_PUBLIC} ||= catdir($FindBin::Bin, updir(), 'share', 'public');

  $envdir = File::Temp->newdir(CLEANUP => 1);
  open my $env, '>', catfile("$envdir", 'testing.yml')
    or die "cannot write the test environment file: $!";
  print $env "default_web_ui: 'shiny'\nweb_uis: ['ghost', '../evil', 'classic']\n";
  close $env;

  $ENV{DANCER_ENVDIR} = "$envdir";
  $ENV{DANCER_ENVIRONMENT} = 'testing';
}

use Plack::Test;
use Plack::Util;
use HTTP::Request::Common;

# The console logger prints to STDERR rather than calling warn.
my $stderr_file = File::Temp->new;
open my $saved_stderr, '>&', \*STDERR or die "cannot save STDERR: $!";
open STDERR, '>', "$stderr_file" or die "cannot redirect STDERR: $!";
my $psgi = catfile($FindBin::Bin, updir(), 'bin', 'netdisco-web-fg');
my $app  = eval { Plack::Util::load_psgi($psgi) };
open STDERR, '>&', $saved_stderr or die "cannot restore STDERR: $!";
BAIL_OUT("could not load $psgi: $@") unless $app;

my $logged = do { local $/; open my $fh, '<', "$stderr_file" or die $!; <$fh> };

sub setting { return Dancer::Config::setting(@_) }

like $logged, qr/default_web_ui is 'shiny'/,
  'resolveDefaultWebUi__unknown_name__warns_at_startup';
is setting('_default_web_ui'), 'classic',
  'resolveDefaultWebUi__unknown_name__falls_back_to_classic';

like $logged, qr/web_uis names 'ghost' but no views-ghost directory was found/,
  'setupWebUis__no_views_directory__warns_at_startup';
like $logged, qr/web_uis entry '\.\.\/evil' is not an interface name/,
  'loadWebUis__name_that_is_a_path__is_refused';
like $logged, qr/web_uis entry 'classic' is not an interface name/,
  'loadWebUis__classic__is_refused_as_it_is_built_in';
is_deeply [ App::Netdisco::Web::UI::web_ui_names() ], ['classic'],
  'setupWebUis__nothing_usable__leaves_classic_alone';

test_psgi $app, sub {
  my $cb = shift;
  like $cb->(GET '/login')->content, qr/class="navbar /,
    'loginPage__unusable_interfaces__renders_classic';
  like $cb->(GET '/login', Cookie => 'nd_web_ui=ghost')->content, qr/class="navbar /,
    'loginPage__cookie_naming_a_left_out_interface__renders_classic';
};

done_testing;
