#!/usr/bin/env perl

# The Ports pane sends its rows as data, carrying for each port only the
# groups of data its shown columns need, and the browser asks the data route
# for a group when a column needing it is switched on later. Nothing about
# which option needs which group, which options share a cell, how a cell
# sorts or which options mean different ports is in the code: all of it is
# built from the configuration, so that a column added by a plugin or a
# custom field, or an option a site adds, works with no code of its own.
# These pin that, without a session: the options built from the shipped
# configuration, from configurations that add to it, the DataTables spec made
# of them, the extension cells Template Toolkit still draws, and, with a
# database, the one statement that finds each neighbor's own MAC.
#
# The options built from the shipped configuration are also the fixture
# xt/js/ports-table.test.js reads, so that the browser's tests run against
# what the server really sends. When this fails because the configuration
# changed on purpose, set REGENERATE_PORTS_FIXTURE=1 and run it once.

use strict;
use warnings;

# The configuration read is this checkout's own, not whatever copy of the
# distribution's share directory is installed beside it, which is where an
# unset DANCER_CONFDIR leads: the options below are what this tree configures.
BEGIN {
    require File::Spec;
    my $share = File::Spec->rel2abs('share');
    $ENV{DANCER_APPDIR}  ||= $share;
    $ENV{DANCER_CONFDIR} ||= $share;
    $ENV{DANCER_PUBLIC}  ||= "$share/public";
    $ENV{DANCER_VIEWS}   ||= "$share/views";
    $ENV{DANCER_ENVIRONMENT} = 'testing';
}

use Test::More 0.88;
use File::Temp 'tempdir';
use File::Path 'make_path';
use File::Slurper qw/read_text write_text/;
use JSON::MaybeXS ();
use Template::AutoFilter;
use lib 'xt/lib';
use Test::Netdisco::Snapshot ();

{
    package NetdiscoSchema;
    use App::Netdisco;
    use Dancer qw/:moose :script/;
    use Dancer::Plugin::DBIC 'schema';
    sub connected { my $s = schema('netdisco'); $s->storage->dbh_do(sub { $_[1]->do('SELECT 1') }); return $s }
}

use App::Netdisco::Web;
require App::Netdisco::Web::Plugin::Device::Ports;
my $P = 'App::Netdisco::Web::Plugin::Device::Ports';

my %ALL = map {($_ => 1)} qw/vlans power ssid comment neighbors nodes admin links cells/;
my $shipped = sub {
    return $P->can('_port_options')->(
      Dancer::setting('port_columns'),
      Dancer::setting('sidebar_defaults')->{'device_ports'},
      \%ALL, {});
};

subtest 'shippedFixture__the_options_of_the_shipped_config__are_what_the_browser_tests_read' => sub {
    my $json = JSON::MaybeXS->new(canonical => 1, pretty => 1);
    my $options = $shipped->();
    my $text = $json->encode({
      options => $options->{options}, columns => $options->{columns},
      group_fields => $P->can('_group_fields')->(),
    });

    my $file = 'xt/js/fixtures/ports-options.json';
    write_text($file, $text) if $ENV{REGENERATE_PORTS_FIXTURE};
    is read_text($file), $text,
      "$file is what the shipped configuration builds (REGENERATE_PORTS_FIXTURE=1 rewrites it)";
};

subtest 'portOptions__shipped_config__columns_and_cells' => sub {
    my $o = $shipped->();
    my %col = map {($_->{name} => $_)} @{ $o->{columns} };

    is_deeply $col{c_connected}->{options}, [qw/c_nodes c_neighbors/],
      'nodes and neighbors share one cell, in the sidebar order';
    ok !exists $col{c_nodes} && !exists $col{c_neighbors}, 'and have none each';
    ok !exists $col{c_admin}, 'port control is an option and no column';
    ok exists $o->{options}->{c_admin}, 'but still an option, with its group';
    is_deeply $o->{options}->{c_admin}->{groups}, ['admin'], 'which is the admin one';

    is $col{c_port}->{sort}, 'portsort', 'a sort type is the option\'s own';
    is $col{c_ifindex}->{sort}, 'num', 'whichever it is';
    ok !defined $col{c_type}->{sort}, 'and absent where there is none';
    is_deeply $o->{options}->{c_vmember}->{groups}, ['vlans'], 'a column says what data it needs';

    ok !$o->{options}->{c_vmember}->{reselect}, 'a column does not mean different ports';
    ok $o->{options}->{p_include_hidden}->{reselect}, 'while an option that does says so';
    ok $o->{options}->{port_state}->{reselect}, 'as does the status filter, which the sidebar defines itself';
    is_deeply $o->{options}->{n_archived}->{groups}, [qw/nodes neighbors/],
      'an option that is no column says which data it changes';
    ok !$o->{options}->{n_archived}->{column}, 'and is not a column';
    is_deeply $o->{options}->{p_vlan_names}->{cell}, [qw/c_pvid c_vmember/],
      'or which cells it draws another way';
};

