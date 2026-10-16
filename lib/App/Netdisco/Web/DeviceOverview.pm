package App::Netdisco::Web::DeviceOverview;

use Dancer ':syntax';
use Dancer::Plugin::Ajax;
use Dancer::Plugin::DBIC;
use Dancer::Plugin::Auth::Extensible;

use App::Netdisco::Web::Plugin;
use App::Netdisco::Web::UI 'current_web_ui';
use App::Netdisco::Web::Data::Device 'device_summary';
use App::Netdisco::Web::Data::Ports qw/device_ports ports_overview/;

=head1 NAME

App::Netdisco::Web::DeviceOverview - the device page's Overview tab

=head1 DESCRIPTION

The tab the modern interface opens a device on: the state of its ports at a
glance, what needs a look, PoE, the device's facts and when it was last
polled. It only exists in the modern interface (its template is in
F<share/views-modern>), so the classic one neither lists it nor serves it.

It is registered here, among the core modules, rather than as a web plugin, so
that it comes first among the device tabs whatever a site's C<web_plugins>
list holds.

=cut

register_device_tab({
  tag       => 'overview',
  label     => 'Overview',
  render_if => sub { current_web_ui() eq 'modern' },
});

ajax '/ajax/content/device/overview' => require_login sub {
    return unless current_web_ui() eq 'modern';

    my $schema = schema(vars->{'tenant'});
    my $device = $schema->resultset('Device')->search_for_device(param('q'))
      or send_error('Bad device', 400);

    my $ports = device_ports($schema, $device);
    template 'ajax/device/overview.tt', {
      device   => device_summary($schema, $device),
      overview => ports_overview($ports),
    }, { layout => 'noop' };
};

true;
