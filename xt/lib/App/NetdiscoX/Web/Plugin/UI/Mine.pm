package App::NetdiscoX::Web::Plugin::UI::Mine;

use Dancer ':syntax';
use App::Netdisco::Web::Plugin;

# The web plugin of a site's own web interface, `mine`, as a site would write
# one (see App::Netdisco::Web::UI): it says what the classic menu reads for the
# switch, and brings a route of its own. Loaded by the tests that name `mine` in
# web_uis.

register_web_ui({
  name         => 'mine',
  short_label  => 'Mine UI',
  switch_title => 'Switch this browser to mine',
});

get '/ajax/xt/mine' => sub { return 'mine route' };

true;
