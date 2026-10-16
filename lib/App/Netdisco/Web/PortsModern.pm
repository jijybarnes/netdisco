package App::Netdisco::Web::PortsModern;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;

use JSON::PP ();

use App::Netdisco::Web::Data::Ports 'device_ports';

use base 'Exporter';
our @EXPORT_OK = qw/modern_ports_pane port_column_offer/;

=head1 NAME

App::Netdisco::Web::PortsModern - the device Ports tab in the modern interface

=head1 DESCRIPTION

The classic route, C</ajax/content/device/ports>, hands over to this when the
browser uses the modern interface. The route is kept rather than given a twin
because its address is what the pane machinery keys on: the CSV link, the page
title and the address bar all follow from it (see C<pane_chrome>).

The pane itself is a shell: F<share/public/modern/js/ports.js> reads the ports
from API v2 and draws the front panel and the table in the browser. The CSV
download, which is the same address without XMLHttpRequest, is written here
from the same normalized ports.

=head1 FUNCTIONS

=head2 port_column_offer( \@port_columns )

The port columns as the modern tab offers them: C<settings.port_columns>, so
in the site's order with its labels and defaults, reduced to name, label and
whether it is on by default. The tab draws those it knows and ignores the rest
(plugin columns among them, for now).

=cut

sub port_column_offer {
  my $columns = shift || [];
  return [ map {{
    name    => $_->{name},
    label   => ($_->{label} // $_->{name}),
    default => ($_->{default} ? JSON::PP::true : JSON::PP::false),
  }} grep { $_->{name} } @$columns ];
}

sub modern_ports_pane {
  my $schema = schema(vars->{'tenant'});
  my $device = $schema->resultset('Device')->search_for_device(param('q'))
    or send_error('Bad device', 400);

  if (request->is_ajax) {
    return template 'ajax/device/ports.tt', {
      device_ip => $device->ip,
      # not 'filter': with ANYCASE that is the FILTER directive
      port_filter => scalar param('f'),
      columns   => JSON::PP->new->canonical->encode(port_column_offer(setting('port_columns'))),
    }, { layout => 'noop' };
  }

  # in the shape xt/95 reads: the header, then the *_csv.tt template
  header('Content-Type' => 'text/comma-separated-values');
  template 'ajax/device/ports_csv.tt', {
    ports => device_ports($schema, $device, include_hidden => scalar param('include_hidden')),
  }, { layout => 'noop' };
}

true;
