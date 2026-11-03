package App::Netdisco::Web::UI;

use Dancer ':syntax';
use Dancer::Plugin::Auth::Extensible;
use Path::Class 'dir';
use Module::Load ();
use URI;
use Try::Tiny;

use App::Netdisco::Util::SiteLocal qw/site_local_paths ui_dirs_for scan_ui_shadowed/;

use base 'Exporter';
our @EXPORT_OK = qw/
  web_ui web_ui_names web_uis_for valid_web_ui current_web_ui
  ui_include_paths web_ui_plugin_names
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

This is the site-local mechanism (C<template_paths>, F<nd-site-local>) with a
choice of which set a browser gets. An interface is found the way a theme is:
C<web_uis> names it, and a F<views-NAME> directory is looked for where
site-local files already are: beside F<share/views> (what Netdisco ships),
beside or inside each C<template_paths> entry and F<nd-site-local/share>
(what a site writes), and beside the F<views> directory of a web plugin
(C<register_template_path>). The directories are laid over the classic ones in
that order, a site's first. A name with no such directory is reported at
startup and left out.

What an interface needs on the server is an ordinary web plugin, loaded before
those of C<web_plugins>: C<mine> is C<App::Netdisco::Web::Plugin::UI::Mine>,
else C<App::NetdiscoX::Web::Plugin::UI::Mine> (from F<site_plugins>). It
may be absent, for an interface that is only templates. It is a plugin like
the others, with routes of its own and hooks that hand its templates more
data; the core routes do not know about it. C<register_web_ui>, which
L<App::Netdisco::Web::Plugin> provides, sets what the classic menu says for
the switch to it.

