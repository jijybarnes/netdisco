package App::Netdisco::Web::UI::Modern::Ports;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;
use Dancer::Plugin::Auth::Extensible;

use JSON::PP ();

use App::Netdisco::Web::UI::Modern::Data::Ports 'device_ports';
use App::Netdisco::Util::Web 'device_display_name';
use App::Netdisco::Web::UI 'current_web_ui';

use base 'Exporter';
our @EXPORT_OK = qw/modern_ports_pane port_column_offer port_reasons port_view_defaults short_device_name
                    server_port_columns/;

=head1 NAME

App::Netdisco::Web::UI::Modern::Ports - the device Ports tab in the modern interface

=head1 DESCRIPTION

The tab keeps the classic tab's address, C</ajax/content/device/ports>,
because that address is what the pane machinery keys on: the CSV link, the
page title and the address bar all follow from it (see C<pane_chrome>). The
route here is registered before the classic one (the interface is loaded
before the web plugins) and passes the request on to it unless the browser
uses the modern interface, so the classic route is not touched. With
C<route_cache> on, the path is cached to this route, which decides again on
every request.

The pane itself is a shell: F<share/public/modern/js/ports.js> reads the ports
from L<App::Netdisco::Web::UI::Modern::DataRoutes> and draws the front panel and the
table in the browser. The CSV
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
  my ($columns, $server) = @_;
  my %server = map {( $_ => 1 )} @{ $server || [] };
  return [ map {
    my $custom = (($_->{field} // '') =~ m/^cf_/) ? 1 : 0;
    +{
      name    => $_->{name},
      label   => ($_->{label} // $_->{name}),
      default => ($_->{default} ? JSON::PP::true : JSON::PP::false),
      ($custom ? (custom => JSON::PP::true, editable => ($_->{editable} ? JSON::PP::true : JSON::PP::false)) : ()),
      ($server{ $_->{name} } ? (server => JSON::PP::true) : ()),
    }
  } grep { $_->{name} and not $_->{hidden} } @$columns ];
}

=head2 server_port_columns( \@extra_columns, \&has_template, $links )

The columns whose cells are drawn on the server, with the plugin's own
template as the classic tab draws them: each plugin column
(C<register_device_port_column>) that ships
F<plugin/E<lt>nameE<gt>/device_port_column.tt>, and C<c_links>, the external
links, when C<$links> says the site has some. C<has_template> is asked with
the template's name. Hidden columns are left out, as there.

=cut

sub server_port_columns {
  my ($extra, $has_template, $links) = @_;
  my @names = map { $_->{name} }
              grep { $_->{name} and not $_->{hidden}
                     and $has_template->("plugin/$_->{name}/device_port_column.tt") }
              @{ $extra || [] };
  push @names, 'c_links' if $links;
  return \@names;
}

sub _has_template {
  my $name = shift;
  my $engine = Dancer::Template->engine or return 0;
  return $engine->view($name) ? 1 : 0;
}

# the ports as the classic tab hands them to plugin templates: device_port rows
# with the same joins, in the same order, hidden ones too (the browser may ask
# for them without coming back here)
sub _template_rows {
  my $device = shift;
  return [ $device->ports->with_properties->with_custom_fields->order_by_port_name->all ];
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

  my @extra = grep { not $_->{hidden} } @{ setting('_extra_device_port_cols') || [] };
  my $links = scalar @{ (setting('external_links') || {})->{device_port} || [] };

  if (request->is_ajax) {
    my $server = server_port_columns(\@extra, \&_has_template, $links);
    my %server = map {( $_ => 1 )} @$server;
    return template 'ajax/device/ports.tt', {
      device    => $device,
      server_columns => [ (grep { $server{ $_->{name} } } @extra),
                          ($server{c_links} ? ({ name => 'c_links' }) : ()) ],
      server_rows => (@$server ? _template_rows($device) : []),
      device_ip => $device->ip,
      device_name => short_device_name(device_display_name($device) || $device->ip),
      model     => ($device->model // ''),
      # not "view": with ANYCASE that is the VIEW directive
      view_defaults => JSON::PP->new->canonical->encode(port_view_defaults(setting('sidebar_defaults')->{'device_ports'})),
      # not 'filter': with ANYCASE that is the FILTER directive
      port_filter => scalar param('f'),
      columns   => JSON::PP->new->canonical->encode(port_column_offer(setting('port_columns'), $server)),
      reasons   => JSON::PP->new->canonical->encode(port_reasons(setting('port_control_reasons'))),
    }, { layout => 'noop' };
  }

  # in the shape xt/95 reads: the header, then the *_csv.tt template
  header('Content-Type' => 'text/comma-separated-values');
  template 'ajax/device/ports_csv.tt', {
    ports => device_ports($schema, $device, include_hidden => scalar param('include_hidden')),
    device => $device,
    # the plugin and custom field columns, as the classic CSV has them
    extra_columns => \@extra,
    rows_by_port => (@extra ? { map {( $_->port => $_ )} @{ _template_rows($device) } } : {}),
  }, { layout => 'noop' };
}

get '/ajax/content/device/ports' => require_login sub {
  pass unless current_web_ui() eq 'modern';
  return modern_ports_pane();
};

true;
