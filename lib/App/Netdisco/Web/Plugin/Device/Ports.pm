package App::Netdisco::Web::Plugin::Device::Ports;

use Dancer ':syntax';
use Dancer::Plugin::Ajax;
use Dancer::Plugin::DBIC;
use Dancer::Plugin::Auth::Extensible;

use App::Netdisco::Util::Permission qw/acl_matches permitted_by_acl/;
use App::Netdisco::Util::Port qw/port_acl_service port_acl_name to_speed/;
use App::Netdisco::Util::Web qw/pane_history_header escape_for_script_context/;
use App::Netdisco::Web::Plugin;

use List::MoreUtils 'singleton';
use NetAddr::MAC ();
use DBIx::Class::ResultClass::HashRefInflator;
use URI::Escape 'uri_escape';

register_device_tab({ tag => 'ports', label => 'Ports', provides_csv => 1 });

# $nodes_name names a has_many relation, but the source it reads from is a
# different name again.
my %node_result_class = (
    nodes                 => 'Node',
    active_nodes          => 'Virtual::ActiveNode',
    nodes_with_age        => 'Virtual::NodeWithAge',
    active_nodes_with_age => 'Virtual::ActiveNodeWithAge',
);

# Fetches nodes for one device and groups them by port name. Split out from
# the route so xt can call it without a session, the route being require_login.
#
# HashRefInflator returns plain hashrefs, and Template Toolkit's FOREACH over
# a bare hashref iterates its key/value pairs instead of treating it as one
# item, so manufacturer (belongs_to) and netbios (might_have) are wrapped in
# an arrayref to restore the one-row-or-none shape the template expects.
# wireless is has_many and arrives as an arrayref already.
#
# $for_browser leaves out net_mac, which only a template reads: the pane sends
# the MAC as Postgres prints a macaddr, which is already NetAddr::MAC's IEEE
# form, and building the object costs more than the rest of a node's row.
sub _stitch_nodes {
    my ($schema, $device_ip, $rows, $nodes_name, $ips_name, $node_order,
        $extra_prefetch, $only_ports, $for_browser) = @_;

    my %cond = (switch => $device_ip);
    $cond{port} = { -in => $only_ports }
      if $only_ports and scalar @$only_ports;

    my $node_rs = $schema->resultset($node_result_class{$nodes_name})
      ->search(\%cond, {
        order_by => $node_order,
        prefetch => [ $ips_name, @{ $extra_prefetch || [] } ],
      });
    $node_rs->result_class('DBIx::Class::ResultClass::HashRefInflator');

    my %nodes_by_port = ();
    for my $node ($node_rs->all) {
        $node->{stitched_ips} = delete $node->{$ips_name} || [];
        $node->{net_mac} = NetAddr::MAC->new(mac => ($node->{mac} || ''))
          unless $for_browser;
        $node->{manufacturer} = [ $node->{manufacturer} ] if $node->{manufacturer};
        $node->{netbios} = [ $node->{netbios} ] if $node->{netbios};
        push @{ $nodes_by_port{ $node->{port} } }, $node;
    }

    # attached here rather than by the caller, so a test exercises the same
    # key the template reads.
    $_->{stitched_nodes} = ($nodes_by_port{ $_->port } || []) for @$rows;
    return;
}

# Decides whether to fetch nodes for this view, and how widely, as the
# $only_ports argument to _stitch_nodes. Kept free of param() so xt can pin
# the decision without a session.
#
# The neighbors-only branch is the shipped default, c_neighbors being checked
# in config.yml and c_nodes not. It reads node data only to name the MAC
# behind a port's remote_ip, so it fetches nothing when no port carries one,
# and only those ports when some do.
#
# Returns undef to fetch nothing, or an arrayref for $only_ports: empty means
# the whole device, non-empty scopes the fetch to those ports. The c_nodes
# branch's empty arrayref only reaches the CSV export as written: the pane
# path narrows it again via _threshold_scope before any fetch runs.
sub _node_fetch_scope {
    my ($want_nodes, $want_neighbors, $rows) = @_;

    return [] if $want_nodes;
    return undef if not $want_neighbors;

    my @neighbor_ports = map { $_->port } grep { $_->remote_ip } @$rows;
    return undef if not scalar @neighbor_ports;
    return \@neighbor_ports;
}

# n_archived swaps $nodes_name to nodes, which is the whole table rather than
# the archived half, so a shadow built with active = 0 there would drop the
# active nodes back out and a MAC visible on screen would stop being findable.
# Derived from $nodes_name so this and %node_result_class cannot drift apart.
sub _shadow_active_fragment {
    my ($nodes_name) = @_;
    return $nodes_name =~ m/^active/ ? 'AND n.active' : '';
}

# Builds the DataTables search shadow: one string per port carrying every
# node's mac, ip, dns and vlan text, plus ssid and netbios when asked for, so
# the filter can find a node whose markup this response does not render.
# Built in one statement rather than by concatenating the fetched rows in
# Perl, which costs more than the render it exists to save.
#
# The node_ip lateral's "active = n.active" mirrors Node's ips relationship,
# which joins foreign.active => self.active, so an archived node gets archived
# IPs. Get it wrong and the filter matches archived IPs that are not on
# screen. node_wireless and node_nbt are keyed on mac alone, with no active
# condition, so their laterals match that instead.
#
# vlan has no n_* guard in the cell and is always included. ssid, netbios and
# vendor are joined only under their own guards: a field the cell does not
# render need not be findable, and each join has a real cost.
sub _attach_search_shadow {
    my ($schema, $device_ip, $rows, $active_fragment, $want_ssid, $want_netbios,
        $mac_format, $want_vendor) = @_;

    my ($ssid_select, $ssid_join) = ('', '');
    if ($want_ssid) {
        $ssid_select = q{ || ' ' || COALESCE(w.txt, '')};
        $ssid_join = q{
          LEFT JOIN LATERAL (
            SELECT string_agg(ssid, ' ') AS txt
              FROM node_wireless WHERE mac = n.mac) w ON true};
    }

    # nbuser is a logged-in user rather than the machine's own NetBIOS
    # hostname, so nbname does not cover it, and nbt.ip is not always one of
    # the node's own IPs, so the node_ip lateral does not either. The
    # '[No User]' fallback the cell renders is left out: it would match
    # every node that has no NetBIOS user.
    my ($netbios_select, $netbios_join) = ('', '');
    if ($want_netbios) {
        $netbios_select = q{ || ' ' || COALESCE(b.txt, '')};
        $netbios_join = q{
          LEFT JOIN LATERAL (
            SELECT string_agg(COALESCE(nbname, '') || ' ' || COALESCE(domain, '')
                 || ' ' || COALESCE(nbuser, '') || ' ' || COALESCE(ip::text, ''), ' ') AS txt
              FROM node_nbt WHERE mac = n.mac) b ON true};
    }

    # manufacturer is belongs_to on the node's oui, so at most one row and a
    # plain LEFT JOIN rather than a lateral. abbrev, not company, because
    # abbrev is what the cell renders.
    my ($vendor_select, $vendor_join) = ('', '');
    if ($want_vendor) {
        $vendor_select = q{ || ' ' || COALESCE(m.abbrev, '')};
        $vendor_join = q{
          LEFT JOIN manufacturer m ON m.base = n.oui};
    }

    # The cell renders the MAC in the chosen format, so on any setting but
    # IEEE the string on screen is not the one Postgres stores and a filter on
    # the visible MAC would miss. The displayed form is carried beside the
    # canonical one rather than instead of it, so a pasted IEEE address keeps
    # working whatever the setting. IEEE needs no entry here: it is exactly
    # what mac::text already gives. Kept in step with NetAddr::MAC's as_cisco,
    # as_microsoft and as_sun, which netdisco-ports.js mirrors.
    my %mac_as = (
        cisco     => q{regexp_replace(replace(n.mac::text, ':', ''),
                         '(.{4})(.{4})(.{4})', '\1.\2.\3')},
        microsoft => q{replace(n.mac::text, ':', '-')},
        sun       => q{replace(regexp_replace(n.mac::text,
                         '(^|:)0([0-9a-f])', '\1\2', 'g'), ':', '-')},
    );
    my $mac_select = '';
    if ($mac_format and my $expr = $mac_as{ lc $mac_format }) {
        $mac_select = qq{ || ' ' || $expr};
    }

    my $sql = sprintf(q{
        SELECT n.port,
               string_agg(n.mac::text || ' ' || COALESCE(n.vlan, '') || ' '
                 || COALESCE(i.txt, '')%s%s%s%s, ' ') AS s
          FROM node n
          LEFT JOIN LATERAL (
            SELECT string_agg(ip::text || ' ' || COALESCE(dns, ''), ' ') AS txt
              FROM node_ip WHERE mac = n.mac AND active = n.active) i ON true
          %s%s%s
         WHERE n.switch = ? %s
         GROUP BY n.port
    }, $ssid_select, $netbios_select, $vendor_select, $mac_select,
       $ssid_join, $netbios_join, $vendor_join, $active_fragment);

    my $shadow = $schema->storage->dbh_do(sub {
      my (undef, $dbh) = @_;
      $dbh->selectall_arrayref($sql, undef, $device_ip);
    });

    my %shadow_by_port = map {; $_->[0] => ($_->[1] || '') } @$shadow;
    $_->{nodes_search} = ($shadow_by_port{ $_->port } || '') for @$rows;
    return;
}

