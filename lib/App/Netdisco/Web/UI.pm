package App::Netdisco::Web::UI;

use Dancer ':syntax';
use Dancer::Plugin::Auth::Extensible;
use Path::Class 'dir';
use URI;
use JSON::PP ();

use base 'Exporter';
our @EXPORT_OK = qw/
  web_ui_names valid_web_ui current_web_ui ui_include_paths safe_back_path
  back_from_referer device_tab_for page_segments nav_for crumbs_for
  modern_dirs_for modern_shadowed_overrides palette_index
/;

=head1 NAME

App::Netdisco::Web::UI - choose between the classic and the modern web interface

=head1 DESCRIPTION

An interface is a directory of views laid over F<share/views>. A template the
interface does not provide falls through to the classic one, so pages move to
the modern interface one at a time and the rest keep working inside it.

C<default_web_ui> names the interface a browser gets until its user picks one.
The pick is kept in the C<nd_web_ui> cookie rather than in the users table, so
it needs no schema change, follows the browser rather than the account, and is
lost harmlessly when the cookie is.

=cut

# classic has no overlay: it is share/views itself.
my %VIEWS_DIR = (classic => undef, modern => 'views-modern');

use constant COOKIE => 'nd_web_ui';

sub web_ui_names { return sort keys %VIEWS_DIR }

sub valid_web_ui {
  my $name = shift;
  return (defined $name and not ref $name and exists $VIEWS_DIR{$name}) ? 1 : 0;
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

For the modern interface these are, in order: the C<views-modern> beside each
of the site's C<template_paths>, the C<views-modern> of each plugin that
registered a template path (the last registered first, as for C<views>), and
F<share/views-modern>. A template none of them has falls through to the
classic chain behind, site, plugins, then F<share/views>, so a site or a
plugin overriding a template the modern interface does not draw itself is
used by both interfaces.

=cut

sub ui_include_paths {
  my $sub = $VIEWS_DIR{ current_web_ui() } or return [];
  return [ @{ setting('_ui_override_paths') || [] },
           dir(setting('views'))->parent->subdir($sub)->stringify ];
}

=head2 modern_dirs_for( @template_paths )

Where a site's modern templates sit, for each of its C<template_paths>: beside
a directory named F<views> (F<.../share/views> gives F<.../share/views-modern>),
else inside it. Only those that exist, each once, in the given order.

=cut

sub modern_dirs_for {
  my %seen;
  return grep { -d $_ and not $seen{$_}++ }
         map  { my $d = dir($_);
                ($d->basename eq 'views' ? $d->parent->subdir('views-modern')
                                         : $d->subdir('views-modern'))->stringify }
         grep { defined and length } @_;
}

=head2 modern_shadowed_overrides( \@classic_dirs, \@modern_dirs, $core_modern )

The classic overrides the modern interface does not use: each template under
one of C<@classic_dirs> (a site's C<template_paths>, a plugin's views) whose
name the modern interface draws itself in C<$core_modern> and that none of
C<@modern_dirs> overrides for it. The modern template is drawn from other data
than the classic one, so the classic override cannot stand in for it. Returns
C<[ dir, template ]> pairs, sorted.

=cut

sub modern_shadowed_overrides {
  my ($classic, $modern, $core) = @_;
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
      next if grep { -f dir($_)->file($t) } @{ $modern || [] };
      push @found, [ "$c", $t ];
    }
  }
  return sort { $a->[0] cmp $b->[0] or $a->[1] cmp $b->[1] } @found;
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

=head2 device_tab_for( $web_ui, $requested_tab )

The device page tab to open. The modern interface opens on its Overview, the
classic one on Details as it always has. Overview exists only in the modern
interface, so a link to it (or a switch back to classic while on it) opens
Details there instead.

=cut

sub device_tab_for {
  my ($ui, $tab) = @_;
  my $modern = (defined $ui and $ui eq 'modern');
  return ($modern ? 'overview' : 'details') unless defined $tab and length $tab;
  return 'details' if $tab eq 'overview' and not $modern;
  return $tab;
}

=head2 page_segments( $path, $base )

The path's segments below the site's base path and a tenant prefix:
C</nd/t/branch/device> under base C</nd> is C<('device')>.

=cut

sub page_segments {
  my ($path, $base) = @_;
  $path = '' unless defined $path;
  $base = '' if not defined $base or $base eq '/';
  # the base is a whole segment: /nd does not take the start of /ndx
  $path =~ s{^\Q$base\E(?=/|$)}{} if length $base;
  $path =~ s{^/t/[^/]+(?=/|$)}{};
  return grep { length } split m{/}, $path;
}

=head2 nav_for( \@segments, $vars_nav )

Which item of the rail a page belongs to. Reports, admin, inventory and
statistics pages say so themselves (C<$vars_nav>); a device, a search and the
list of devices are all "devices"; the front page is "home".

=cut

sub nav_for {
  my ($segments, $vars_nav) = @_;
  my $first = $segments->[0];
  return 'home' unless defined $first;
  return 'devices' if $first =~ m/^(?:device|devices|search)$/;
  return $vars_nav;
}

=head2 crumbs_for( \@segments, \%context )

The breadcrumb of a page: a list of C<{ label, href }>, where C<href> is an
application path, or absent for a crumb that is not a page (there is no page of
all reports, so "Reports" is only a name). The last crumb is the page itself.
C<%context> holds what the path does not: C<display_name> of the device,
C<query> of a search, and C<reports> and C<admin_tasks>, the registered ones.

