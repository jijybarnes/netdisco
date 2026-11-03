#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Spec::Functions qw/catdir catfile updir/;
use File::Path 'make_path';
use FindBin;
use File::Temp ();

# template_paths and nd-site-local override every template by relative path,
# and Dancer looks for a layout only under the views setting, so a layout was
# the one thing they could not override. NetdiscoTemplateToolkit searches the
# layouts along INCLUDE_PATH now. Here a site layout is the only site-local
# file and no web interface is named: the change is for every site.
my ($envdir, $site);
BEGIN {
  $ENV{DANCER_PUBLIC} ||= catdir($FindBin::Bin, updir(), 'share', 'public');

  $site = File::Temp->newdir(CLEANUP => 1);
  make_path(catdir("$site", 'views', 'layouts'));
  open my $layout, '>', catfile("$site", 'views', 'layouts', 'main.tt')
    or die "cannot write the layout: $!";
  print $layout qq{<html data-xt-site-layout="1"><body>[% content | none %]</body></html>\n};
  close $layout;

  $envdir = File::Temp->newdir(CLEANUP => 1);
  open my $env, '>', catfile("$envdir", 'testing.yml')
    or die "cannot write the test environment file: $!";
  print $env "template_paths: ['" . catdir("$site", 'views') . "']\n";
  close $env;

  $ENV{DANCER_ENVDIR} = "$envdir";
  $ENV{DANCER_ENVIRONMENT} = 'testing';
}

use Plack::Test;
use Plack::Util;
use HTTP::Request::Common;
use Dancer::Template::NetdiscoTemplateToolkit;

my $app = eval { Plack::Util::load_psgi(catfile($FindBin::Bin, updir(), 'bin', 'netdisco-web-fg')) };
BAIL_OUT("could not load the app: $@") unless $app;

test_psgi $app, sub {
  my $cb = shift;
  my $page = $cb->(GET '/login')->content;
  like $page, qr/data-xt-site-layout="1"/, 'layout__main_in_template_paths__is_used';
  like $page, qr/Welcome to Netdisco/, 'layout__main_in_template_paths__still_wraps_the_page';
  unlike $page, qr/class="navbar /, 'layout__main_in_template_paths__replaces_the_shipped_one';
};

# the order: the interface's directories first, then the site's
my ($first, $second) = map { File::Temp->newdir(CLEANUP => 1) } 1 .. 2;
foreach my $dir ($first, $second) {
  make_path(catdir("$dir", 'layouts'));
  open my $fh, '>', catfile("$dir", 'layouts', 'main.tt') or die $!;
  close $fh;
}
my @rendered;
{
  no warnings 'redefine';
  local *Dancer::Template::NetdiscoTemplateToolkit::render = sub { push @rendered, $_[1]; 'x' };
  my $engine = bless { config => { INCLUDE_PATH => [ sub { [ "$first" ] }, "$second" ] } },
    'Dancer::Template::NetdiscoTemplateToolkit';
  $engine->layout('main', {}, 'content');
}
is_deeply \@rendered, [ catfile("$first", 'layouts', 'main.tt') ],
  'layout__in_two_include_paths__the_first_wins';

done_testing;