# The nodes cell and the neighbors cell are one <td>, and data-search on a
# <td> replaces that cell's whole search text rather than adding to it, so a
# port's own neighbor identity has to be appended or it stops being findable
# once c_nodes is on.
#
# remote_ip, remote_port, remote_dns, remote_id and remote_type are
# device_port columns (remote_dns via the with_properties join the route
# always applies) and are safe to read whatever the params say. neighbor_ip
# and neighbor_dns come from a +select added only under c_neighbors, and
# get_column dies for a column that was never selected. remote_inventory is a
# method, not a column: it reads columns only with_remote_inventory selects,
# which the route applies only under n_inventory, so it dies the same way
# unless guarded on that flag.
sub _augment_neighbor_search {
    my ($rows, $want_neighbors, $want_inventory) = @_;

    for my $row (@$rows) {
        my @extra = grep { defined and length }
          ($row->remote_ip, $row->remote_port, $row->remote_dns,
           $row->remote_id, $row->remote_type);
        push @extra, grep { defined and length }
          ($row->get_column('neighbor_ip'), $row->get_column('neighbor_dns'))
          if $want_neighbors;
        if ($want_inventory) {
            my $inventory = $row->remote_inventory;
            push @extra, $inventory if defined $inventory and length $inventory;
        }

        next unless @extra;
        $row->{nodes_search} = join ' ', grep { length } ($row->{nodes_search}, @extra);
    }
    return;
}

# Shared with the one-port route below: the node source and the ordering and
# prefetch terms must not drift between the two, or the deferred fetch draws
# its rows in a different order than the eager path would have. Kept free of
# the c_nodes/c_neighbors gate the main route used to apply to the ordering
# and prefetch terms, because the deferred fetch never sends either param and
# an empty @node_order would leave it unordered.
sub _node_display_options {
    my $nodes_name = (param('n_archived') ? 'nodes' : 'active_nodes');
    $nodes_name .= '_with_age' if param('n_age');

    my $ips_name = ((param('n_ip4') and param('n_ip6')) ? 'ips'
                   : param('n_ip4') ? 'ip4s'
                   : 'ip6s');

    my @node_order = (
      \qq{regexp_replace(COALESCE(me.vlan, '0'), '[^0-9]*' ,'0') :: integer},
      'me.mac',
      "${ips_name}.ip",
    );

    my @extra_prefetch = ();
    push @extra_prefetch, 'wireless' if param('n_ssid');
    push @extra_prefetch, 'netbios' if param('n_netbios');
    push @extra_prefetch, 'manufacturer' if param('n_vendor');

    return ($nodes_name, $ips_name, \@node_order, \@extra_prefetch);
}

# One query, run once per c_nodes request rather than once per row: reads the
# same table _attach_search_shadow does, under the same active fragment, so a
# port cannot say "N nodes" here and expand to a different number there.
sub _count_nodes_by_port {
    my ($schema, $device_ip, $rows, $active_fragment) = @_;

    my $sql = sprintf(q{
        SELECT n.port, count(*) AS n
          FROM node n
         WHERE n.switch = ? %s
         GROUP BY n.port
    }, $active_fragment);

    my $counts = $schema->storage->dbh_do(sub {
      my (undef, $dbh) = @_;
      $dbh->selectall_arrayref($sql, undef, $device_ip);
    });

    my %count_by_port = map {; $_->[0] => $_->[1] } @$counts;
    $_->{node_count} = ($count_by_port{ $_->port } || 0) for @$rows;
    return \%count_by_port;
}

# Carries the display options that change how a node row renders, built once
# here rather than in the browser, so the deferred fetch draws the same
# markup the eager path would have. mac_format feeds mac_format_call in
# Web.pm, which every node's MAC is rendered through. Kept free of param()
# so xt can pin the querystring without a session.
sub _deferred_node_params {
    my ($n_ip4, $n_ip6, $n_dns, $n_age, $n_ssid, $n_vendor, $n_netbios,
        $n_archived, $mac_format) = @_;

    my $qs = '';
    $qs .= '&n_ip4=1' if $n_ip4;
    $qs .= '&n_ip6=1' if $n_ip6;
    $qs .= '&n_dns=1' if $n_dns;
    $qs .= '&n_age=1' if $n_age;
    $qs .= '&n_ssid=1' if $n_ssid;
    $qs .= '&n_vendor=1' if $n_vendor;
    $qs .= '&n_netbios=1' if $n_netbios;
    $qs .= '&n_archived=1' if $n_archived;
    $qs .= '&mac_format=' . uri_escape($mac_format) if $mac_format;
    return $qs;
}

# Ports at or under the threshold get their own row fetched; a port over it
# still gets one when it might carry a neighbor's own MAC, since the
# Neighbors column reads stitched_nodes for that regardless of the node
# list's own threshold, but only under c_neighbors: that carve-out is what
# makes neighbor_mac renderable at all, and stitching every node of an
# over-threshold trunk port just to throw the render away is expensive on
# exactly the ports a core switch has the most of. Kept free of param() and
# setting() so xt can pin the decision without a session.
sub _threshold_scope {
    my ($threshold, $want_neighbors, $count_by_port, $rows) = @_;
    return [ map { $_->port }
      grep { ($count_by_port->{ $_->port } || 0) <= $threshold
             or ($want_neighbors and $_->remote_ip) } @$rows ];
}

