package Test::Netdisco::Snapshot;

use strict;
use warnings;

use File::Find ();
use File::Spec;
use Template::AutoFilter;

use base 'Exporter';
our @EXPORT_OK = qw/render_template all_templates snapshot_path stash_for
                    VIEW_ROOT SNAPSHOT_ROOT/;

use constant VIEW_ROOT     => 'share/views';
use constant SNAPSHOT_ROOT => 'xt/snapshots';

# Mirrors share/config.yml:1026-1044. If that block changes, change this.
# Production renders a CSV response with AUTO_FILTER none (Web.pm's
# before_template hook), and every CSV route renders a *_csv.tt template
# (xt/95), so the suffix is what selects it here.
sub _engine {
  my $view = shift || '';
  return Template::AutoFilter->new({
    INCLUDE_PATH => [ VIEW_ROOT ],
    START_TAG    => quotemeta('[%'),
    END_TAG      => quotemeta('%]'),
    ANYCASE      => 1,
    ABSOLUTE     => 1,
    PRE_CHOMP    => 1,
    AUTO_FILTER  => ($view =~ m/_csv\.tt\z/ ? 'none' : 'html_entity'),
    ENCODING     => 'utf8',
    # mirrors share/config.yml: the SNMP tree includes itself per open level
    RECURSION    => 1,
    # mirrors share/config.yml's PLUGINS mapping
    PLUGINS      => { csv => 'App::Netdisco::Template::Plugin::CSV' },
  });
}

=head2 all_templates

Sorted list of every C<.tt> under C<share/views>, relative to that directory.

=cut

sub all_templates {
  my @found = ();
  # no_chdir is load-bearing: without it File::Find chdirs into each directory
  # while $File::Find::name stays relative to the start, so the -f test is
  # evaluated against the wrong path and matches nothing.
  File::Find::find({ no_chdir => 1, wanted => sub {
    return unless -f $File::Find::name and $File::Find::name =~ m/\.tt$/;
    my $rel = File::Spec->abs2rel($File::Find::name, VIEW_ROOT);
    push @found, $rel;
  } }, VIEW_ROOT);
  return sort @found;
}

=head2 stash_for( $relative_path )

Template variables for one template. Almost every template renders correctly
against an empty stash: Template Toolkit is not in STRICT mode, so undefined
variables become the empty string and the markup structure still appears in
full, which is what a snapshot needs to capture.

The single exception is a CSV template whose first statement after loading the
plugin is C<[% CSV.dump(headings) %]>. Template::Plugin::CSV dereferences that
argument as an array, and an undefined C<headings> arrives as the empty string,
which dies under C<strict refs> before any output is produced. The key is
C<headings>, not C<results>: the C<FOREACH> over C<results> further down is
harmless against an empty stash, because Template Toolkit iterates an undefined
value as an empty list. Verified 2026-08-02 against all three stashes.

Two further templates carry Bootstrap or Font Awesome classes that an empty
stash never reaches, because the class-bearing markup sits behind a truthy
condition:

=over

=item C<sidebar/report/generic_report.tt>

The class-bearing branch only runs when C<report.rconfig.bind_params.size> is
true, so the stash needs one bind param entry to take that branch at all.

=item C<ajax/admintask/orphaned.tt>

The whole accordion is wrapped in C<[% IF orphans.size E<gt> 0 %]>, so the
stash needs one orphan row, even an empty one, to get past the guard.

=back

Seven further templates carry Bootstrap or Font Awesome classes behind a
C<FOREACH> over a result set, and were measured (2026-08-04) to render fewer
than half of their migration-relevant class tokens against an empty stash.
Each gets the smallest result set that reaches every branch of interest. Four
of the seven also gate some of that markup on C<user_has_role(...)>, a Perl
function rather than a stash value; each of those four stubs it the same way,
as a coderef returning true, rather than leaving some templates faked and
others not:

=over

=item C<ajax/device/ports.tt>