An interface may draw a page by wrapping the classic template of the same name
instead of replacing it (a layout that adds a style sheet to the classic one);
its template begins with a C<[%# wraps-classic> comment, and a site's override
of the classic template is then the one wrapped.

By convention an interface named C<mine> keeps its scripts and styles under
F</mine/> in the public directory, F<share/public/mine> or, for a site,
F<nd-site-local/share/public/mine>.

C<default_web_ui> names the interface a browser gets until its user picks one.
The pick is kept in the C<nd_web_ui> cookie rather than in the users table, so
it needs no schema change, follows the browser rather than the account, and is
lost harmlessly when the cookie is.

=cut

use constant COOKIE => 'nd_web_ui';

# name => { name, views, switch_title, short_label, overrides }
#   views: the directory Netdisco ships for the interface, if it exists
#   overrides: the site's and plugins' directories for it, first first
#   short_label: what the account menu calls the interface
#   switch_title: the tooltip of the menu item that moves to it
my %UI = (
  classic => {
    name         => 'classic',
    views        => undef,
    switch_title => 'Switch this browser back to the classic interface',
    short_label  => 'Classic UI',
  },
);

my $VALID_NAME = qr/\A[a-z][a-z0-9_]*\z/;

=head1 FUNCTIONS

=head2 web_ui( $name )

The interface declared under C<$name>, or C<undef>.

=cut

sub web_ui { my $name = shift; return (defined $name and not ref $name) ? $UI{$name} : undef }

sub web_ui_names { return sort keys %UI }

=head2 web_uis_for( $current )

Every interface a browser using C<$current> can choose between, itself
included, the classic one first, then the others by name. Each is a hash with
C<name>, C<short_label>, C<switch_title> and C<current>, true for C<$current>.
This is what the account menu of every layout lists, so that any interface can
reach any other whatever their number.

=cut

sub web_uis_for {
  my $current = shift;
  return map { my $ui = $UI{$_};
               +{ name => $ui->{name}, short_label => $ui->{short_label},
                  switch_title => $ui->{switch_title},
                  current => ((defined $current and $_ eq $current) ? 1 : 0) } }
         sort { ($a ne 'classic') <=> ($b ne 'classic') or $a cmp $b }
         keys %UI;
}

sub valid_web_ui {
  my $name = shift;
  return (defined $name and not ref $name and exists $UI{$name}) ? 1 : 0;
}

=head2 web_ui_plugin_names( $name )

Pure: the web plugin modules that serve interface C<$name>, in the order
they are tried.

=cut

sub web_ui_plugin_names {
  my $name = shift;
  return () unless defined $name and not ref $name and $name =~ $VALID_NAME;
  my $camel = ucfirst $name;
  return ("App::Netdisco::Web::Plugin::UI::$camel",
          "App::NetdiscoX::Web::Plugin::UI::$camel");
}

=head2 load_web_uis()

Declares the interfaces C<web_uis> names and loads their web plugins. A
plugin that is not there is no fault; one that cannot be loaded is reported
and left out rather than stopping the web server: the classic interface works
without it. A name that is not a valid interface name is reported and ignored.

=cut

sub load_web_uis {
  my @names = @{ (ref [] eq ref setting('web_uis')) ? setting('web_uis') : [] };
  unshift @INC, dir(($ENV{NETDISCO_HOME} || $ENV{HOME}), 'site_plugins')->stringify if @names;

  foreach my $name (@names) {
    unless (defined $name and not ref $name and $name =~ $VALID_NAME and $name ne 'classic') {
      warning sprintf q{web_uis entry '%s' is not an interface name: use lower case letters,}
        . q{ digits and '_', starting with a letter, and not 'classic'. It is ignored.},
        (defined $name ? $name : 'undef');
      next;
    }

    $UI{$name} ||= {
      name         => $name,
      views        => dir(setting('views'))->parent->subdir("views-$name")->stringify,
      switch_title => "Switch this browser to the $name interface",
      short_label  => ucfirst($name) . ' UI',
      overrides    => [],
    };

    foreach my $module (web_ui_plugin_names($name)) {
      my $file = join('/', split /::/, $module) . '.pm';
      try { Module::Load::load($module) }
      catch {
        # a plugin the interface does not have is not a problem
        warning sprintf 'web interface %s could not be loaded: %s', $name, $_
          unless m/^Can't locate \Q$file\E in \@INC/;
      };
    }
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
directory Netdisco ships for it, if any. A template none of them has falls through to the
classic chain behind, site, plugins, then F<share/views>, so a site or a
plugin overriding a template the interface does not draw itself is used by
every interface. The classic interface adds nothing.

=cut

sub ui_include_paths {
  my $ui = $UI{ current_web_ui() } or return [];
  return [] if $ui->{name} eq 'classic';
  return [ @{ $ui->{overrides} || [] }, (defined $ui->{views} ? $ui->{views} : ()) ];
}

=head2 setup_web_uis()

Run once, after the web plugins and the site's C<template_paths> are known:
finds each declared interface's directories, drops those that have none, puts
the overlay in front of the template engine's C<INCLUDE_PATH>, and says which
classic overrides an interface does not use. C<netdisco-do checksitelocal>
says the same for the site's files alone.

=cut

sub setup_web_uis {
  my @site  = site_local_paths();
  my @roots = @{ setting('_plugin_template_roots') || [] };
  my $labels = setting('_web_ui_labels') || {};

  foreach my $ui (grep { $_->{name} ne 'classic' } values %UI) {
    my $name = $ui->{name};
    $ui->{$_} = $labels->{$name}->{$_}
      for grep { defined $labels->{$name}->{$_} } qw/switch_title short_label/;

    $ui->{overrides} = [ ui_dirs_for($name, @site, @roots) ];
    $ui->{views} = undef unless defined $ui->{views} and -d $ui->{views};

    unless (defined $ui->{views} or scalar @{ $ui->{overrides} }) {
      warning sprintf q{web_uis names '%s' but no views-%s directory was found beside share/views,}
        . q{ in template_paths, in nd-site-local/share or beside a web plugin's views. The}
        . q{ interface is left out.}, ($name) x 2;
      delete $UI{$name};
      next;
    }

    # said once at startup rather than left to be found by a user of the
    # interface wondering where the site's change went
    foreach my $f (scan_ui_shadowed({
        name => $name, core => $ui->{views}, overrides => $ui->{overrides},
        paths => [ @site, map { dir($_, 'views')->stringify } @roots ] })) {
      warning sprintf '%s: %s', $f->{path}, $f->{advice};
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

# web_uis: the interfaces a layout's account menu offers to choose between
hook 'before_template' => sub {
  my $tokens = shift;
  $tokens->{web_ui} = current_web_ui();
  $tokens->{web_ui_names} = [ web_ui_names() ];
  $tokens->{web_uis} = [ web_uis_for($tokens->{web_ui}) ];
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
