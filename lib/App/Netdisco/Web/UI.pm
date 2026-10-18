package App::Netdisco::Web::UI;

use Dancer ':syntax';
use Dancer::Plugin::Auth::Extensible;
use Path::Class 'dir';
use Module::Load ();
use URI;
use Try::Tiny;

use base 'Exporter';
our @EXPORT_OK = qw/
  register_web_ui web_ui web_ui_names valid_web_ui current_web_ui
  ui_include_paths ui_dirs_for ui_shadowed_overrides web_ui_module
  safe_back_path back_from_referer
/;

=head1 NAME

App::Netdisco::Web::UI - web interfaces, and choosing between them

=head1 DESCRIPTION

Netdisco's web pages can be drawn by more than one interface. The classic one
is F<share/views> itself. Any other is a directory of views laid over it: a
template the interface does not provide falls through to the classic one, so
an interface can redraw the pages it wants and leave the rest as they are,
inside its own layout.

An interface other than classic comes as a module, named in C<web_uis> (or a
site's C<extra_web_uis>) the way web plugins are named in C<web_plugins>:
C<Modern> is C<App::Netdisco::Web::UI::Modern>, C<X::Mine> is
C<App::NetdiscoX::Web::UI::Mine> (looked for under F<site_plugins> too), and
C<+Some::Module> is that module. The module calls L</register_web_ui> and
brings whatever else the interface needs on the server: routes of its own,
hooks that hand its templates more data. The core routes do not know about
it.

By convention an interface named C<mine> keeps its templates in
F<views-mine> and its scripts and styles under F</mine/> in the public
directory. A site (C<template_paths>) or a web plugin
(C<register_template_path>) overrides its templates from a F<views-mine>
directory beside its F<views> one.

C<default_web_ui> names the interface a browser gets until its user picks one.
The pick is kept in the C<nd_web_ui> cookie rather than in the users table, so
it needs no schema change, follows the browser rather than the account, and is
lost harmlessly when the cookie is.

=cut

use constant COOKIE => 'nd_web_ui';

# name => { name, views, switch_label, switch_title, overrides }
my %UI = (
  classic => { name => 'classic', views => undef },
);

=head1 FUNCTIONS

=head2 register_web_ui( \%config )

Declares an interface: C<name>, the one the cookie and C<default_web_ui> use;
C<views>, its directory of templates; and, for the classic interface's menu,
C<switch_label> and C<switch_title>, what the item that moves a browser to it
says. A name already registered is replaced.

=cut

sub register_web_ui {
  my $config = shift;
  my $name = $config->{name};
  die "register_web_ui needs a name\n" unless defined $name and $name =~ m/^[a-z][a-z0-9_]*$/;
  die "the classic interface is built in\n" if $name eq 'classic';
  $UI{$name} = {
    name         => $name,
    views        => (defined $config->{views} ? "$config->{views}" : undef),
    switch_label => ($config->{switch_label} // "Try the $name interface"),
    switch_title => ($config->{switch_title} // "Switch this browser to the $name interface"),
    overrides    => [],
  };
  return $UI{$name};
}

=head2 web_ui( $name )

The interface registered under C<$name>, or C<undef>.

=cut

sub web_ui { my $name = shift; return (defined $name and not ref $name) ? $UI{$name} : undef }

sub web_ui_names { return sort keys %UI }

sub valid_web_ui {
  my $name = shift;
  return (defined $name and not ref $name and exists $UI{$name}) ? 1 : 0;
}

=head2 web_ui_module( $entry )

Pure: the module a C<web_uis> entry names, as described above.

=cut

sub web_ui_module {
  my $entry = shift;
  return undef unless defined $entry and length $entry and not ref $entry;
  return $1 if $entry =~ m/^\+(.+)$/;
  return "App::NetdiscoX::Web::UI::$1" if $entry =~ m/^X::(.+)$/;
  return "App::Netdisco::Web::UI::$entry";
}

=head2 load_web_uis()

Loads the modules C<web_uis> and C<extra_web_uis> name. One that cannot be
loaded is reported and left out rather than stopping the web server: the
classic interface works without it.

=cut

sub load_web_uis {
  my @core  = @{ (ref [] eq ref setting('web_uis')) ? setting('web_uis') : [] };
  my @extra = @{ (ref [] eq ref setting('extra_web_uis')) ? setting('extra_web_uis') : [] };
  unshift @INC, dir(($ENV{NETDISCO_HOME} || $ENV{HOME}), 'site_plugins')->stringify if @extra;

  foreach my $entry (@core, @extra) {
    my $module = web_ui_module($entry) or next;
    try { Module::Load::load($module) }
    catch { warning sprintf 'web interface %s could not be loaded: %s', $entry, $_ };
  }
}

sub default_web_ui_message {
  my $name = shift;
  return sprintf q{default_web_ui is '%s', which is not one of %s. }
    . q{The classic interface is used until it is corrected.},
    $name, join(', ', web_ui_names());
}

sub resolve_default_web_ui {
  my $name = setting('default_web_ui');
  $name = 'classic' unless defined $name and length $name;

  unless (valid_web_ui($name)) {
    warning default_web_ui_message($name);
    $name = 'classic';
  }
  setting('_default_web_ui' => $name);
}

# Outside a request (netdisco-do, the test harness) there is no browser to ask,
# so the configured default applies.
sub current_web_ui {
  my $ui = (Dancer::SharedData->request ? vars->{'web_ui'} : undef);
  return $ui || setting('_default_web_ui') || 'classic';
}

=head2 ui_include_paths

The current interface's view directories, as an array ref. It is installed as
a code ref at the front of the template engine's C<INCLUDE_PATH>, which
Template Toolkit expands on every lookup, so the overlay follows the request
rather than being fixed when the engine is built.

These are, in order: the overrides of the interface's templates (a site's,
then each plugin's, the last registered first, as for F<views>), then the
interface's own directory. A template none of them has falls through to the
classic chain behind, site, plugins, then F<share/views>, so a site or a
plugin overriding a template the interface does not draw itself is used by
every interface. The classic interface adds nothing.

=cut

sub ui_include_paths {
  my $ui = $UI{ current_web_ui() } or return [];
  return [] unless defined $ui->{views};
  return [ @{ $ui->{overrides} || [] }, $ui->{views} ];
}

=head2 ui_dirs_for( $name, @template_paths )

Where a site's templates for interface C<$name> sit, for each of its
C<template_paths>: beside a directory named F<views> (F<.../share/views> gives
F<.../share/views-NAME>), else inside it. Only those that exist, each once, in
the given order.

=cut

sub ui_dirs_for {
  my ($name, @paths) = @_;
  my %seen;
  return grep { -d $_ and not $seen{$_}++ }
         map  { my $d = dir($_);
                ($d->basename eq 'views' ? $d->parent->subdir("views-$name")
                                         : $d->subdir("views-$name"))->stringify }
         grep { defined and length } @paths;
}

=head2 ui_shadowed_overrides( \@classic_dirs, \@override_dirs, $views )

The classic overrides an interface does not use: each template under one of
C<@classic_dirs> (a site's C<template_paths>, a plugin's views) whose name the
interface draws itself in C<$views> and that none of C<@override_dirs>
overrides for it. The interface's template is drawn from other data than the
classic one, so the classic override cannot stand in for it. Returns
C<[ dir, template ]> pairs, sorted.

=cut

sub ui_shadowed_overrides {
  my ($classic, $overrides, $core) = @_;
  return () unless defined $core and -d $core;

  my %drawn;
  dir($core)->recurse(callback => sub {
    my $f = shift;
    return if $f->is_dir or $f->basename !~ m/\.tt$/;
    $drawn{ $f->relative($core)->as_foreign('Unix')->stringify } = 1;
  });
  # a layout is never looked up under template_paths, so overriding one there
  # changes nothing in either interface
  delete $drawn{$_} for grep { m{^layouts/} } keys %drawn;

  my @found;
  foreach my $c (grep { defined and -d $_ } @{ $classic || [] }) {
    foreach my $t (sort keys %drawn) {
      next unless -f dir($c)->file($t);
      next if grep { -f dir($_)->file($t) } @{ $overrides || [] };
      push @found, [ "$c", $t ];
    }
  }
  return sort { $a->[0] cmp $b->[0] or $a->[1] cmp $b->[1] } @found;
}

=head2 setup_web_uis( \@template_paths )

Run once, after the web plugins and the site's C<template_paths> are known:
finds each interface's overrides, puts the overlay in front of the template
engine's C<INCLUDE_PATH>, and says which classic overrides an interface does
not use.

=cut

sub setup_web_uis {
  my $site = shift || [];
  my @roots = @{ setting('_plugin_template_roots') || [] };

  foreach my $ui (grep { defined $_->{views} } values %UI) {
    my $name = $ui->{name};
    $ui->{overrides} = [ ui_dirs_for($name, @$site),
                         grep { -d $_ } map { dir($_, "views-$name")->stringify } @roots ];

    # said once at startup rather than left to be found by a user of the
    # interface wondering where the site's change went
    foreach my $s (ui_shadowed_overrides(
        [ @$site, map { dir($_, 'views')->stringify } @roots ], $ui->{overrides}, $ui->{views})) {
      warning sprintf
        '%s overrides %s, which the %s interface draws itself: browsers using the'
        . ' %s interface do not see this override. Copy it to a views-%s'
        . ' directory beside it and adapt it to change the %s page too.',
        $s->[0], $s->[1], ($name) x 4;
    }
  }

  unshift @{ config->{engines}->{netdisco_template_toolkit}->{INCLUDE_PATH} },
    \&ui_include_paths;
}

=head2 safe_back_path( $path )

C<$path> if it is a path on this site, otherwise C<undef>. A leading C<//> or
C</\> is a scheme-relative URL to another host, which would make the switch an
open redirect.

=cut

sub safe_back_path {
  my $path = shift;
  return undef unless defined $path and not ref $path;
  return undef unless $path =~ m{\A/(?![/\\])};
  return undef if $path =~ m/[\r\n]/;
  return $path;
}

=head2 back_from_referer( $referer, $base )

The page to return to after switching: the path and query of C<$referer> when
it is a page of this site (same host as C<$base>), otherwise C<undef>. The
port is not compared: behind a proxy that terminates TLS without saying so,
the base is http on 80 while the browser was on https, and cookies, which are
all the switch sets, are not kept apart by port anyway.

The page the switch was pressed on is taken from the Referer header rather
than from a field in the form, so that no page has to carry its own URL. A
field would echo the raw request URI into every page, including the not-found
page for an unknown tenant, which must not reflect its segment (xt/76).

=cut

sub back_from_referer {
  my ($referer, $base) = @_;
  return undef unless defined $referer and length $referer and defined $base;

  my $from = URI->new($referer);
  my $site = URI->new("$base");
  return undef unless $from->can('host') and $site->can('host');
  return undef unless length $from->host and lc $from->host eq lc $site->host;

  return safe_back_path($from->path_query);
}

hook 'before' => sub {
  my $picked = cookie(COOKIE);
  var(web_ui => (valid_web_ui($picked) ? $picked : setting('_default_web_ui')));
};

# web_uis: the other interfaces a layout can offer to switch to
hook 'before_template' => sub {
  my $tokens = shift;
  $tokens->{web_ui} = current_web_ui();
  $tokens->{web_ui_names} = [ web_ui_names() ];
  $tokens->{web_uis} = [ map {{ name => $_->{name}, switch_label => $_->{switch_label},
                                switch_title => $_->{switch_title} }}
                         map { $UI{$_} } grep { $_ ne 'classic' } web_ui_names() ];
};

post '/web_ui' => require_login sub {
  my $ui = param('ui');
  send_error('Unknown interface', 400) unless valid_web_ui($ui);

  cookie(COOKIE() => $ui,
    expires   => '365 days',
    path      => '/',
    same_site => 'Lax',
    http_only => 1,
    secure    => (request->secure ? 1 : 0),
  );

  redirect(back_from_referer(request->referer, request->base) || uri_for('/')->path);
};

true;
