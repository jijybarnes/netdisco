package App::Netdisco::Web::UI::Modern::DataRoutes;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;
use Dancer::Plugin::Auth::Extensible;

use URI::Escape 'uri_unescape';

use Dancer::Plugin::Ajax;
use JSON::PP ();
use Scalar::Util 'blessed';
use Try::Tiny;

use base 'Exporter';
our @EXPORT_OK = 'data_route';
use App::Netdisco::Web::UI::Modern::Data::Device qw/find_device device_summary/;
use App::Netdisco::Web::UI::Modern::Data::Ports qw/device_ports device_port port_nodes
                                       device_vlans port_log free_interval/;
use App::Netdisco::Web::UI::Modern::Data::Jobs 'my_jobs';
use App::Netdisco::Web::UI::Modern::Data::Devices 'list_devices';
use App::Netdisco::Web::UI::Modern::Data::Search 'quick_search';
use App::Netdisco::Web::UI::Modern::Data::Summary 'network_summary';
use App::Netdisco::Util::Port qw/port_acl_service port_acl_pvid port_acl_name
                                 device_acl_by_role_check sync_portctl_roles/;
use App::Netdisco::Util::Permission qw/acl_matches acl_matches_only/;

=head1 NAME

App::Netdisco::Web::UI::Modern::DataRoutes - the data the modern interface reads

=head1 DESCRIPTION

What the modern interface's scripts read from the browser: the normalized data
of L<App::Netdisco::Web::UI::Modern::Data>, as JSON, at C</ajax/data/v2/...>.
These are not an API: they are for the interface's own pages, answer only an XMLHttpRequest from
a signed in session (the C<X-Requested-With> header a page can only send to its
own origin is what keeps another site from reading them through the user's
cookie), and are not in the Swagger document. Port changes do not come here:
they go to the classic C</ajax/portcontrol>, whose checks stay the only ones.

A response is C<< { data => ..., meta => {...} } >>, an error
C<< { type, title, status, detail } >> (RFC 9457) with that HTTP status.

=over 4

=item C<GET /devices>

The devices, as light rows, searched, ordered and cut to a page in the
database. C<q>: words that must all appear in the device (its names, address,
model, vendor, software, location, serial or description); C<health=failing>:
only those the backend cannot reach; C<sort> (name, ip, model, os, location,
ports, last_discover) and C<dir> (asc, desc); C<limit> (at most 1000) and
C<offset>.

=item C<GET /summary>

The network at a glance: devices (and those unreachable or not discovered
lately), ports in trouble, the job queue, and the daily statistics.

=item C<GET /search?q=>

The first few devices, nodes, port descriptions and VLANs that match some text:
a MAC, an address, a VLAN number or words.

=item C<GET /me/jobs>

The jobs the signed in user queued, newest first. C<limit>: at most 100.

=item C<GET /devices/{ip}>

One device. C<ip> is its canonical IP, any of its interface addresses, or its
name.

=item C<GET /devices/{ip}/vlans>

The VLANs it knows, by number, with their names.

=item C<GET /devices/{ip}/ports>

Its ports, in port name order. C<include_hidden>: also those
C<hide_deviceports> hides; C<free_age> (1 to 31) and C<free_unit> (days,
weeks, months, years): how long a port must have been down to be free.

=item C<GET /devices/{ip}/ports/{port}>

One port, with the same C<free_*>. A port name may hold slashes; any other
reserved character is URL-encoded.

=item C<GET /devices/{ip}/ports/{port}/nodes>

The nodes seen on it, most recently seen first. C<archived>: also those no
longer active.

=item C<GET /devices/{ip}/ports/{port}/log>

Its port control log, newest first. C<limit>: at most 200.

=back

=cut

# Port names hold slashes (Gi1/0/1), so a port is the rest of the path, and the
# routes with a suffix after it are declared before the one without.

# One of the routes above: pattern is the path after /ajax/data/v2, a regex
# fragment with named captures; code gets the captures and returns the body.
sub data_route {
  my %args = @_;
  my ($pattern, $code) = @args{qw/pattern code/};

  ajax qr{^/ajax/data/v2${pattern}$} => require_login sub {
    my $body = try {
      $code->({ %{ captures() || {} } });
    }
    catch {
      # anything that is not ours, Dancer's own continuations included,
      # goes on up as it came
      die $_ unless blessed $_ and $_->isa('App::Netdisco::Web::UI::Modern::Data::Problem');
      $_;
    };

    if (blessed $body) {
      status $body->{status};
      $body = { %$body };
    }

    content_type 'application/json';
    return JSON::PP->new->utf8->canonical->allow_nonref->encode($body);
  };
}

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



data_route(
  pattern  => '/devices',
  code => sub {
    my $r = list_devices(_schema,
      map { $_ => scalar param($_) } qw/q health sort dir limit offset/);
    return { data => $r->{rows}, meta => {
      count => scalar @{ $r->{rows} }, total => $r->{total}, failing => $r->{failing} } };
  },
);

data_route(
  pattern  => '/summary',
  code => sub { return { data => network_summary(_schema), meta => {} } },
);

data_route(
  pattern  => '/search',
  code => sub {
    my $q = param('q');
    return { data => quick_search(_schema, $q), meta => { q => (defined $q ? "$q" : '') } };
  },
);

data_route(
  pattern  => '/me/jobs',
  code => sub {
    my $jobs = my_jobs(_schema, session('logged_in_user'), limit => param('limit'));
    return { data => $jobs, meta => { count => scalar @$jobs } };
  },
);

data_route(
  pattern  => '/devices/(?<ip>[^/]+)/vlans',
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $vlans = device_vlans(_schema, $device);
    return { data => $vlans, meta => { device => $device->ip, count => scalar @$vlans } };
  },
);

data_route(
  pattern  => '/devices/(?<ip>[^/]+)/ports/(?<port>.+)/log',
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $port = _port_name($c->{port});
    my $log = port_log(_schema, $device, $port,
      limit => scalar param('limit'), reasons => setting('port_control_reasons'));
    return { data => $log, meta => { device => $device->ip, port => $port, count => scalar @$log } };
  },
);

data_route(
  pattern  => '/devices/(?<ip>[^/]+)/ports/(?<port>.+)/nodes',
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $port = _port_name($c->{port});
    my $nodes = port_nodes(_schema, $device, $port, archived => _flag('archived'));
    return { data => $nodes, meta => {
      device => $device->ip, port => $port, count => scalar @$nodes } };
  },
);

data_route(
  pattern  => '/devices/(?<ip>[^/]+)/ports/(?<port>.+)',
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $port = device_port(_schema, $device, _port_name($c->{port}),
      control => _control_for($device), custom_fields => _custom_fields_for(), free => _free());
    return { data => $port, meta => { device => $device->ip } };
  },
);

data_route(
  pattern  => '/devices/(?<ip>[^/]+)/ports',
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    my $ports = device_ports(_schema, $device, include_hidden => _flag('include_hidden'),
      control => _control_for($device), custom_fields => _custom_fields_for(), free => _free());
    return { data => $ports, meta => { device => $device->ip, count => scalar @$ports } };
  },
);

data_route(
  pattern  => '/devices/(?<ip>[^/]+)',
  code => sub {
    my $c = shift;
    my $device = find_device(_schema, uri_unescape($c->{ip}));
    return { data => device_summary(_schema, $device), meta => {} };
  },
);

true;