# The MAC behind each neighbor's own address, which is all the neighbors
# column reads from a port's nodes: one statement, where stitching fetched
# every node of every port with a neighbor, and their IPs, SSIDs and NetBIOS
# names, to find one MAC among them. Picks the node the stitched list would
# have reached first: the node source and IP family the node options choose,
# ordered by vlan then mac as _node_display_options orders them. Kept free of
# param() so xt can pin it without a session.
sub _neighbor_macs {
    my ($schema, $device_ip, $nodes_name, $ips_name) = @_;

    my $family = ($ips_name eq 'ip4s') ? 'AND family(i.ip) = 4'
               : ($ips_name eq 'ip6s') ? 'AND family(i.ip) = 6'
               : '';

    my $sql = sprintf(q{
        SELECT DISTINCT ON (n.port) n.port, n.mac::text
          FROM device_port p
          JOIN node n ON n.switch = p.ip AND n.port = p.port
          JOIN node_ip i ON i.mac = n.mac AND i.active = n.active
                        AND i.ip = p.remote_ip
         WHERE p.ip = ? AND p.remote_ip IS NOT NULL %s %s
         ORDER BY n.port,
                  regexp_replace(COALESCE(n.vlan, '0'), '[^0-9]*' ,'0') :: integer,
                  n.mac
    }, _shadow_active_fragment($nodes_name), $family);

    my $macs = $schema->storage->dbh_do(sub {
      my (undef, $dbh) = @_;
      $dbh->selectall_arrayref($sql, undef, $device_ip);
    });

    return { map {; $_->[0] => $_->[1] } @$macs };
}

# The groups of data the pane can carry beside a port's own fields, and the
# fields of a row each one owns: what the browser replaces when it merges a
# group in, and all _group_json may set for it (xt/147 holds the one to the
# other). Each group costs a query, a join or a render the others do not, so
# it is fetched only when an option needing it is on, and netdisco-ports.js
# asks the data route for it when such an option is switched on later.
#
# Which options need which group is configuration, not code: the "groups" key
# of the option in sidebar_defaults, or of the column a plugin registers.
# These are only the groups this file can deliver; a name outside them in a
# configuration is ignored rather than waited for.
#
# "cells" is the plugin columns that bring their own template, and "links" the
# external links column: both are rendered here rather than in the browser, so
# that what a site or plugin wrote in Template Toolkit keeps working.
my %GROUP_FIELDS = (
    vlans     => [qw/vlan_count vlan_set/],
    power     => [qw/power/],
    ssid      => [qw/ssids/],
    comment   => [qw/comment/],
    neighbors => [qw/neighbor_ip neighbor_dns neighbor_mac/],
    nodes     => [qw/node_count node_search nodes/],
    admin     => [qw/acl_service acl_pvid acl_name/],
    links     => [qw/links_html/],
    cells     => [qw/cells_html/],
);
my @GROUPS = sort keys %GROUP_FIELDS;
sub _group_fields { return \%GROUP_FIELDS }

# The one selecting option the sidebar template defines itself rather than
# take from the configuration: ports are shown or not by their status.
my $STATUS_OPTION = 'port_state';

sub _list {
    my $value = shift;
    return () unless defined $value;
    return (ref [] eq ref $value) ? @$value : ($value);
}

# Plugin columns that bring their own device_port_column.tt, looked up once
# per request on the template path rather than once per row by an INCLUDE
# that fails for every custom field: a failed INCLUDE stats every path
# again, on every row.
sub _template_cells {
    my @paths = @{ config->{engines}->{netdisco_template_toolkit}->{INCLUDE_PATH} || [] };
    return [ grep {
      my $name = $_->{name};
      scalar grep { -f "$_/plugin/$name/device_port_column.tt" } @paths;
    } grep { not $_->{hidden} } @{ setting('_extra_device_port_cols') || [] } ];
}

# What each sidebar option does to the table, built from the configuration
# and nothing else, so an option, column or custom field added there works
# without a line of code here or in the browser. $columns is port_columns,
# $defaults the device_ports options of sidebar_defaults, which carry the
# options that are not columns, and $groups the groups available to this user
# on this site. Free of param() and setting() so xt can pin it.
#
# An option is a column when it is in $columns. It draws the cell named by its
# "cell" key, which is its own name unless it says otherwise, and the cells of
# the options sharing a name are one table column. An option that is not a
# column but carries "cell", "groups" or "reselect" says how it changes the
# table. An option needing a group that is not available is left out whole:
# that is how External Links goes when none are configured, and Port Control
# when the user has no right to it.
sub _port_options {
    my ($columns, $defaults, $groups, $with_template) = @_;
    my %option = ();
    my @order = ();
    my %is_column = map {($_->{name} => 1)} @$columns;

    foreach my $item (@$columns) {
        next if $item->{hidden};
        my $name = $item->{name};
        my @groups = grep { $GROUP_FIELDS{$_} } _list($item->{groups});
        push @groups, 'cells' if $with_template->{$name};
        next if grep { not $groups->{$_} } @groups;

        my @cell = _list($item->{cell});
        my %opt = (
          label  => $item->{label},
          groups => \@groups,
          cell   => (scalar @cell ? \@cell : [$name]),
          column => 1,
        );
        $opt{sort} = $item->{sort} if defined $item->{sort};
        if (exists $item->{position}) {
            $opt{extra} = 1;
            $opt{field} = $item->{field} if $item->{field};
            $opt{editable} = 1 if $item->{editable};
            $opt{template} = 1 if $with_template->{$name};
        }
        $option{$name} = \%opt;
        push @order, $name;
    }

    foreach my $name (sort keys %$defaults) {
        next if $is_column{$name}; # a column, or left out above
        my $item = $defaults->{$name};
        next unless ref {} eq ref $item;
        my @groups = grep { $groups->{$_} } _list($item->{groups});
        my @cell = _list($item->{cell});
        next unless scalar @groups or scalar @cell or $item->{reselect};
        $option{$name} = {
          groups => \@groups, cell => \@cell,
          ($item->{reselect} ? (reselect => 1) : ()),
        };
    }
    $option{$STATUS_OPTION} ||= { groups => [], cell => [], reselect => 1 };

    # the table's columns: the cells the options draw, in the order the
    # sidebar lists the options, which is also where plugin columns go
    my (@cells, %cell) = ();
    foreach my $name (@order) {
        my $opt = $option{$name};
        foreach my $cell_name (@{ $opt->{cell} }) {
            next if $cell_name eq 'none';
            my $cell = $cell{$cell_name} ||= do {
                push @cells, { name => $cell_name, options => [] };
                $cells[-1];
            };
            push @{ $cell->{options} }, $name;
            # the title until the browser joins those of the options that are
            # on, for a cell that several share
            $cell->{label} = $opt->{label} unless defined $cell->{label};
            foreach my $key (qw/sort extra field editable template/) {
                $cell->{$key} = $opt->{$key}
                  if defined $opt->{$key} and not defined $cell->{$key};
            }
        }
    }

    return { options => \%option, columns => \@cells };
}

