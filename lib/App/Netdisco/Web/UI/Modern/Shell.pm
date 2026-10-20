package App::Netdisco::Web::UI::Modern::Shell;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;
use Dancer::Plugin::Auth::Extensible;

use JSON::PP ();

use App::Netdisco::Web::UI 'current_web_ui';
use App::Netdisco::Web::UI::Modern::Data::Device 'device_summary';

use base 'Exporter';
our @EXPORT_OK = qw/page_segments nav_for crumbs_for palette_index/;

=head1 NAME

App::Netdisco::Web::UI::Modern::Shell - what the modern layout needs on every page

=head1 DESCRIPTION

The modern layout (F<share/views-modern/layouts/main.tt>) draws a rail, a
breadcrumb and a command palette on every page, and a header on the device
page. What they show is handed to the templates by the hooks here, from the
routes' own tokens, so that no core route computes anything for an interface:
C<nd2_nav>, the rail item the page belongs to; C<nd2_crumbs>, the breadcrumb;
C<nd2_palette>, the palette's index; and C<nd2_device>, the device of the
device page, normalized.

=head1 FUNCTIONS

=cut

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

sub _modern_page { current_web_ui() eq 'modern' and not request->is_ajax }

hook 'before_template' => sub {
  my $tokens = shift;
  return if request->is_ajax;
  my @segments = page_segments(request->path, setting('path'));

  # the device page's header: its device
  if (@segments == 1 and $segments[0] eq 'device' and $tokens->{netdisco_device}
      and current_web_ui() eq 'modern') {
    $tokens->{nd2_device} = device_summary(schema(vars->{'tenant'}), $tokens->{netdisco_device});
  }

  return unless _modern_page();
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

true;
