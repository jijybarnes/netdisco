package App::Netdisco::Web::Data;

use Dancer ':syntax';

use JSON::PP ();

use base 'Exporter';
our @EXPORT_OK = qw/
  problem json_bool iso8601_sql speed_to_bps layers_list
/;

=head1 NAME

App::Netdisco::Web::Data - normalized data for the web interfaces

=head1 DESCRIPTION

The modules under App::Netdisco::Web::Data read devices, ports, nodes, jobs
and the like from the database and return them as plain, normalized Perl data,
the same whichever interface asks. They serve no routes: an interface that
reads them from the browser serves them itself (the modern one does so in
L<App::Netdisco::Web::UI::Modern::Data>), so that a third interface can build
on the same data without the core growing an address for each.

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