The table shell and its two data blocks: the rows are drawn by
F<netdisco-ports.js>, so the template's own branches are the column headers,
the escaping of the JSON into its script blocks and of the DataTables spec into
its attribute, and the port-log modal, reached with C<user_has_role> stubbed
true. C<ports_rows> carries a C<< </script> >> sequence, so the snapshot
records the template escaping it out of the way of the HTML parser.

=item C<ajax/device/port_nodes.tt>

The node list of one port over the collapse threshold, fetched when it is
opened. C<row> carries two C<stitched_nodes>, one archived and one with two
C<stitched_ips>, so the archived-node icon and the per-node IP-collapse
wrapper both render.

=item C<layouts/main.tt>

A logged-in session reaches the search bar, the account menu, and (with a
tenant configured) the tenant-switcher dropdown; C<user_has_role> stubbed true
reaches the Admin dropdown's static buttons. The three menus built from
registered plugins each get the smallest set that reaches every branch of the
loop that draws them: one navbar item, marked current so the Reports and Admin
toggles supply the inactive form of the same construct; the stock eight report
categories with two of them populated, so the empty-category branch renders
too, and one of the three reports hidden, as C<portlog> is in production; and
an admin list holding a task, a divider and a second task. Tags and labels are
the ones the shipped plugins register, so a reader can find each one in
C<lib/App/Netdisco/Web/Plugin/>.

=item C<ajax/device/details.tt>

A single device row, plus C<user_has_role> stubbed true because most of this
template's buttons and its snapshot dropdown are gated on the admin role and
there is no cheaper way to reach them.

=item C<ajax/admintask/jobqueue.tt>

One queued job. An empty C<results> takes the "queue is empty" branch and
never reaches the table at all.

=item C<ajax/admintask/acleditor.tt>

C<results> here is a DBIx::Class::ResultSet in production, walked with
C<results.next> rather than C<FOREACH>. The stash supplies the same interface
as a hashref holding one C<next> coderef that returns a single rule pair then
undef.

=item C<ajax/admintask/aclmanager.tt>

One ACL row, which is all its C<FOREACH> needs: every button and icon in the
row is unconditional once the row exists.

=item C<index.tt>

Takes the same logged-in-session branch as C<layouts/main.tt>, plus one flag
(C<vars.notfound>) for the "page not found" banner, plus C<user_has_role>
stubbed true to reach the Admin discovery form. The guest/login banners are a
remaining gap: they render only when C<NOT session.logged_in_user>, which is
mutually exclusive with the logged-in branch that unlocks everything else in
this template.

=back

B<A harness-wide note, not specific to any one template above:>
C<Template::Stash> hides any key with a leading underscore from templates
unless a caller turns that check off. C<lib/App/Netdisco/Web.pm> turns it off
before every render and C<render_template> below does the same, so a fixture
here drives C<settings._navbar_items>, C<settings._admin_tasks>,
C<settings._admin_order>, C<settings._reports>, C<settings._reports_menu>,
C<settings._report_order>, C<settings._extra_device_details>,
C<settings._extra_device_port_cols>, C<settings._additional_javascript> and
C<settings._additional_css> exactly as production does. Where markup behind one
of those is missing from a snapshot it is because no fixture supplies the
value, never because the path cannot be reached.

Two other templates also carry classes and are still left on an empty stash.
Both are recorded here as known blind spots rather than driven with fixtures:

=over

=item C<ajax/device/ports_csv.tt>

Emits CSV, not HTML: C<grep> finds zero C<class="..."> attributes anywhere in
its source. No stash, however elaborate, would give a snapshot of this
template anything to guard against a markup regression.

=item C<externallinks.tt>

The entire file is five C<BLOCK> definitions (C<external_link>,
C<external_mac_links>, C<external_ip_links>, C<external_device_links>,
C<external_device_port_links>) and no top-level C<PROCESS> or C<INCLUDE> of
any of them. Each block is only ever reached from another template that names
it explicitly. Verified empirically: even a fully populated stash supplying
C<settings.external_links.node> and C<item.net_mac.as_ieee> still produces the
same handful of blank lines as an empty stash, because rendering the file on
its own never executes a directive that calls into any block. No stash can
fix this; only rendering it from a caller that names a block would.