# The groups the columns that are on need. $on answers whether an option is
# ticked, and is the only way this learns of the request. An option that is no
# column feeds the groups a column needs and none of its own, so that a ticked
# Archived Data fetches nothing while the nodes are not shown.
sub _groups_for_options {
    my ($on, $options) = @_;
    my %want = ();
    foreach my $name (keys %$options) {
        next unless $options->{$name}->{column} and $on->($name);
        $want{$_} = 1 for @{ $options->{$name}->{groups} || [] };
    }
    return \%want;
}

# The groups named in the data route's "groups" parameter, those this file
# does not deliver and those not available dropped. Free of param() for the
# same reason as above.
sub _groups_from_list {
    my ($list, $groups) = @_;
    return { map {($_ => 1)}
      grep { $GROUP_FIELDS{$_} and $groups->{$_} } split m/,/, ($list || '') };
}

# The groups this site and user can have: all but the two that depend on
# something being there.
sub _available_groups {
    my $links = scalar @{ setting('external_links')->{'device_port'} || [] };
    return { map {($_ => 1)} grep {
      ($_ eq 'links') ? $links : ($_ eq 'admin') ? user_has_role('port_control') : 1
    } @GROUPS };
}

# The options of this request, from the live configuration.
sub _request_options {
    my $cells = _template_cells();
    my $options = _port_options(
      setting('port_columns'), setting('sidebar_defaults')->{'device_ports'},
      _available_groups(), { map {($_->{name} => 1)} @$cells });
    return ($options, $cells);
}