subtest 'portOptions__a_group_that_is_not_available__takes_its_option_and_column_with_it' => sub {
    my %groups = %ALL;
    delete $groups{links};
    my $o = $P->can('_port_options')->(
      Dancer::setting('port_columns'), Dancer::setting('sidebar_defaults')->{'device_ports'},
      \%groups, {});
    ok !exists $o->{options}->{c_links}, 'External Links with none configured is no option';
    ok !(grep { $_->{name} eq 'c_links' } @{ $o->{columns} }), 'and no column';

    delete $groups{admin};
    $o = $P->can('_port_options')->(
      Dancer::setting('port_columns'), Dancer::setting('sidebar_defaults')->{'device_ports'},
      \%groups, {});
    ok !exists $o->{options}->{c_admin}, 'nor is Port Control one for a user with no right to it';
    ok exists $o->{options}->{c_port}, 'and the rest are untouched';
};

# What a plugin or a custom field registers is an entry of port_columns like
# any other, with whatever of the same keys it sets.
subtest 'portOptions__plugin_columns__are_columns_with_no_code_of_their_own' => sub {
    my @columns = (
      { name => 'c_port', label => 'Port' },
      { name => 'cf_owner', label => 'Owner', position => 'right', field => 'cf_owner', editable => 1 },
      { name => 'demo', label => 'Demo', position => 'mid' },
      { name => 'cf_count', label => 'Count', position => 'right', field => 'cf_count', sort => 'num',
        groups => ['ssid', 'imaginary'] },
      { name => 'cf_hidden', label => 'Hidden', position => 'right', field => 'cf_hidden', hidden => 1 },
    );
    my $o = $P->can('_port_options')->(\@columns, {}, \%ALL, { demo => 1 });
    my %col = map {($_->{name} => $_)} @{ $o->{columns} };

    is_deeply [ map { $_->{name} } @{ $o->{columns} } ], [qw/c_port cf_owner demo cf_count/],
      'in the order port_columns lists them, a hidden one left out';
    ok $col{cf_owner}->{extra} && $col{cf_owner}->{editable}, 'a custom field is extra, and editable if it says so';
    is $col{cf_owner}->{field}, 'cf_owner', 'with its field';
    ok $col{demo}->{template}, 'a column with a template of its own says so';
    is_deeply $o->{options}->{demo}->{groups}, ['cells'], 'and needs its cells drawn';
    is $col{cf_count}->{sort}, 'num', 'a column can say how it sorts';
    is_deeply $o->{options}->{cf_count}->{groups}, ['ssid'],
      'and the groups it needs, one this file does not deliver ignored';
};

subtest 'portOptions__a_site_option__is_an_option_if_it_says_what_it_does' => sub {
    my $defaults = {
      c_port => { label => 'Port' },
      n_custom => { label => 'Custom', groups => ['nodes'], cell => ['c_connected'] },
      p_inert => { label => 'Inert' },
      p_reload => { label => 'Reload', reselect => 1 },
      partial => { default => undef },
    };
    my $o = $P->can('_port_options')->([ { name => 'c_port', label => 'Port' } ], $defaults, \%ALL, {});
    is_deeply $o->{options}->{n_custom}, { groups => ['nodes'], cell => ['c_connected'] },
      'it is told what it feeds and draws';
    ok $o->{options}->{p_reload}->{reselect}, 'or that it means other ports';
    ok !exists $o->{options}->{p_inert}, 'one that says nothing is left to Update View, as it always was';
    ok !exists $o->{options}->{partial}, 'as are the filter box and its switches';
};