=cut

sub crumbs_for {
  my ($segments, $ctx) = @_;
  my ($first, $second) = @$segments;
  return [] unless defined $first;

  return [ { label => 'Devices' } ] if $first eq 'devices';
  return [ { label => 'Devices', href => '/devices' }, { label => $ctx->{display_name} } ]
    if $first eq 'device' and defined $ctx->{display_name} and length $ctx->{display_name};
  return [ { label => 'Inventory' } ] if $first eq 'inventory';
  if ($first eq 'search') {
    my $q = $ctx->{query};
    return [ { label => 'Search', ((defined $q and length $q) ? (href => '/search') : ()) },
             ((defined $q and length $q) ? { label => $q } : ()) ];
  }
  if ($first eq 'report' and defined $second) {
    my $r = ($ctx->{reports} || {})->{$second} or return [ { label => 'Reports' } ];
    return [ { label => 'Reports' },
             ((defined $r->{category} and length $r->{category}) ? { label => $r->{category} } : ()),
             { label => ($r->{label} // $second) } ];
  }
  if ($first eq 'admin' and defined $second) {
    my $t = ($ctx->{admin_tasks} || {})->{$second} or return [ { label => 'Admin' } ];
    return [ { label => 'Admin' }, { label => ($t->{label} // $second) } ];
  }
  return [];
}

hook 'before' => sub {
  my $picked = cookie(COOKIE);
  var(web_ui => (valid_web_ui($picked) ? $picked : setting('_default_web_ui')));
};

=head2 palette_index( \%registry, \&may )

Pure: what the command palette offers without asking the server, from what the
core and the web plugins registered: the pages (Home, Devices, the navigation
items), the reports, the admin tasks, and the search tabs, which the palette
offers to search the typed text with. C<%registry> holds C<navbar_items>,
C<reports>, C<reports_menu>, C<report_order>, C<admin_tasks>,
C<admin_order> and C<search_tabs> as the settings of those names have them;
C<may> is asked with a list of roles and says whether the user has one. A
report or a task that is hidden is left out, as the menus leave it out, and
so is a task the user may not open.

=cut

sub palette_index {
  my ($r, $may) = @_;
  $may ||= sub { 0 };
  my @items = (
    { group => 'Pages', label => 'Home', href => '/', icon => 'fa-house' },
    { group => 'Pages', label => 'Devices', sub => 'Every device', href => '/devices', icon => 'fa-server' },
    (map {{ group => 'Pages', label => $_->{label}, href => $_->{path},
            icon => (($_->{icon} // '') =~ m/^fa-[a-z0-9-]+$/ ? $_->{icon}
                     : ($_->{tag} // '') eq 'inventory' ? 'fa-boxes-stacked' : 'fa-circle-dot') }}
     grep { $_->{label} and $_->{path} } @{ $r->{navbar_items} || [] }),
  );

  foreach my $cat (@{ $r->{report_order} || [] }) {
    foreach my $tag (@{ ($r->{reports_menu} || {})->{$cat} || [] }) {
      my $rep = ($r->{reports} || {})->{$tag} or next;
      next if $rep->{hidden};
      push @items, { group => 'Reports', label => $rep->{label}, sub => $cat,
                     href => "/report/$tag?firstsearch=on", icon => 'fa-chart-column' };
    }
  }

  foreach my $tag (@{ $r->{admin_order} || [] }) {
    my $task = ($r->{admin_tasks} || {})->{$tag} or next;
    next if $task->{hidden};
    next unless $may->(['admin']) or ($task->{roles} and $may->($task->{roles}));
    push @items, { group => 'Admin', label => $task->{label}, sub => 'Admin task',
                   href => "/admin/$tag?firstsearch=on", icon => 'fa-gear' };
  }

  my @search = map {{ tag => $_->{tag}, label => $_->{label} }}
               grep { $_->{tag} and $_->{label} and not $_->{hidden} } @{ $r->{search_tabs} || [] };
  return { items => \@items, search_tabs => \@search };
}

hook 'before_template' => sub {
  my $tokens = shift;
  $tokens->{web_ui} = current_web_ui();
  $tokens->{web_ui_names} = [ web_ui_names() ];

  return unless current_web_ui() eq 'modern' and not request->is_ajax;
  my @segments = page_segments(request->path, setting('path'));
  $tokens->{nd2_nav} = nav_for(\@segments, vars->{'nav'});
  $tokens->{nd2_crumbs} = crumbs_for(\@segments, {
    display_name => $tokens->{display_name},
    query        => scalar param('q'),
    reports      => setting('_reports'),
    admin_tasks  => setting('_admin_tasks'),
  });

  return unless session('logged_in_user');
  $tokens->{nd2_palette} = JSON::PP->new->canonical->encode(palette_index({
    navbar_items => setting('_navbar_items'),
    reports      => setting('_reports'),
    reports_menu => setting('_reports_menu'),
    report_order => setting('_report_order'),
    admin_tasks  => setting('_admin_tasks'),
    admin_order  => setting('_admin_order'),
    search_tabs  => setting('_search_tabs'),
  }, sub { my $roles = shift; scalar grep { user_has_role($_) } @$roles }));
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
