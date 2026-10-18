package App::Netdisco::Web::UI::Modern::DevicesPage;

use Dancer ':syntax';
use Dancer::Plugin::Auth::Extensible;

use App::Netdisco::Web::UI 'current_web_ui';

=head1 NAME

App::Netdisco::Web::UI::Modern::DevicesPage - the list of devices, in the modern interface

=head1 DESCRIPTION

Netdisco has no page that lists its devices: the classic interface finds them by
searching. The modern one has this, which the rail's Devices item and the first
crumb of a device page lead to. It is a shell that
F<share/public/modern/js/devices.js> fills from C<GET /ajax/data/v2/devices>.

The classic interface has no such page to show, so it sends the visit to the
inventory, the nearest it has.

=cut

get '/devices' => require_login sub {
    return redirect uri_for('/inventory')->path
      unless current_web_ui() eq 'modern';

    template 'devices', { page_devices => 1 }, { layout => 'main' };
};

true;