subtest 'groupsForOptions__the_columns_that_are_on__need_their_groups' => sub {
    my $o = $shipped->();
    my %on = map {($_ => 1)} qw/c_vmember c_nodes c_admin n_ssid n_archived/;
    my $want = $P->can('_groups_for_options')->(sub { $on{ shift() } }, $o->{options});
    is_deeply [ sort keys %$want ], [qw/admin nodes vlans/],
      'those of the columns; an option that only changes data feeds none of its own';
    is_deeply $P->can('_groups_for_options')->(sub { 0 }, $o->{options}), {},
      'no option, no group: the port fields alone';
};

subtest 'groupsFromList__only_the_groups_that_are_delivered_and_available' => sub {
    my %available = %ALL;
    delete $available{admin};
    my $want = $P->can('_groups_from_list')->('nodes,vlans,results,,admin', \%available);
    is_deeply [ sort keys %$want ], [qw/nodes vlans/],
      'not an unknown one, nor one the user may not have';
    is_deeply $P->can('_groups_from_list')->(undef, \%ALL), {}, 'no list, no group';
};

subtest 'groupFields__every_group__is_one_the_route_can_deliver_and_owns_fields' => sub {
    my $fields = $P->can('_group_fields')->();
    is_deeply [ sort keys %$fields ], [ sort keys %ALL ], 'the groups are these';
    ok scalar(@{ $fields->{$_} }), "$_ owns fields" for sort keys %$fields;
};

# The browser replaces the fields a group owns when it merges one in, so a
# field _group_json sets that the group does not own would stay behind.
{
    package Fake::Row;
    sub new { my ($class, %a) = @_; return bless { %a }, $class }
    sub port { $_[0]->{port} }
    sub remote_ip { $_[0]->{remote_ip} }
    sub get_column { $_[0]->{cols}->{ $_[1] } }
}

subtest 'groupJson__every_group__sets_only_the_fields_it_owns' => sub {
    my $owned = $P->can('_group_fields')->();
    my %on = map {($_ => 1)} keys %$owned;
    my $row = Fake::Row->new(port => 'Gi1', remote_ip => '10.0.0.9',
      node_count => 1, nodes_search => 'x', stitched_nodes => [],
      port_acl_service => 1, port_acl_pvid => 1, port_acl_name => 1,
      cols => { neighbor_ip => '10.0.0.9', neighbor_dns => 'sw' });
    my $ctx = {
      vlans => { Gi1 => { vlan_count => 2, vlan_set => [10, 20] } },
      neighbor_macs => { Gi1 => 'aa:bb:cc:dd:ee:ff' },
    };
    my $extra = {
      power => { Gi1 => { admin => 'true', power => 5 } },
      ssids => { Gi1 => ['CORP'] }, comments => { Gi1 => 'a comment' },
    };
    my $rendered = { Gi1 => { _links => '<a>l</a>', demo => '' } };

    my $j = $P->can('_group_json')->({ port => 'Gi1' }, $row, $ctx, \%on, $extra, $rendered);
    my %allowed = map {($_ => 1)} 'port', map { @$_ } values %$owned;
    is_deeply [ grep { not $allowed{$_} } sort keys %$j ], [], 'no field outside what the groups own';

    foreach my $group (sort keys %$owned) {
        my $one = $P->can('_group_json')->({ port => 'Gi1' }, $row, $ctx, { $group => 1 }, $extra, $rendered);
        my %mine = map {($_ => 1)} 'port', @{ $owned->{$group} };
        is_deeply [ grep { not $mine{$_} } sort keys %$one ], [], "$group sets only its own";
    }
    is_deeply $j->{cells_html}, { demo => '' }, 'a cell a template drew empty is sent empty';
};

