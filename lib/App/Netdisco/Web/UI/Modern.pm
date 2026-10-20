package App::Netdisco::Web::UI::Modern;

use Dancer ':syntax';
use Path::Class 'dir';

use App::Netdisco::Web::UI 'register_web_ui';

=head1 NAME

App::Netdisco::Web::UI::Modern - the modern web interface

=head1 DESCRIPTION

A web interface (see L<App::Netdisco::Web::UI>), named C<modern>: its
templates are in F<share/views-modern>, its scripts and styles under
F<share/public/modern>, and what it needs on the server is in the modules
below, which the core neither loads nor knows of. Leaving C<Modern> out of
C<web_uis> leaves the interface out entirely.

=over 4

=item L<App::Netdisco::Web::UI::Modern::Shell>

What its layout draws on every page: the rail, the breadcrumb, the command
palette, the device page's header.

=item L<App::Netdisco::Web::UI::Modern::Ports>

The device page's Ports tab, in front of the classic one.

=item L<App::Netdisco::Web::UI::Modern::DevicesPage>

The list of devices, C</devices>.

=item L<App::Netdisco::Web::UI::Modern::Home>

The network at a glance on the home page.

=item L<App::Netdisco::Web::UI::Modern::DataRoutes>

The data its scripts read, at C</ajax/data/v2/...>.

=item L<App::Netdisco::Web::UI::Modern::Data>

That data, read from the database and normalized, for the modules above.

=back

=cut

register_web_ui({
  name         => 'modern',
  views        => dir(setting('views'))->parent->subdir('views-modern')->stringify,
  switch_label => 'Try the new interface',
  switch_title => 'Switch this browser to the new interface',
});

use App::Netdisco::Web::UI::Modern::Shell;
use App::Netdisco::Web::UI::Modern::DevicesPage;
use App::Netdisco::Web::UI::Modern::Home;
use App::Netdisco::Web::UI::Modern::DataRoutes;
use App::Netdisco::Web::UI::Modern::Ports;

true;
