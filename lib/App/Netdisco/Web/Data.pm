package App::Netdisco::Web::Data;

use Dancer ':syntax';
use Dancer::Plugin::Ajax;
use Dancer::Plugin::Auth::Extensible;
use Dancer::Plugin::Swagger;

use JSON::PP ();
use Scalar::Util 'blessed';
use Try::Tiny;

use base 'Exporter';
our @EXPORT_OK = qw/
  register_data_route problem json_bool iso8601_sql speed_to_bps layers_list
/;

=head1 NAME

App::Netdisco::Web::Data - normalized data shared by the API v2 and the web UI

=head1 DESCRIPTION

Each v2 resource is written once, as a code ref returning plain Perl data, and
served at two addresses:

=over 4

=item C</api/v2/...>

For scripts. Token authentication and the C<api> role, like v1, and listed in
the Swagger document.

=item C</ajax/data/v2/...>

For the browser. The user's session, and only for an XMLHttpRequest: the
C<X-Requested-With> header a page can only send to its own origin is what
keeps another site from reading the data through the user's cookie.

=back

Both answer the same JSON, so a page of the modern interface and an API client
see exactly the same fields. Every C</api/> request is token only and drops
its session (L<App::Netdisco::Web::AuthN>), which is why the browser cannot
simply use the first address.

=head2 Conventions

=over 4

=item *

A response is C<< { data => ..., meta => {...} } >>; an error is
C<< { type, title, status, detail } >> (RFC 9457) with the same HTTP status.

=item *

Field names are snake_case and stable. Absent values are C<null>, never C<''>.
Booleans are JSON booleans.

=item *

Times are ISO 8601 with their UTC offset. Netdisco stores local timestamps
without a zone; they are read in the database session's time zone, which is
the one they were written in.

=item *

Units are in the name: C<_bps>, C<_mw>, C<_seconds>.

=back

=cut

# The Swagger document lists v2 next to v1; both share the same url_base. The
# documented path is appended after URI has built the base, as v1 does with
# api_base, because URI would percent-encode the braces of {ip}.
sub _api_path {
  my $path = shift;
  return setting('url_base')->with('/api/v2')->path . $path;
}

=head2 register_data_route( %args )

C<pattern> is the path after the C</api/v2> or C</ajax/data/v2> prefix, as a
regex fragment with named captures; C<doc_path> is the same path in Swagger's
C<{name}> form; C<doc> is the rest of the C<swagger_path> entry; C<code> gets
the captures as a hash ref and returns the response body.

=cut

sub register_data_route {
  my %args = @_;
  my ($pattern, $code) = @args{qw/pattern code/};

  my $handler = sub {
    my $body = try {
      $code->({ %{ captures() || {} } });
    }
    catch {
      # anything that is not ours, Dancer's own continuations included,
      # goes on up as it came
      die $_ unless blessed $_ and $_->isa('App::Netdisco::Web::Data::Problem');
      $_;
    };

    if (blessed $body) {
      status $body->{status};
      $body = { %$body };
    }

    content_type 'application/json';
    return JSON::PP->new->utf8->canonical->allow_nonref->encode($body);
  };

  swagger_path {
    tags => ['Objects v2'],
    %{ $args{doc} || {} },
    path => _api_path($args{doc_path}),
  }, get qr{^/api/v2${pattern}$} => require_role api => $handler;

  ajax qr{^/ajax/data/v2${pattern}$} => require_login $handler;
}

=head2 problem( $status, $title, $detail? )

Stops the current data route with an error response. C<$title> is the same for
every occurrence of a problem; C<$detail> says what this occurrence was.

=cut

sub problem {
  my ($status, $title, $detail) = @_;
  die bless {
    type   => 'about:blank',
    title  => $title,
    status => $status,
    detail => $detail,
  }, 'App::Netdisco::Web::Data::Problem';
}

sub json_bool { return $_[0] ? JSON::PP::true : JSON::PP::false }

=head2 iso8601_sql( $column )

SQL rendering C<$column>, a C<timestamp without time zone>, as ISO 8601 with
the session's UTC offset, or NULL.

=cut

sub iso8601_sql {
  my $col = shift;
  return qq{to_char(($col)::timestamptz, 'YYYY-MM-DD"T"HH24:MI:SSTZH:TZM')};
}

=head2 speed_to_bps( $text )

Netdisco stores a port's speed as SNMP::Info renders it, C<1.0 Gbps>, C<100
Mbps>. Returns the bits per second, or C<undef> for anything else (C<auto>, an
empty column, an unknown unit).

=cut

my %SPEED_UNIT = ('' => 1, k => 1e3, M => 1e6, G => 1e9, T => 1e12);

sub speed_to_bps {
  my $text = shift;
  return undef unless defined $text;
  return undef unless $text =~ m/^\s*(\d+(?:\.\d+)?)\s*([kMGT]?)bps\s*$/;
  return int($1 * $SPEED_UNIT{$2} + 0.5);
}

=head2 layers_list( $layers )

The device C<layers> column is eight characters, layer 8 first, each C<1> or
C<0>. Returns the layer numbers that are set, lowest first.

=cut

sub layers_list {
  my $layers = shift;
  return [] unless defined $layers and $layers =~ m/^[01]{8}$/;
  my @bits = reverse split //, $layers;
  return [ grep { $bits[$_ - 1] } 1 .. 8 ];
}

true;