# The ports of one device that the request's sidebar options select, carrying
# what the groups in $want need. Shared by the pane, its CSV download and the
# data route, so the three cannot disagree on which ports are shown. Returns
# undef when the options select nothing, which every caller renders as "no
# matching records".
# $want says what the caller wants besides the ports: the groups it needs, and
# in what shape. "json" is the pane's rows as data, which skips what the browser
# does for itself: the sort, the prefetches a query of its own does cheaper, and
# the filtering of VLANs 1002-1005. "html" is the pane drawn by a template, for
# a site that has its own copy of ports.tt: the ports as that template has
# always had them. Neither is the CSV, which gets the whole device.
sub _select_ports {
    my ($device, $want) = @_;
    my $json = $want->{json};
    my $pane = ($want->{json} or $want->{html});

    my $prefer = param('prefer');
    $prefer = ''
      unless defined $prefer and $prefer =~ m/^(?:port|name|vlan)$/;

    my $set = $device->ports->with_properties->with_custom_fields;

    # refine by ports if requested
    my $f = param('f');
    my $vlan_filter = (($prefer eq 'vlan')
      or (not $prefer and defined $f and $f =~ m/^\d+$/)) ? 1 : 0;

    if ($f) {
        if ($vlan_filter) {
            return undef unless $f =~ m/^\d+$/;
        }
        else {
            if (param('partial')) {
                # change wildcard chars to SQL
                $f =~ s/\*/%/g;
                $f =~ s/\?/_/g;
                # set wildcards at param boundaries
                if ($f !~ m/[%_]/) {
                    $f =~ s/^\%*/%/;
                    $f =~ s/\%*$/%/;
                }
                # enable ILIKE op
                $f = { (param('invert') ? '-not_ilike' : '-ilike') => $f };
            }
            elsif (param('invert')) {
                $f = { '!=' => $f };
            }

            if (($prefer eq 'port') or not $prefer and
                $set->search({-or => ['me.port' => $f, 'me.descr' => $f]})->count) {

                $set = $set->search({
                  -or => [
                    'me.port' => $f,
                    'me.descr' => $f,
                    'me.slave_of' => $f,
                  ],
                });
            }
            else {
                $set = $set->search({'me.name' => $f});
                return undef unless $set->count;
            }
        }
    }

    # filter for port status if asked
    my %port_state = map {$_ => 1}
      (ref [] eq ref param('port_state') ? @{param('port_state')}
        : param('port_state') ? param('port_state') : ());

    return undef unless scalar keys %port_state;

    if (exists $port_state{free}) {
        if (scalar keys %port_state == 1) {
            $set = $set->only_free_ports({
              age_num => (param('age_num') || 3),
              age_unit => (param('age_unit') || 'months')
            });
        }
        else {
            $set = $set->with_is_free({
              age_num => (param('age_num') || 3),
              age_unit => (param('age_unit') || 'months')
            });
        }
        delete $port_state{free};
        # showing free ports requires showing down ports
        ++$port_state{down};
    }

    if (scalar keys %port_state < 3) {
        my @combi = ();

        push @combi, {'me.up' => 'up'}
          if exists $port_state{up};
        push @combi, {'me.up_admin' => 'up', 'me.up' => { '!=' => 'up'}}
          if exists $port_state{down};
        push @combi, {'me.up_admin' => { '!=' => 'up'}}
          if exists $port_state{shut};

        $set = $set->search({-or => \@combi});
    }

    # so far only the basic device_port data
    # now begin to join tables depending on the selected columns/options

    # get vlans on the port. The pane sends every VLAN and the browser drops
    # 1002-1005 itself, so that Hide VLAN 1002-1005 needs no new fetch; the
    # CSV still filters here, having no browser to do it.
    my $hide1002 = (param('p_hide1002') and not $want->{json});
    my $vlans = $set->search(
      { $hide1002 ?
        (-or => ['port_vlans.vlan' => {'<', '1002'},
                 'port_vlans.vlan' => {'>', '1005'}]) : ()
      }, {
      select => [
        'port',
        { count     => 'port_vlans.vlan', -as => 'vlan_count' },
        { array_agg => \q{port_vlans.vlan ORDER BY port_vlans.vlan}, -as => 'vlan_set' },
        { array_agg => \q{COALESCE(NULLIF(vlan_entry.description,''), vlan_entry.vlan::text) ORDER BY vlan_entry.vlan}, -as => 'vlan_name_set' },
      ],
      join => {'port_vlans' => 'vlan_entry'},
      group_by => 'me.port',
    });

    # leave the vlan query dormant (lazy) unless asked for or vlan filtering
    if ($want->{vlans} or $vlan_filter) {
        $vlans = { map {(
          $_->port => {
            # DBIC smart enough to work out this should be an arrayref :)
            vlan_count => $_->get_column('vlan_count'),
            vlan_set   => $_->get_column('vlan_set'),
            vlan_name_set => $_->get_column('vlan_name_set'),
          },
        )} $vlans->all };
    }
    else {
        $vlans = {};
    }

    # the pane carries what Use VLAN Names, Last Change and Remote Inventory
    # read whether or not they are on, so switching one needs no new fetch:
    # each is a column of a table this query joins already, or nearly so
    if (param('p_vlan_names') or $want->{json}) {
        $set = $set->search({}, {
          'join' => 'native_vlan',
          '+select' => [qw/native_vlan.description/],
          '+as'     => [qw/native_vlan_name/],
        });
    }

    # get aggregate master status (self join)
    $set = $set->search({}, {
      'join' => 'agg_master',
      '+select' => [qw/agg_master.up_admin agg_master.up/],
      '+as'     => [qw/agg_master_up_admin agg_master_up/],
    });

    # make sure query asks for formatted timestamps when needed
    $set = $set->with_times if param('c_lastchange') or $want->{json};

    # what kind of nodes are we interested in? node_order is qualified
    # against the node source, never $set: see DevicePort's
    # order_by_port_name for why the port key has to lead there. Fetched
    # separately and joined by port name below, not prefetched: one prefetch
    # of ports to nodes to IPs returns the product of all three and DBIC
    # inflates every row of it. _stitch_nodes still prefetches IPs and
    # wireless together off the node, which reintroduces that product, but
    # scoped to one node's own rows rather than every port's.
    my ($nodes_name, $ips_name, $node_order, $extra_prefetch)
      = _node_display_options();

    # retrieve SSID and PoE info, if asked for. Not prefetched for the pane's
    # rows: a prefetch makes DBIC collapse the whole result set, which on a
    # large device costs more than everything else in this query together, so
    # the pane reads them with a query of their own (_port_power, _port_ssids).
    # A plugin's own template may read them off the row, though, so while one
    # is in use the rows carry them as they always did.
    $set = $set->search({}, { prefetch => 'ssid' })
      if $want->{ssid} and (not $json or $want->{cells});

    $set = $set->search({}, { prefetch => 'power' })
      if $want->{power} and (not $json or $want->{cells});

    # retrieve neighbor devices, if asked for
    $set = $set->search({}, {
      join => 'neighbor_alias',
      '+select' => ['neighbor_alias.ip', 'neighbor_alias.dns'],
      '+as'     => ['neighbor_ip', 'neighbor_dns'],
    }) if $want->{neighbors};

    # also get remote LLDP inventory if asked for
    $set = $set->with_remote_inventory
      if param('n_inventory') or $want->{json};

    # Ordered in the database rather than after the fetch. The order is
    # portsort.js's, which is the one the browser shows, so this replaces a
    # sort_port pass whose result the browser overwrote anyway. $node_order
    # must not be added here: $set has its own mac and vlan columns and would
    # silently order by those instead.
    #
    # Only for the CSV. The pane's rows are sorted by the browser, with
    # portsort.js, before any of them is drawn, and port_sortkey() costs
    # Postgres around a tenth of a millisecond a port: most of this query on
    # a device with thousands of them.
    $set = $set->order_by_port_name() unless $json;

    # run query
    my @results = $set->all;

    # fetch and attach nodes by port name, rather than prefetching them.
    # The pane's rows find the neighbors' own MACs in one statement of their
    # own instead, so they stitch nodes only for the nodes column, and for the
    # neighbors too while a plugin's own template, which may read them off the
    # row, is in use.
    my $node_fetch_scope = _node_fetch_scope(
      $want->{nodes}, ($want->{neighbors} and (not $json or $want->{cells})),
      \@results);

    my $deferred_node_params = '';

    if (defined $node_fetch_scope) {
        my $only_ports = $node_fetch_scope;
        my $skip_stitch = 0;

        # ports_csv.tt has no collapse threshold and reads every port's
        # stitched_nodes unconditionally, so this scoping only applies to
        # the pane: a CSV export still gets the whole device.
        if ($want->{nodes} and $pane) {
            my $count_by_port = _count_nodes_by_port(schema(vars->{'tenant'}),
              $device->ip, \@results, _shadow_active_fragment($nodes_name));

            # Ports over the threshold carry a count and fetch their own rows
            # when opened; fetching them here would send rows the browser
            # hides on arrival.
            $only_ports = _threshold_scope(
              setting('devport_nodes_collapse_threshold'),
              ($json ? 0 : $want->{neighbors}), $count_by_port, \@results);
            $skip_stitch = 1 unless scalar @$only_ports;
        }

        _stitch_nodes(schema(vars->{'tenant'}), $device->ip, \@results,
          $nodes_name, $ips_name, $node_order, $extra_prefetch, $only_ports,
          $json) unless $skip_stitch;
    }

    my $neighbor_macs = (($want->{neighbors} and $json)
      ? _neighbor_macs(schema(vars->{'tenant'}), $device->ip, $nodes_name, $ips_name)
      : {});

    if ($want->{nodes} and $pane) {
        $deferred_node_params = _deferred_node_params(
          scalar param('n_ip4'), scalar param('n_ip6'),
          scalar param('n_dns'), scalar param('n_age'),
          scalar param('n_ssid'), scalar param('n_vendor'),
          scalar param('n_netbios'), scalar param('n_archived'),
          scalar param('mac_format'));

        # in the pane's rows the browser adds the port's own neighbor
        # identity to this, since whether that is on screen is something it
        # can change by itself; a template cannot, and has it added here
        _attach_search_shadow(schema(vars->{'tenant'}), $device->ip, \@results,
          _shadow_active_fragment($nodes_name),
          scalar param('n_ssid'), scalar param('n_netbios'),
          scalar param('mac_format'), scalar param('n_vendor'));
        _augment_neighbor_search(\@results, scalar $want->{neighbors},
          scalar param('n_inventory')) if $want->{html};
    }

    # filter for tagged vlan using existing agg query,
    # which is better than join inflation
    if ($vlan_filter) {
      if (param('invert')) {
        @results = grep {
            (!defined $_->vlan or $_->vlan ne $f)
              and
            (0 == scalar grep {defined and $_ ne $f} @{ $vlans->{$_->port}->{vlan_set} || [] })
        } @results;
      }
      else {
        @results = grep {
            (defined $_->vlan and $_->vlan eq $f)
              or
            (scalar grep {defined and $_ eq $f} @{ $vlans->{$_->port}->{vlan_set} || [] })
        } @results;
      }
    }

    # filter out hidden ones
    if (not param('p_include_hidden')) {
        my $port_map = {};
        my %to_hide  = ();

        map { push @{ $port_map->{$_->port} }, $_ }
             grep { $_->port }
             @results;

        map { push @{ $port_map->{$_->port} }, $_ }
            grep { $_->port }
            $device->device_ips()->all;

        foreach my $map (@{ setting('hide_deviceports')}) {
            next unless ref {} eq ref $map;

            foreach my $key (sort keys %$map) {
                # lhs matches device, rhs matches port
                next unless $key and $map->{$key};
                next unless acl_matches($device, $key);

                foreach my $port (sort keys %$port_map) {
                    next unless acl_matches($port_map->{$port}, $map->{$key});
                    ++$to_hide{$port};
                }
            }
        }

        @results = grep { ! exists $to_hide{$_->port} } @results;
    }

    # empty set would be a 'no records' msg
    return undef unless scalar @results;

    # collapsible subinterface groups
    my %port_has_dot_zero = ();
    my %port_subinterface_count = ();
    my $subinterfaces_match = (setting('subinterfaces_match') || qr/(.+)\.\d+/);

    foreach my $port (@results) {
        if ($port->port =~ m/^${subinterfaces_match}$/) {
            my $parent = $1;
            next unless defined $parent;
            ++$port_subinterface_count{$parent};
            ++$port_has_dot_zero{$parent}
              if $port->port =~ m/\.0$/
                and ($port->type and $port->type =~ m/^(?:propVirtual|ieee8023adLag)$/i);
            $port->{subinterface_group} = $parent;
        }
    }

    # one pass to index the rows by port name. the two lookups below used to
    # grep @results, re-reading every row once per parent, and on a wireless
    # controller where every port is subinterface-shaped that is the whole
    # request: 3650 parents each reading all 7300 rows and matching none of
    # them, because the bare parent port does not exist (see 1479).
    my %port_row = ();
    $port_row{ $_->port } = $_ for @results;

    foreach my $parent (keys %port_subinterface_count) {
        my $parent_port = $port_row{$parent}
          or next; # 1479 we've seen subinterfaces without parents
        $parent_port->{has_subinterface_group} = true;
        $parent_port->{has_only_dot_zero_subinterface} = true
          if exists $port_has_dot_zero{$parent}
            and $port_subinterface_count{$parent} == 1
            and ($parent_port->type
              and $parent_port->type =~ m/^(?:ethernetCsmacd|ieee8023adLag)$/i);
        if ($parent_port->{has_only_dot_zero_subinterface}) {
            my $dotzero_port = $port_row{"${parent}.0"};
            $dotzero_port->{is_dot_zero_subinterface} = true;
        }
    }

    # add acl on port config
    # this has the merged yaml and database config
    if ($want->{admin}) {
      foreach my $row (@results) {
        # port_acl_pvid is portctl_native_vlan in front of port_acl_service,
        # so the service answer is reused rather than worked out twice over
        $row->{port_acl_service} = port_acl_service($row, $device, logged_in_user);
        $row->{port_acl_pvid} = (setting('portctl_native_vlan')
          ? $row->{port_acl_service} : false);
        # for name/descr change: if service true then this is OK
        $row->{port_acl_name} = ($row->{port_acl_service} ||
          port_acl_name($row, $device, logged_in_user));
      }
    }

    # filter the tags by hide_tags setting
    my @hide = @{ setting('hide_tags')->{'device_port'} };
    map { $_->{filtered_tags} = [ singleton (@{ $_->tags || [] }, @hide, @hide) ] } @results;

    # pretty print the port running speed
    map { $_->{speed_running} = to_speed( $_->speed ) } @results;

    return {
      results => \@results,
      vlans => $vlans,
      nodes_name => $nodes_name,
      ips_name => $ips_name,
      deferred_node_params => $deferred_node_params,
      neighbor_macs => $neighbor_macs,
    };
}