subtest 'tableSpec__every_column__is_drawn_by_the_ports_renderer' => sub {
    my $columns = [
      { name => 'c_port', sort => 'portsort' }, { name => 'c_type' },
      { name => 'c_ifindex', sort => 'num' }, { name => 'c_connected' },
    ];
    my $spec = $P->can('_table_spec')->($columns);

    is scalar @{ $spec->{columns} }, 1 + scalar @$columns,
      'the status column, then one per column';
    is $spec->{columns}->[0]->{render}->{col}, 'status', 'the status column comes first';
    ok !${ $spec->{columns}->[0]->{orderable} }, 'and is not sortable';

    is $spec->{columns}->[1]->{type}, 'portsort', 'a column sorts as its configuration says';
    is $spec->{columns}->[2]->{type}, 'string', 'and as text where it says nothing';
    is $spec->{columns}->[3]->{type}, 'num', 'whatever type that is';

    foreach my $col (@{ $spec->{columns} }) {
        is $col->{render}->{name}, 'portsCell', 'drawn by netdisco-ports.js';
        is $col->{createdCell}->{name}, 'portsCellAttributes', 'with its attributes';
    }
    ok ${ $spec->{deferRender} }, 'a row is drawn when it is first shown, not before';
    is $spec->{initComplete}, 'portsInit', 'and the table set up by netdisco-ports.js';
    is_deeply $spec->{order}, [[1, 'asc']], 'sorted by port, as the pane always was';
};

# ports_cells.tt renders what a site or plugin wrote, and nothing of it may
# reach the response directly: each cell is captured and handed back by port.
subtest 'portsCells__links_and_template_columns__are_captured_by_port' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/plugin/demo", "$dir/plugin/broken", "$dir/plugin/seesall");
    write_text("$dir/plugin/demo/device_port_column.tt", '<b>[% row.port %]</b>');
    write_text("$dir/plugin/broken/device_port_column.tt", '[% THROW boom "this one fails" %]');
    # what ports.tt gave a plugin's template
    write_text("$dir/plugin/seesall/device_port_column.tt",
      '[% portname %]|[% vlans.${portname}.vlan_count %]|[% nodes %]|[% ips %]|[% config.name %]|[% device.ip %]');

    my $engine = Template::AutoFilter->new({
      INCLUDE_PATH => [ $dir, Test::Netdisco::Snapshot::VIEW_ROOT() ],
      START_TAG => quotemeta('[%'), END_TAG => quotemeta('%]'),
      ANYCASE => 1, PRE_CHOMP => 1, AUTO_FILTER => 'html_entity',
    });

    my %got = ();
    my $out = '';
    local $Template::Stash::PRIVATE = undef;
    $engine->process('ajax/device/ports_cells.tt', {
      results => [ { port => 'Gi1/1' }, { port => 'Gi1/2' } ],
      device => { ip => '192.0.2.1', dns => 'sw.example.com', name => 'sw' },
      nodes => 'active_nodes', ips => 'ips',
      vlans => { 'Gi1/1' => { vlan_count => 3 } },
      want_links => 1,
      settings => {
        external_links => { device_port => [
          { displayname => 'Wiki', url => 'http://wiki/[% port %]' },
        ] },
        _extra_device_port_cols => [],
      },
      cell_cols => [ { name => 'demo' }, { name => 'broken' }, { name => 'missing' }, { name => 'seesall' } ],
      permitted_by_acl => sub { my ($row, $config) = @_;
        return not ($row->{port} eq 'Gi1/2' and ($config->{name} || '') eq 'demo') },
      collect => sub { my ($port, $key, $html) = @_; $got{$port}{$key} = $html; return '' },
    }, \$out) or die $engine->error;

    unlike $out, qr/<b>|wiki/, 'nothing is output directly';
    like $got{'Gi1/1'}{'_links'}, qr{href="http://wiki/Gi1%2F1"}, 'the link is rendered per port';
    like $got{'Gi1/1'}{demo}, qr{<b>Gi1/1</b>}, 'the plugin template is rendered per port';
    ok !exists $got{'Gi1/2'}{demo}, 'a cell its own ACL hides is not rendered at all';
    ok !exists $got{'Gi1/1'}{broken},
      'a template that fails draws nothing, which is how the browser knows to draw the field';
    ok !exists $got{'Gi1/1'}{missing},
      'and a column with no template of its own renders nothing, and does not fail the rest';
    is $got{'Gi1/1'}{seesall}, 'Gi1/1|3|active_nodes|ips|seesall|192.0.2.1',
      'a template sees the variables ports.tt gave it';
    is $got{'Gi1/2'}{seesall}, 'Gi1/2||active_nodes|ips|seesall|192.0.2.1', 'for each row';
};

