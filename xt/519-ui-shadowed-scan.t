#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use File::Path 'make_path';
use File::Spec::Functions qw/catdir catfile/;
use File::Temp ();

use App::Netdisco::Util::SiteLocal qw/scan_ui_shadowed ui_dirs_for/;

# A web interface draws some pages from other data than the classic ones, so a
# site's classic override of such a page changes nothing for a browser using
# the interface. Finding those is what scan_ui_shadowed is for, at web startup
# and in `netdisco-do checksitelocal`.

sub touch {
  my $file = catfile(@_);
  my ($dir) = $file =~ m{^(.*)/[^/]+$};
  make_path($dir);
  open my $fh, '>', $file or die "cannot write $file: $!";
  close $fh;
}

my $root = File::Temp->newdir(CLEANUP => 1);
my $core = catdir("$root", 'share', 'views-mine');
touch($core, 'device.tt');
touch($core, 'layouts', 'main.tt');
touch($core, 'ajax', 'device', 'ports.tt');

my $site = catdir("$root", 'site', 'share');
my $views = catdir($site, 'views');
touch($views, 'device.tt');            # shadowed: the interface draws device.tt
touch($views, 'layouts', 'main.tt');   # a layout counts, too
touch($views, 'search.tt');            # not drawn by the interface
touch($views, 'ajax', 'device', 'ports.tt');
touch($site, 'views-mine', 'ajax', 'device', 'ports.tt'); # answered for the interface

# beside a directory named views, else inside the directory
is_deeply [ ui_dirs_for('mine', $views, $site, "$root/nowhere", undef, '') ],
  [ catdir($site, 'views-mine') ], 'uiDirsFor__views_and_its_parent__is_one_existing_directory_once';

my @found = scan_ui_shadowed({ name => 'mine', core => $core, paths => [ $views ] });
is_deeply [ map { $_->{path} } @found ],
  [ catfile($views, 'device.tt'), catfile($views, 'layouts', 'main.tt') ],
  'scanUiShadowed__classic_overrides_of_what_the_interface_draws__are_found_sorted';
ok !(grep { $_->{path} =~ m{ports\.tt$} } @found),
  'scanUiShadowed__override_for_the_interface_too__is_not_reported';
ok !(grep { $_->{path} =~ m{search\.tt$} } @found),
  'scanUiShadowed__template_the_interface_does_not_draw__is_not_reported';

my $first = $found[0];
is $first->{rule}, 'ui-shadowed', 'scanUiShadowed__finding__names_its_rule';
is $first->{kind}, 'file', 'scanUiShadowed__finding__is_a_file_finding';
ok $first->{release}, 'scanUiShadowed__finding__cites_a_release';
like $first->{advice}, qr/mine.*device\.tt.*views-mine/s, 'scanUiShadowed__finding__names_the_interface_template_and_directory';

is_deeply [ scan_ui_shadowed({ name => 'mine', core => undef, paths => [ $views ] }) ], [],
  'scanUiShadowed__interface_with_nothing_shipped__finds_nothing';
is_deeply [ scan_ui_shadowed({ name => 'mine', core => $core, paths => [ "$root/nowhere" ] }) ], [],
  'scanUiShadowed__missing_directory__is_skipped';

done_testing;