# One query for every port's most recent comment, where the row's own
# last_comment method is one query per port.
sub _last_comments {
    my ($device_ip) = @_;
    my $rows = schema(vars->{'tenant'})->storage->dbh_do(sub {
      my (undef, $dbh) = @_;
      $dbh->selectall_arrayref(q{
          SELECT DISTINCT ON (port) port, log
            FROM device_port_log
           WHERE ip = ?
           ORDER BY port, creation DESC
      }, undef, $device_ip);
    });
    return { map {; $_->[0] => $_->[1] } @$rows };
}

# Every port's PoE row, and every port's SSIDs, each in one query keyed by
# port, for the reason given where _select_ports skips their prefetch.
sub _port_power {
    my ($device_ip) = @_;
    my $rows = schema(vars->{'tenant'})->storage->dbh_do(sub {
      my (undef, $dbh) = @_;
      $dbh->selectall_arrayref(q{
          SELECT port, admin, status, class, power
            FROM device_port_power WHERE ip = ?
      }, { Slice => {} }, $device_ip);
    });
    return { map {; (delete $_->{port}) => $_ } @$rows };
}

sub _port_ssids {
    my ($device_ip) = @_;
    my $rows = schema(vars->{'tenant'})->storage->dbh_do(sub {
      my (undef, $dbh) = @_;
      $dbh->selectall_arrayref(q{
          SELECT port, ssid FROM device_port_ssid WHERE ip = ? ORDER BY port, ssid
      }, undef, $device_ip);
    });
    my %ssids = ();
    push @{ $ssids{ $_->[0] } }, $_->[1] for grep { defined $_->[1] } @$rows;
    return \%ssids;
}

# The external links column and the plugin columns with their own template,
# rendered here through Template Toolkit so that what a site or plugin wrote
# keeps working, then handed to the browser as markup. One render for every
# row, each cell captured by name. The template sees what ports.tt gave a
# plugin's: the rows, the device and the variables of the loop over them.
#
# A cell a template failed to draw is left out, which is how the browser knows
# to draw the column's field instead, as the INCLUDE inside TRY always did; a
# cell it drew empty is sent empty.
sub _template_rendered_cells {
    my ($ctx, $device, $links, $cells) = @_;

    my %out = ();
    my $collect = sub {
        my ($port, $key, $html) = @_;
        $html = '' unless defined $html;
        $html =~ s/^\s+|\s+$//g;
        $out{$port}->{$key} = $html;
        return '';
    };

    template 'ajax/device/ports_cells.tt', {
      results => $ctx->{results},
      nodes => $ctx->{nodes_name},
      ips   => $ctx->{ips_name},
      vlans => $ctx->{vlans},
      device => $device,
      want_links => ($links ? 1 : 0),
      cell_cols => $cells,
      collect => $collect,
    }, { layout => 'noop' };

    return \%out;
}

# MAC addresses go to the browser in IEEE form and are drawn in the chosen
# format there, so the format can change without a fetch.
sub _ieee_mac {
    my $mac = shift;
    return undef unless defined $mac and length $mac;
    my $net_mac = eval { NetAddr::MAC->new(mac => $mac) } or return undef;
    return $net_mac->as_ieee;
}

# One node of a connected nodes cell, carrying only what the options the
# nodes were fetched with draw. The MAC is a macaddr as Postgres prints it,
# which is the IEEE form already.
sub _node_json {
    my ($node) = @_;
    my %n = (mac => $node->{mac});
    $n{vlan} = $node->{vlan} if defined $node->{vlan};
    $n{archived} = 1 if not $node->{active};
    $n{age} = $node->{time_last_age} if defined $node->{time_last_age};
    $n{ips} = [ map {{
      ip => $_->{ip},
      ($_->{dns} ? (dns => $_->{dns}) : ()),
      ($_->{active} ? () : (archived => 1)),
    }} @{ $node->{stitched_ips} || [] } ];
    $n{ssids} = [ map { $_->{ssid} } @{ $node->{wireless} } ]
      if param('n_ssid') and ref $node->{wireless} and scalar @{ $node->{wireless} };
    $n{vendor} = $node->{manufacturer}->[0]->{abbrev}
      if param('n_vendor') and ref $node->{manufacturer}
        and defined $node->{manufacturer}->[0]->{abbrev};
    $n{netbios} = [ map {{
      domain => $_->{domain}, nbname => $_->{nbname},
      nbuser => $_->{nbuser}, ip => $_->{ip},
    }} @{ $node->{netbios} } ] if param('n_netbios') and ref $node->{netbios};
    return \%n;
}

