#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Spec::Functions qw/catdir catfile updir/;
use FindBin;
use File::Temp ();

# A default_web_ui that names no interface must not stop the web frontend from
# starting: it warns once at startup and every browser without a cookie gets
# the classic interface, as if the setting were absent.
my $envdir;
BEGIN {
  $ENV{DANCER_PUBLIC} ||= catdir($FindBin::Bin, updir(), 'share', 'public');

  $envdir = File::Temp->newdir(CLEANUP => 1);
  open my $env, '>', catfile("$envdir", 'testing.yml')
    or die "cannot write the test environment file: $!";
  print $env "default_web_ui: 'shiny'\n";
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

test_psgi $app, sub {
  my $cb = shift;
  unlike $cb->(GET '/login')->content, qr/data-nd-ui="modern"/,
    'loginPage__unknown_default_no_cookie__renders_classic';
  like $cb->(GET '/login', Cookie => 'nd_web_ui=modern')->content, qr/data-nd-ui="modern"/,
    'loginPage__unknown_default_cookie_modern__still_honours_the_browser_choice';
};

done_testing;
