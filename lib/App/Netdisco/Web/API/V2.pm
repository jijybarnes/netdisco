package App::Netdisco::Web::API::V2;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;
use Dancer::Plugin::Auth::Extensible;

use URI::Escape 'uri_unescape';

use App::Netdisco::Web::Data qw/register_data_route/;
use App::Netdisco::Web::Data::Device qw/find_device device_summary/;
use App::Netdisco::Web::Data::Ports qw/device_ports device_port port_nodes
                                       device_vlans port_log free_interval/;
use App::Netdisco::Web::Data::Jobs 'my_jobs';
use App::Netdisco::Web::Data::Devices 'list_devices';
use App::Netdisco::Web::Data::Search 'quick_search';
use App::Netdisco::Web::Data::Summary 'network_summary';
use App::Netdisco::Util::Port qw/port_acl_service port_acl_pvid port_acl_name
                                 device_acl_by_role_check sync_portctl_roles/;
use App::Netdisco::Util::Permission qw/acl_matches acl_matches_only/;

# Each route here is served as /api/v2/... and as /ajax/data/v2/..., see
# App::Netdisco::Web::Data. Port names hold slashes (Gi1/0/1), so a port is the
# rest of the path, and the routes with a suffix after it are declared before
# the one without, as in v1.

sub _schema { schema(vars->{'tenant'}) }

sub _port_name {
  my $s = uri_unescape(shift // '');
  $s =~ s/^\s+|\s+$//g;
  return $s;
}

# What the signed in user may change on a port, decided by the same checks the
# classic Ports tab and /ajax/portcontrol make. Undef when the user has no port
# control at all, which is what the classic tab does by not drawing the column.
# logged_in_user is the user's row, which the checks accept as it is: handed the
# name instead, each would look the row up again, once per port and per check.
sub _control_for {
  my $device = shift;
  return undef unless user_has_role('port_control');

  sync_portctl_roles();
  my $user = logged_in_user or return undef;

  # a role limited to some devices may not control any port of this one, which
  # the route refuses before it looks at the port
  my $device_ok = (user_has_role('admin') or device_acl_by_role_check($device->ip, $user));

  my $shown = _custom_fields_for();
  my @editable = map { $_->{name} } grep { $_->{editable} } _port_custom_fields();
  return sub {
    my $row = shift;
    return { service => 0, pvid => 0, name => 0 } unless $device_ok;
    my $service = port_acl_service($row, $device, $user) ? 1 : 0;
    my %here = map {( $_ => 1 )} @{ $shown->($row) };
    return {
      service => $service,
      pvid    => (port_acl_pvid($row, $device, $user) ? 1 : 0),
      name    => ($service or port_acl_name($row, $device, $user) ? 1 : 0),
      custom_fields => [ grep { $here{$_} } @editable ],
    };
  };
}

sub _port_custom_fields { grep { $_->{name} } @{ setting('custom_fields')->{'device_port'} || [] } }

# The custom fields a port may show: the site's, less those whose only and no
# ACLs leave this port out, as permitted_by_acl decides for the classic tab.
sub _custom_fields_for {
  my @fields = _port_custom_fields();
  return sub {
    my $row = shift;
    return [ map { $_->{name} } grep {
      not acl_matches($row, ($_->{no} || [])) and acl_matches_only($row, ($_->{only} || []))
    } @fields ];
  };
}

sub _free { [ free_interval(scalar param('free_age'), scalar param('free_unit')) ] }

sub _flag {
  my $v = param(shift);
  return (defined $v and $v =~ m/^(?:1|true|yes|on)$/i) ? 1 : 0;
}

my %IP = (
  description => 'Canonical IP of the device, any of its interface addresses, or its name.',
  required => 1,
  in => 'path',
);
my %PORT = (
  description => 'Name of the port, as listed by .../ports. It may contain slashes; URL-encode any other reserved character.',
  required => 1,
  in => 'path',
);

# is_free: down, and for how long, as the classic tab's "Mark as Free if Down for"
my %FREE = (
  free_age  => { description => 'With free_unit: how long a port must have been down to be free (is_free), 1 to 31', in => 'query', type => 'integer', default => 3 },
  free_unit => { description => 'days, weeks, months or years', in => 'query', type => 'string', enum => [qw/days weeks months years/], default => 'months' },
);

register_data_route(
  pattern  => '/devices',
  doc_path => '/devices',
  doc => {
    description => 'The devices, as light rows: searched, ordered and cut to a page in the database',
    parameters  => [
      q      => { description => 'Words that must all appear in the device: its names, address, model, vendor, software, location, serial or description', in => 'query', type => 'string' },
      health => { description => 'failing: only the devices the backend cannot reach', in => 'query', type => 'string', enum => ['failing'] },
      sort   => { description => 'Order by', in => 'query', type => 'string', enum => [qw/name ip model os location ports last_discover/], default => 'name' },
      dir    => { description => 'asc or desc', in => 'query', type => 'string', enum => [qw/asc desc/], default => 'asc' },
      limit  => { description => 'How many rows, at most 1000', in => 'query', type => 'integer', default => 100 },
      offset => { description => 'How many rows to skip', in => 'query', type => 'integer', default => 0 },
    ],
    responses => { default => {} },
  },
  code => sub {
    my $r = list_devices(_schema,
      map { $_ => scalar param($_) } qw/q health sort dir limit offset/);
    return { data => $r->{rows}, meta => {
      count => scalar @{ $r->{rows} }, total => $r->{total}, failing => $r->{failing} } };
  },
);

register_data_route(
  pattern  => '/summary',
  doc_path => '/summary',
  doc => {
    description => 'The network at a glance: devices (and those unreachable or not discovered lately), ports in trouble, the job queue, and the daily statistics',
    parameters  => [],
    responses => { default => {} },
  },
  code => sub { return { data => network_summary(_schema), meta => {} } },
);

register_data_route(
  pattern  => '/search',
  doc_path => '/search',
  doc => {
    description => 'The first few devices, nodes, port descriptions and VLANs that match some text: a MAC, an address, a VLAN number or words',
    parameters  => [
      q => { description => 'What to look for', in => 'query', type => 'string', required => 1 },
    ],
    responses => { default => {} },
  },
  code => sub {
    my $q = param('q');
    return { data => quick_search(_schema, $q), meta => { q => (defined $q ? "$q" : '') } };
  },
);

register_data_route(
  pattern  => '/me/jobs',
  doc_path => '/me/jobs',
  doc => {
    description => 'The jobs the signed in user queued, newest first: the changes made from a device page, polls, and their outcome',
    parameters  => [
      limit => { description => 'How many jobs, at most 100', in => 'query', type => 'integer', default => 25 },
    ],
    responses => { default => {} },
  },
  code => sub {
    my $jobs = my_jobs(_schema, session('logged_in_user'), limit => param('limit'));
    return { data => $jobs, meta => { count => scalar @$jobs } };
  },
);

register_data_route(
  pattern  => '/devices/(?<ip>[^/]+)/vlans',
  doc_path => '/devices/{ip}/vlans',
  doc => {
    description => 'The VLANs a device knows, by number, with their names',
    parameters  => [ ip => \%IP ],
    responses => { default => {} },
  },
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $vlans = device_vlans(_schema, $device);
    return { data => $vlans, meta => { device => $device->ip, count => scalar @$vlans } };
  },
);