# A port's own fields, which the pane carries whatever the options, so that
# showing or hiding any column drawn from them needs no fetch.
sub _base_json {
    my ($row, $ctx, $extra_cols, $domain_suffix) = @_;
    my %c = $row->get_columns;
    my %j = ();

    foreach my $key (qw/descr type name mtu speed_admin duplex duplex_admin up
                        up_admin stp vlan slave_of remote_ip remote_port
                        remote_type remote_id remote_dns error_disable_cause
                        ifindex lastchange_stamp native_vlan_name
                        agg_master_up_admin agg_master_up/) {
        $j{$key} = $c{$key} if defined $c{$key} and length $c{$key};
    }
    # a macaddr, which Postgres prints in the IEEE form already
    $j{mac} = $c{mac} if defined $c{mac};
    $j{speed} = $row->{speed_running} if defined $row->{speed_running};

    foreach my $key (qw/is_uplink manual_topo is_master has_subinterfaces
                        remote_is_wap remote_is_phone/) {
        $j{$key} = 1 if $c{$key};
    }
    # true in the table's own default, so a port with no properties row reads
    # as not discoverable, as it always has
    $j{remote_is_discoverable} = ($c{remote_is_discoverable} ? 1 : 0);
    $j{is_free} = 1 if exists $c{is_free} and $c{is_free};

    my $inventory = $row->remote_inventory;
    $j{remote_inventory} = $inventory if length $inventory;

    $j{tags} = $row->{filtered_tags} if scalar @{ $row->{filtered_tags} || [] };

    # NAC, with the session user read as a MAC address where it is one
    if ($c{pae_authconfig_port_status} or $c{pae_authconfig_state}) {
        my $user = $c{pae_authsess_user};
        my %nac = (
          port_status => $c{pae_authconfig_port_status},
          state => $c{pae_authconfig_state},
          ($c{pae_authsess_mab} ? (mab => 1) : ()),
        );
        if (defined $user and length $user) {
            if (my $mac = _ieee_mac($user)) { $nac{user_mac} = $mac }
            else {
                (my $short = $user) =~ s/$domain_suffix//g;
                $nac{user} = $short;
            }
        }
        $j{nac} = \%nac;
    }

    # subinterface folding
    $j{group} = $row->{subinterface_group} if defined $row->{subinterface_group};
    $j{has_group} = 1 if $row->{has_subinterface_group};
    $j{only_dot_zero} = 1 if $row->{has_only_dot_zero_subinterface};
    $j{is_dot_zero} = 1 if $row->{is_dot_zero_subinterface};

    # plugin and custom field columns: the value where one is a column of this
    # row, unless the column's own only/no ACL hides the cell, in which case
    # neither the value nor the cell leaves the server. A column of someone
    # else's, with a field of its own that the row selects, is no different
    # from a custom field here.
    foreach my $config (@$extra_cols) {
        if (not permitted_by_acl($row, $config)) {
            $j{hidden_cells}->{ $config->{name} } = 1;
            next;
        }
        my $field = $config->{field};
        $j{fields}->{$field} = $c{$field}
          if $field and defined $c{$field} and length $c{$field};
    }

    return \%j;
}

# The fields of each group the browser may ask for, added to $j for $row.
sub _group_json {
    my ($j, $row, $ctx, $want, $extra, $rendered) = @_;
    my $port = $row->port;

    if ($want->{vlans}) {
        my $v = $ctx->{vlans}->{$port};
        if ($v and $v->{vlan_count}) {
            $j->{vlan_count} = $v->{vlan_count} + 0;
            # the names come once for the whole device, in the meta block
            $j->{vlan_set} = [ map { $_ + 0 } grep { defined } @{ $v->{vlan_set} || [] } ];
        }
    }

    if ($want->{power} and my $power = $extra->{power}->{$port}) {
        $j->{power} = { map {( $_ => $power->{$_} )}
          grep { defined $power->{$_} } keys %$power };
    }

    if ($want->{ssid} and my $ssids = $extra->{ssids}->{$port}) {
        $j->{ssids} = $ssids;
    }

    if ($want->{comment}) {
        $j->{comment} = $extra->{comments}->{$port}
          if defined $extra->{comments}->{$port} and length $extra->{comments}->{$port};
    }

    if ($want->{neighbors}) {
        foreach my $col (qw/neighbor_ip neighbor_dns/) {
            my $value = $row->get_column($col);
            $j->{$col} = $value if defined $value and length $value;
        }
    }

    # the MAC behind the neighbor's own address, as Postgres prints it
    if ($want->{neighbors} and my $mac = $ctx->{neighbor_macs}->{$port}) {
        $j->{neighbor_mac} = $mac;
    }

    if ($want->{nodes}) {
        $j->{node_count} = ($row->{node_count} || 0) + 0;
        $j->{node_search} = $row->{nodes_search} if length ($row->{nodes_search} || '');
        if ($j->{node_count} <= setting('devport_nodes_collapse_threshold')) {
            my $remote_ip = $row->remote_ip;
            # the node behind the neighbor's own address is drawn as the
            # neighbor, not again in the list of nodes
            $j->{nodes} = [ map { _node_json($_) } grep {
              my $node = $_;
              not ($remote_ip and grep { $_->{ip} eq $remote_ip } @{ $node->{stitched_ips} || [] });
            } @{ $row->{stitched_nodes} || [] } ];
        }
    }

    if ($want->{admin}) {
        $j->{acl_service} = 1 if $row->{port_acl_service};
        $j->{acl_pvid} = 1 if $row->{port_acl_pvid};
        $j->{acl_name} = 1 if $row->{port_acl_name};
    }

    if ($want->{links} or $want->{cells}) {
        my $r = $rendered->{$port} || {};
        $j->{links_html} = $r->{'_links'} if $want->{links} and length ($r->{'_links'} || '');
        if ($want->{cells}) {
            my %cells = map {( $_ => $r->{$_} )} grep { $_ ne '_links' } keys %$r;
            $j->{cells_html} = \%cells if scalar keys %cells;
        }
    }

    return $j;
}

# The rows as the browser receives them: the port's own fields when $base is
# set, and the fields of each group in $want. Of the plugin columns with a
# template, only those that are on are rendered, as ports.tt only ever drew
# the ones that were.
sub _ports_json_rows {
    my ($ctx, $device, $want, $base) = @_;

    my $extra_cols = [ grep { not $_->{hidden} } @{ setting('_extra_device_port_cols') || [] } ];
    my $extra = {
      comments => ($want->{comment} ? _last_comments($device->ip) : {}),
      power => ($want->{power} ? _port_power($device->ip) : {}),
      ssids => ($want->{ssid} ? _port_ssids($device->ip) : {}),
    };
    my $rendered = (($want->{links} or $want->{cells})
      ? _template_rendered_cells($ctx, $device, $want->{links},
          ($want->{cells} ? [ grep { param($_->{name}) } @{ _template_cells() } ] : []))
      : {});
    my $domain_suffix = setting('domain_suffix');

    my @out = ();
    foreach my $row (@{ $ctx->{results} }) {
        my $j = ($base ? _base_json($row, $ctx, $extra_cols, $domain_suffix) : {});
        $j->{port} = $row->port;
        _group_json($j, $row, $ctx, $want, $extra, $rendered);
        push @out, $j;
    }
    return \@out;
}