# A site or a plugin with a template of its own for ajax/device/ports.tt, from
# before the rows were data, keeps working: it is given the ports as it always
# was, found by what the template reads, so a copy of the new one still counts
# as new.
subtest 'templateTakesData__a_site_template__is_drawn_the_old_way_unless_it_reads_the_rows_as_data' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $paths = Dancer::config->{engines}->{netdisco_template_toolkit}->{INCLUDE_PATH};
    my $takes = $P->can('_template_takes_data');

    ok $takes->(), 'the shipped template takes data';

    make_path("$dir/ajax/device");
    write_text("$dir/ajax/device/ports.tt", '<table>[% FOREACH row IN results %]<tr></tr>[% END %]</table>');
    unshift @$paths, $dir;
    ok !$takes->(), 'a template of a site that draws the rows itself does not';

    write_text("$dir/ajax/device/ports.tt", '<script id="nd_ports-rows">[% ports_rows | none %]</script>');
    utime time + 10, time + 10, "$dir/ajax/device/ports.tt"; # the answer is kept by the file's mtime
    ok $takes->(), 'but a copy of the new one does';

    shift @$paths;
    ok $takes->(), 'and without a template of the site\'s own, the shipped one is back';
};

# permitted_by_acl is the one function that decides whether a custom field or
# plugin column is shown for a port, for the template token and for the data
# sent to the browser alike.
subtest 'permittedByAcl__no_and_only__hide_a_cell_for_the_template_and_the_json_alike' => sub {
    require App::Netdisco::Util::Permission;
    my $permitted = \&App::Netdisco::Util::Permission::permitted_by_acl;
    my $thing = { ip => '192.0.2.5' };

    ok $permitted->($thing, {}), 'no ACL, no hiding';
    ok !$permitted->($thing, { no => ['192.0.2.5'] }), 'no: hidden when it matches';
    ok $permitted->($thing, { no => ['192.0.2.6'] }), 'and shown when it does not';
    ok $permitted->($thing, { only => ['192.0.2.5'] }), 'only: shown when it matches';
    ok !$permitted->($thing, { only => ['192.0.2.6'] }), 'and hidden when it does not';
    ok !$permitted->(undef, {}), 'failing safe with nothing to check';
    ok !$permitted->($thing, undef), 'or no config';
};

my $schema = eval { NetdiscoSchema::connected() };
my $why = $@;

SKIP: {
    skip "no usable netdisco database: $why", 1 if not $schema;

    # a port whose neighbor's own address is among the port's active nodes
    my ($switch, $port, $mac) = $schema->storage->dbh_do(sub {
      my (undef, $dbh) = @_;
      $dbh->selectrow_array(q{
          SELECT p.ip::text, p.port, n.mac::text
            FROM device_port p
            JOIN node n ON n.switch = p.ip AND n.port = p.port AND n.active
            JOIN node_ip i ON i.mac = n.mac AND i.active AND i.ip = p.remote_ip
           ORDER BY p.ip, p.port,
                    regexp_replace(COALESCE(n.vlan, '0'), '[^0-9]*' ,'0') :: integer,
                    n.mac
           LIMIT 1
      });
    });

    skip 'no port in this database has its neighbor among its nodes', 1
      if not defined $switch;

    subtest 'neighborMacs__a_neighbor_among_the_nodes__is_found_by_its_address' => sub {
        my $macs = $P->can('_neighbor_macs')->($schema, $switch, 'active_nodes', 'ips');
        is $macs->{$port}, $mac, 'the first node, in node order, carrying the neighbor address';

        my $family = ($schema->storage->dbh_do(sub {
          $_[1]->selectrow_array('SELECT family(remote_ip) FROM device_port WHERE ip = ? AND port = ?',
            undef, $switch, $port) }) == 4) ? 'ip6s' : 'ip4s';
        my $other = $P->can('_neighbor_macs')->($schema, $switch, 'active_nodes', $family);
        ok !exists $other->{$port}, 'not when the node options leave out that address family';
    };
}

done_testing;