=back

=cut

sub stash_for {
  my $view = shift;

  return { headings => [] }
    if $view eq 'ajax/report/generic_report_csv.tt';

  return { report => { rconfig => { bind_params =>
             [ { param => 'q', type => 'text', default => '' } ] } } }
    if $view eq 'sidebar/report/generic_report.tt';

  return { orphans => [ {} ] }
    if $view eq 'ajax/admintask/orphaned.tt';

  if ($view eq 'ajax/device/ports.tt') {
    return {
      # stubbed true to reach the port-log modal, which is otherwise the
      # only gate in this template that depends on a Perl function rather
      # than a data structure
      user_has_role => sub { 1 },
      search_node => '/search?tab=node&stamps=checked',
      port_cols => [
        { name => 'c_port', label => 'Port' },
        { name => 'c_name', label => 'Name' },
        { name => 'c_connected', label => 'Connected' },
        { name => 'cf_owner', label => 'Owner <&>', extra => 1 },
      ],
      ports_rows => '[{"port":"Gi1/1","name":"</script>"}]',
      ports_meta => '{"device":"192.0.2.1","groups":["vlans"]}',
      table_spec => '{"columns":[{"data":null,"render":{"name":"portsCell","col":"status"}}],"deferRender":true}',
      settings => {
        port_control_reasons => { other => 'Other', resolved => 'Issue Resolved' },
      },
    };
  }

  if ($view eq 'ajax/device/port_nodes.tt') {
    return {
      params => { n_ip4 => 1, n_ip6 => 1, n_dns => 1 },
      settings => { devport_ips_collapse_threshold => 1 },
      mac_format_call => 'as_string',
      # Gi1/1's own two nodes, moved here from ports.tt.html's fixture: this
      # is the row ports.tt now renders as a deferred stub, so the IP-collapse
      # wrapper and the archived-node icon live in this snapshot instead.
      row => { port => 'Gi1/1',
        stitched_nodes => [ { active => 0,
            net_mac => { as_string => 'aa:bb:cc:00:01:01' },
            stitched_ips => [ { ip => '192.0.2.11', active => 1,
              dns => 'host11.example.com' } ] },
          { active => 1,
            net_mac => { as_string => 'aa:bb:cc:00:01:02' },
            stitched_ips => [ { ip => '192.0.2.12', active => 1,
                dns => 'host12.example.com' },
              { ip => '192.0.2.13', active => 1,
                  dns => 'host13.example.com' } ] } ],
      },
    };
  }

  if ($view eq 'layouts/main.tt') {
    return {
      session => { logged_in_user => 'demo' },
      # stubbed true to reach the Admin dropdown's static buttons
      user_has_role => sub { 1 },
      # marks the one navbar item current, so the two dropdown toggles below
      # supply the same construct in its inactive form
      vars => { nav => 'inventory' },
      settings => {
        tenant_databases => ['netdisco'],
        tenant_data => { netdisco => { displayname => 'Netdisco' } },
        tenant_tags => ['netdisco'],
        _navbar_items => [
          { tag => 'inventory', path => '/inventory', label => 'Inventory' },
        ],
        # the stock category list, of which two are given reports: the rest
        # take the empty-category branch of the same loop
        _report_order =>
          [qw/Device Port IP Node VLAN Network Wireless/, 'My Reports'],
        _reports_menu => {
          'Device' => ['deviceaddrnodns'],
          'Port'   => ['portssid', 'portlog'],
        },
        _reports => {
          deviceaddrnodns => { label => 'IPs without DNS Entries' },
          portssid        => { label => 'Port SSID Inventory' },
          # registered hidden in production too, which is the case that
          # exercises the menu loop's skip
          portlog         => { label => 'Port Control Log', hidden => 1 },
        },
        _admin_order => [qw/duplicatedevices divider users/],
        # 'divider' is absent from this hash on purpose: register_admin_task
        # pushes the tag onto _admin_order and returns before recording a
        # task, and that asymmetry is what makes the loop's divider branch
        # reachable
        _admin_tasks => {
          duplicatedevices => { label => 'Duplicate Devices' },
          users            => { label => 'User Management' },
        },
      },
    };
  }

  if ($view eq 'ajax/device/details.tt') {
    return {
      # stubbed true because most of this template's actions are admin-only
      user_has_role => sub { 1 },
      d => {
        layers => '01010101', pae_is_enabled => 1,
        is_discoverable => 1, is_arpnipable => 1, is_macsuckable => 0,
      },
      filtered_tags => ['core'],
    };
  }

  if ($view eq 'ajax/admintask/jobqueue.tt') {
    return {
      results => [
        { job => 1, backend => 'localhost', action => 'discover',
          status => 'queued', username => 'demo', duration => '5s' },
      ],
    };
  }

  # The tree renders nothing at all without rows, so its snapshot would be an
  # empty file guarding nothing. One branch holding one leaf is enough to
  # capture both shapes a row can take.
  if ($view eq 'ajax/device/snmptree.tt') {
    return {
      device => '192.0.2.1',
      nodes => [
        { oid => '.1.3', label => 'org (3)', icon => 'fas fa-folder text-info',
          has_children => 1, open => 1, children => [
            { oid => '.1.3.6', label => 'dod (6)', icon => 'fas fa-leaf text-muted',
              has_children => 0, open => 0, children => [] },
          ] },
      ],
    };
  }

  if ($view eq 'ajax/admintask/acleditor.tt') {
    my @pairs = ( {
      id => 1,
      left_acl_with_dns => { ruleset => [ [ '192.0.2.0/24' ] ] },
      right_acl => { rules => ['80'] },
    } );
    return {
      acl_name => 'demo',
      params => { acl_type => 'host_port' },
      # production's `results` is a DBIx::Class::ResultSet, walked with
      # results.next rather than FOREACH; a coderef reproduces just that
      results => { next => sub { shift @pairs } },
    };
  }

  if ($view eq 'ajax/admintask/aclmanager.tt') {
    return { results => [ { acl_name => 'demo', acl_type => 'host' } ] };
  }

  if ($view eq 'index.tt') {
    return {
      session => { logged_in_user => 'demo' },
      # stubbed true to reach the Admin discovery form
      user_has_role => sub { 1 },
      params => { login_failed => 1 },
      vars => { notfound => 1 },
    };
  }

  return {};
}