# Everything netdisco-ports.js needs besides the rows, built from the options
# (see _port_options) and the settings, and from nothing it could have
# hard-coded: the browser has no list of columns, options, groups or setting
# names of its own.
sub _ports_meta {
    my ($device, $want, $ctx, $options) = @_;
    my %vlan_names = ();
    if ($want->{vlans}) {
        foreach my $v (values %{ $ctx->{vlans} || {} }) {
            my @set = @{ $v->{vlan_set} || [] };
            my @names = @{ $v->{vlan_name_set} || [] };
            $vlan_names{ $set[$_] } = $names[$_]
              for grep { defined $set[$_] } 0 .. $#set;
        }
    }

    # every plain setting the table's thresholds are made of, whichever there
    # are, and the one other the cells read
    my $settings = config;
    return {
      device => $device->ip,
      groups => [ grep { $want->{$_} } @GROUPS ],
      group_fields => \%GROUP_FIELDS,
      columns => $options->{columns},
      options => $options->{options},
      only_free => ((param('port_state') || '') eq 'free' ? 1 : 0),
      vlan_names => \%vlan_names,
      settings => {
        map {( $_ => $settings->{$_} )}
        grep { not ref $settings->{$_} } 'portctl_topology',
          grep { m/^devport_/ } keys %$settings
      },
      urls => {
        portlog   => uri_for('/report/portlog')->path,
        search    => uri_for('/search')->path,
        device    => uri_for('/device')->path,
        topology  => uri_for('/admin/topology')->path,
        portssid  => uri_for('/report/portssid')->path,
        nodevendor => uri_for('/report/nodevendor')->path,
        netbios   => uri_for('/report/netbios')->path,
        port_nodes => uri_for('/ajax/content/device/port/nodes')->path,
        data      => uri_for('/ajax/data/device/ports')->path,
      },
    };
}

# The DataTables options for the table, columns and all, so that
# netdisco-tables.js builds it like any other table on the site. A column
# sorts as its "sort" says, which is a string unless the configuration of the
# option that draws it gives another type.
sub _table_spec {
    my ($columns) = @_;
    my @columns = ({
      data => undef, orderable => \0, searchable => \0, type => 'string',
      render => { name => 'portsCell', col => 'status' },
      createdCell => { name => 'portsCellAttributes', col => 'status' },
    });
    foreach my $col (@$columns) {
        push @columns, {
          data => undef,
          type => ($col->{sort} || 'string'),
          render => { name => 'portsCell', col => $col->{name} },
          createdCell => { name => 'portsCellAttributes', col => $col->{name} },
        };
    }
    return {
      columns => \@columns,
      deferRender => \1,
      order => [[1, 'asc']],
      initComplete => 'portsInit',
    };
}

# Whether the template the pane is drawn with takes the rows as data, as the
# one this distribution ships does. A site, or a plugin, that has a template
# of its own for ajax/device/ports.tt from before that was so draws the rows
# itself, from the ports as they have always been given to it. Found by what
# the template reads, so a copy of the new one counts as new.
my %template_reads;
sub _template_takes_data {
    my $engine = engine('template');
    my $file = $engine->view('ajax/device/ports') or return true;
    my $mtime = (stat $file)[9] || 0;
    my $known = $template_reads{$file};
    if (not $known or $known->{mtime} != $mtime) {
        open my $fh, '<:encoding(UTF-8)', $file or return true;
        my $text = do { local $/; <$fh> };
        $known = $template_reads{$file}
          = { mtime => $mtime, data => (($text =~ m/\bports_rows\b/) ? 1 : 0) };
    }
    return $known->{data};
}

# device ports with a description (er, name) matching
get '/ajax/content/device/ports' => require_login sub {
    my $device = schema(vars->{'tenant'})->resultset('Device')
      ->search_for_device(param('q')) or send_error('Bad device', 400);

    my ($options, $cells) = _request_options();
    my $want = _groups_for_options(sub { scalar param(shift) }, $options->{options});

    if (not request->is_ajax) {
        # the CSV download: every port's columns as the options ask for them
        my $ctx = _select_ports($device, $want) or return;

        header( 'Content-Type' => 'text/comma-separated-values' );
        template 'ajax/device/ports_csv.tt', {
          results => $ctx->{results},
          nodes => $ctx->{nodes_name},
          ips   => $ctx->{ips_name},
          device => $device,
          vlans  => $ctx->{vlans},
        }, { layout => 'noop' };
    }
    elsif (not _template_takes_data()) {
        # a template of the site's own, which draws the rows itself
        $want->{html} = 1;
        my $ctx = _select_ports($device, $want) or return;

        template 'ajax/device/ports.tt', {
          results => $ctx->{results},
          nodes => $ctx->{nodes_name},
          ips   => $ctx->{ips_name},
          device => $device,
          vlans  => $ctx->{vlans},
          deferred_node_params => $ctx->{deferred_node_params},
        }, { layout => 'noop' };
    }
    else {
        $want->{json} = 1;
        my $ctx = _select_ports($device, $want) or return;

        my $rows = _ports_json_rows($ctx, $device, $want, 1);
        my $meta = _ports_meta($device, $want, $ctx, $options);

        template 'ajax/device/ports.tt', {
          device => $device,
          port_cols => $options->{columns},
          # escaped here as well as in the template: the template's replace
          # vmethod copes badly with the thousands of "<" the markup of the
          # links and plugin cells brings, where one Perl substitution does
          # not, and leaves it nothing to do
          ports_rows => escape_for_script_context(to_json($rows)),
          ports_meta => escape_for_script_context(to_json($meta)),
          table_spec => to_json(_table_spec($options->{columns})),
        }, { layout => 'noop' };
    }
};

# The fields of the groups named in "groups" for every port the sidebar
# options select, so the browser can show a column it did not have the data
# for without fetching the rest of the table again. Also where the browser
# says the options changed when it has everything it needs already: the
# options are remembered for the next visit either way.
ajax '/ajax/data/device/ports' => require_login sub {
    App::Netdisco::Web::Device::remember_ports_form();
    content_type 'application/json';

    # when htmx asks, the browser is saying the options changed, and the
    # address they now describe is the pane's: the history is htmx's to keep
    header( pane_history_header('device', 'ports') )
      if request->env->{'HTTP_HX_REQUEST'};

    my ($options) = _request_options();
    my $want = _groups_from_list(scalar param('groups'), _available_groups());
    return to_json({ groups => [], rows => [] }) unless scalar keys %$want;

    my $device = schema(vars->{'tenant'})->resultset('Device')
      ->search_for_device(param('q')) or send_error('Bad device', 400);

    $want->{json} = 1;
    my $ctx = _select_ports($device, $want)
      or return to_json({ groups => [ grep { $want->{$_} } @GROUPS ], rows => [] });

    my $rows = _ports_json_rows($ctx, $device, $want, 0);
    my $meta = _ports_meta($device, $want, $ctx, $options);

    return to_json({
      groups => $meta->{groups},
      rows => $rows,
      vlan_names => $meta->{vlan_names},
    });
};

# one collapsed port's node list, fetched only when the caller opens it
get '/ajax/content/device/port/nodes' => require_login sub {
    my $device = schema(vars->{'tenant'})->resultset('Device')
      ->search_for_device(param('q')) or send_error('Bad device', 400);
    my $port = param('port') or send_error('Bad port', 400);
    my $row = $device->ports->find({ port => $port })
      or send_error('Bad port', 400);

    my ($nodes_name, $ips_name, $node_order, $extra_prefetch)
      = _node_display_options();

    _stitch_nodes(schema(vars->{'tenant'}), $device->ip, [$row],
      $nodes_name, $ips_name, $node_order, $extra_prefetch, [$port]);

    template 'ajax/device/port_nodes.tt', {
      row => $row, device => $device,
    }, { layout => 'noop' };
};

true;
