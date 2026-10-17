package App::Netdisco::Web::PortsModern;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;

use JSON::PP ();

use App::Netdisco::Web::Data::Ports 'device_ports';
use App::Netdisco::Util::Web 'device_display_name';

use base 'Exporter';
our @EXPORT_OK = qw/modern_ports_pane port_column_offer port_reasons port_view_defaults short_device_name/;

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
whether it is on by default. A custom field's column (its field is C<cf_...>)
says so, and whether it may be edited. The tab draws those it knows and the
custom fields, and ignores the rest (other plugin columns, which bring their
own templates).

=cut

sub port_column_offer {
  my $columns = shift || [];
  return [ map {
    my $custom = (($_->{field} // '') =~ m/^cf_/) ? 1 : 0;
    +{
      name    => $_->{name},
      label   => ($_->{label} // $_->{name}),
      default => ($_->{default} ? JSON::PP::true : JSON::PP::false),
      ($custom ? (custom => JSON::PP::true, editable => ($_->{editable} ? JSON::PP::true : JSON::PP::false)) : ()),
    }
  } grep { $_->{name} } @$columns ];
}

=head2 port_view_defaults( \%device_ports_defaults )

The site's defaults for the display options the tab offers in its View menu,
from C<sidebar_defaults.device_ports>: the same options the classic sidebar
has, under the names F<ports.js> keeps them by.

=cut

sub port_view_defaults {
  my $d = shift || {};
  my $on = sub { my $o = $d->{ shift() }; (ref {} eq ref $o and $o->{default}) ? JSON::PP::true : JSON::PP::false };
  my $val = sub { my $o = $d->{ shift() }; ref {} eq ref $o ? $o->{default} : undef };
  my $age = $val->('age_num');
  return {
    foldSubinterfaces => $on->('p_fold_subinterfaces'),
    vlanNames         => $on->('p_vlan_names'),
    hide1002          => $on->('p_hide1002'),
    macFormat         => ($val->('mac_format') // 'IEEE'),
    freeAge           => ((defined $age and $age =~ m/^\d+$/) ? 0 + $age : 3),
    freeUnit          => ($val->('age_unit') // 'months'),
  };
}

=head2 short_device_name( $name )

The device as the drawer's subtitle names it: its host name without the
domain, as the prototype has it, but an address whole.

=cut

sub short_device_name {
  my $n = shift // '';
  return $n if $n =~ m/^[0-9.]+$/ or $n =~ m/:/;
  (my $short = $n) =~ s/\..*//;
  return length $short ? $short : $n;
}

=head2 port_reasons( \%reasons )

The reasons a port change can be logged under, as C<port_control_reasons> has
them (key and text), in the order the classic modal lists them: by key.

=cut

sub port_reasons {
  my $reasons = shift;
  return [] unless ref {} eq ref $reasons;
  return [ map {{ value => $_, label => $reasons->{$_} }} sort keys %$reasons ];
}

sub modern_ports_pane {
  my $schema = schema(vars->{'tenant'});
  my $device = $schema->resultset('Device')->search_for_device(param('q'))
    or send_error('Bad device', 400);

  if (request->is_ajax) {
    return template 'ajax/device/ports.tt', {
      device_ip => $device->ip,
      device_name => short_device_name(device_display_name($device) || $device->ip),
      model     => ($device->model // ''),
      # not "view": with ANYCASE that is the VIEW directive
      view_defaults => JSON::PP->new->canonical->encode(port_view_defaults(setting('sidebar_defaults')->{'device_ports'})),
      # not 'filter': with ANYCASE that is the FILTER directive
      port_filter => scalar param('f'),
      columns   => JSON::PP->new->canonical->encode(port_column_offer(setting('port_columns'))),
      reasons   => JSON::PP->new->canonical->encode(port_reasons(setting('port_control_reasons'))),
    }, { layout => 'noop' };
  }

  # in the shape xt/95 reads: the header, then the *_csv.tt template
  header('Content-Type' => 'text/comma-separated-values');
  template 'ajax/device/ports_csv.tt', {
    ports => device_ports($schema, $device, include_hidden => scalar param('include_hidden')),
  }, { layout => 'noop' };
}

true;
