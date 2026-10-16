package App::Netdisco::Web::UI;

use Dancer ':syntax';
use Dancer::Plugin::Auth::Extensible;
use Path::Class 'dir';
use URI;

use base 'Exporter';
our @EXPORT_OK = qw/
  web_ui_names valid_web_ui current_web_ui ui_include_paths safe_back_path
  back_from_referer device_tab_for
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

=cut

sub ui_include_paths {
  my $sub = $VIEWS_DIR{ current_web_ui() } or return [];
  return [ dir(setting('views'))->parent->subdir($sub)->stringify ];
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

hook 'before' => sub {
  my $picked = cookie(COOKIE);
  var(web_ui => (valid_web_ui($picked) ? $picked : setting('_default_web_ui')));
};

hook 'before_template' => sub {
  my $tokens = shift;
  $tokens->{web_ui} = current_web_ui();
  $tokens->{web_ui_names} = [ web_ui_names() ];
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