=head2 render_template( $relative_path, \%stash? )

Returns C<($html, undef)> on success or C<(undef, $error)> on failure.

With a stash hashref the template renders against that instead of
C<stash_for>. It is for a test that needs a branch no snapshot reaches, such as
the per-tab C<FOREACH> in C<device.tt> and C<search.tt>, whose bodies never run
against the empty tab lists a snapshot renders with. The snapshots themselves
must not pass one, or they would depend on their caller.

=cut

sub render_template {
  my $view = shift;
  my $stash = shift;
  my $engine = _engine($view);
  my $out = '';
  # Templates read empty values from the stash; that is expected here and the
  # resulting numeric warnings are noise, not signal.
  local $SIG{__WARN__} = sub { };
  # Mirrors lib/App/Netdisco/Web.pm:404, which the application sets before
  # every render so settings._foo keys resolve instead of being hidden by
  # Template::Stash's leading-underscore filter. This must run after the
  # _engine($view) call above: that call is what first loads Template::Stash and
  # assigns its qr/^[_.]/ default, so setting this beforehand would only be
  # overwritten by that load. Localized to this one process() call so the
  # package global cannot leak into another subtest in this process.
  local $Template::Stash::PRIVATE = undef;
  if ($engine->process($view, ($stash || stash_for($view)), \$out)) {
    return ($out, undef);
  }
  return (undef, scalar $engine->error);
}

=head2 snapshot_path( $relative_path )

Where the committed snapshot for a template lives.

=cut

sub snapshot_path {
  my $view = shift;
  return join '/', SNAPSHOT_ROOT, $view . '.html';
}

1;
