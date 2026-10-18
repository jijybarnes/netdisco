package App::Netdisco::Web::Data::Summary;

use strict;
use warnings;

use App::Netdisco::Web::Data qw/iso8601_sql/;
use App::Netdisco::Web::Data::Devices 'list_devices';

use base 'Exporter';
our @EXPORT_OK = qw/network_summary normalize_statistics STALE_DAYS/;

=head1 NAME

App::Netdisco::Web::Data::Summary - the network at a glance, normalized

=head1 DESCRIPTION

What the modern interface's home page shows, and what C<GET /ajax/data/v2/summary>
returns: how many devices, ports and nodes there are, what needs a look, and
how the job queue is doing.

The node and address counts are the daily ones the statistics job keeps
(C<statistics>), as the classic System Information panel shows them: counting
them live costs a scan of the largest tables on every visit. What is counted
live is small or indexed: devices, the ones the backend cannot reach or has
not discovered lately, ports and those in trouble, and the queue.

=cut

use constant STALE_DAYS => 7;

sub _int { my $v = shift; (defined $v and $v =~ m/^-?\d+$/) ? 0 + $v : undef }

=head1 FUNCTIONS

=head2 normalize_statistics( \%statistics_row )

Pure: the newest C<statistics> row, as counts, and the day it is for. C<undef>
in (the statistics job has never run), C<undef> out.

=cut

sub normalize_statistics {
  my $s = shift;
  return undef unless $s;
  return {
    day          => (defined $s->{day} ? "$s->{day}" : undef),
    devices      => _int($s->{device_count}),
    device_ips   => _int($s->{device_ip_count}),
    links        => _int($s->{device_link_count}),
    ports        => _int($s->{device_port_count}),
    ports_up     => _int($s->{device_port_up_count}),
    ips          => _int($s->{ip_table_count}),
    ips_active   => _int($s->{ip_active_count}),
    nodes        => _int($s->{node_table_count}),
    nodes_active => _int($s->{node_active_count}),
    phones       => _int($s->{phone_count}),
    waps         => _int($s->{wap_count}),
  };
}

=head2 network_summary( $schema )

The home page's figures: C<devices> (C<total>, C<failing>, the C<unreachable>
ones by name, at most five, C<stale>: not discovered for C<STALE_DAYS> days),
C<ports> (C<total>, C<up>, C<errdisabled> and C<half_duplex>, linked ports
only), C<jobs>
(C<queued>, C<running>, C<failed_today>), and C<statistics> (see
L</normalize_statistics>).

=cut

sub network_summary {
  my $schema = shift;

  my $failing = list_devices($schema, health => 'failing', sort => 'name', limit => 5);
  my $total = $schema->resultset('Device')->count;
  my $stale = $schema->resultset('Device')->search({ -or => [
    'me.last_discover' => undef,
    'me.last_discover' => { '<' => \[ q{now() - ?::interval}, STALE_DAYS() . ' days' ] },
  ] })->count;

  my $ports = $schema->resultset('DevicePort');
  my $errdisabled = $ports->search(
    { 'properties.error_disable_cause' => { '!=' => undef, '<>' => '' } },
    { join => 'properties' })->count;
  my $half = $ports->search({ 'me.up' => 'up', 'me.duplex' => 'half' })->count;
  my $port_total = $ports->count;
  my $port_up = $ports->search({ 'me.up' => 'up' })->count;

  my $jobs = $schema->resultset('Admin');
  my $queued = $jobs->search({ status => 'queued', -or => [ backend => undef, backend => '' ] })->count;
  my $running = $jobs->search({ status => 'queued', backend => { '!=' => undef, '<>' => '' } })->count;
  my $failed = $jobs->search({ status => 'error', finished => { '>' => \q{now() - interval '1 day'} } })->count;

  my ($stats) = map {{ $_->get_columns }}
    $schema->resultset('Statistics')->search({}, { order_by => { -desc => 'day' }, rows => 1 })->all;

  return {
    devices => {
      total       => 0 + $total,
      failing     => 0 + $failing->{failing},
      unreachable => $failing->{rows},
      stale       => 0 + $stale,
      stale_days  => STALE_DAYS,
    },
    ports => { total => 0 + $port_total, up => 0 + $port_up, errdisabled => 0 + $errdisabled, half_duplex => 0 + $half },
    jobs  => { queued => 0 + $queued, running => 0 + $running, failed_today => 0 + $failed },
    statistics => normalize_statistics($stats),
  };
}

1;