register_data_route(
  pattern  => '/devices/(?<ip>[^/]+)/ports/(?<port>.+)/log',
  doc_path => '/devices/{ip}/ports/{port}/log',
  doc => {
    description => 'The port control log of a port, newest first: changes, who made them and why, and comments',
    parameters  => [
      ip => \%IP, port => \%PORT,
      limit => { description => 'How many entries, at most 200', in => 'query', type => 'integer', default => 25 },
    ],
    responses => { default => {} },
  },
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $port = _port_name($c->{port});
    my $log = port_log(_schema, $device, $port,
      limit => scalar param('limit'), reasons => setting('port_control_reasons'));
    return { data => $log, meta => { device => $device->ip, port => $port, count => scalar @$log } };
  },
);

register_data_route(
  pattern  => '/devices/(?<ip>[^/]+)/ports/(?<port>.+)/nodes',
  doc_path => '/devices/{ip}/ports/{port}/nodes',
  doc => {
    description => 'The nodes seen on a port, most recently seen first, each with its IP addresses',
    parameters  => [
      ip => \%IP, port => \%PORT,
      archived => {
        description => 'Include nodes and addresses no longer active',
        in => 'query', type => 'boolean', default => 'false',
      },
    ],
    responses => { default => {} },
  },
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $port = _port_name($c->{port});
    my $nodes = port_nodes(_schema, $device, $port, archived => _flag('archived'));
    return { data => $nodes, meta => {
      device => $device->ip, port => $port, count => scalar @$nodes } };
  },
);

register_data_route(
  pattern  => '/devices/(?<ip>[^/]+)/ports/(?<port>.+)',
  doc_path => '/devices/{ip}/ports/{port}',
  doc => {
    description => 'One port of a device',
    parameters  => [ ip => \%IP, port => \%PORT, %FREE ],
    responses => { default => {} },
  },
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $port = device_port(_schema, $device, _port_name($c->{port}),
      control => _control_for($device), custom_fields => _custom_fields_for(), free => _free());
    return { data => $port, meta => { device => $device->ip } };
  },
);

register_data_route(
  pattern  => '/devices/(?<ip>[^/]+)/ports',
  doc_path => '/devices/{ip}/ports',
  doc => {
    description => 'The ports of a device, in port name order',
    parameters  => [
      ip => \%IP,
      include_hidden => {
        description => 'Include the ports the hide_deviceports setting hides',
        in => 'query', type => 'boolean', default => 'false',
      },
      %FREE,
    ],
    responses => { default => {} },
  },
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $ports = device_ports(_schema, $device, include_hidden => _flag('include_hidden'),
      control => _control_for($device), custom_fields => _custom_fields_for(), free => _free());
    return { data => $ports, meta => { device => $device->ip, count => scalar @$ports } };
  },
);

register_data_route(
  pattern  => '/devices/(?<ip>[^/]+)',
  doc_path => '/devices/{ip}',
  doc => {
    description => 'One device',
    parameters  => [ ip => \%IP ],
    responses => { default => {} },
  },
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    return { data => device_summary(_schema, $device), meta => {} };
  },
);

true;
