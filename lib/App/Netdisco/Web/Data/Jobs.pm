package App::Netdisco::Web::Data::Jobs;

use strict;
use warnings;

use App::Netdisco::Web::Data qw/iso8601_sql/;

use base 'Exporter';
our @EXPORT_OK = qw/my_jobs normalize_job job_state/;

=head1 NAME

App::Netdisco::Web::Data::Jobs - the signed in user's own jobs, normalized

=head1 DESCRIPTION

What the modern interface's jobs list reads: the jobs the user queued, newest
first. It is the user's own jobs only, whatever their role, so that a port
change made from a device page can be followed without the admin role. The
whole queue stays on the admin job queue page.

=head1 FUNCTIONS

=head2 job_state( \%columns )

One word for where a job is. The C<admin> table says C<queued> both for a job
nobody has taken and for one a backend is working on, and tells them apart by
the backend name; C<info> is how a job found to duplicate another ends.

=cut

sub job_state {
  my $c = shift;
  my $status = $c->{status} // '';
  return 'running' if $status eq 'queued' and defined $c->{backend} and length $c->{backend};
  return 'duplicate' if $status eq 'info';
  return $status if $status =~ m/^(?:queued|done|error)$/;
  return 'queued';
}

sub _str { my $v = shift; (defined $v and length $v) ? "$v" : undef }

=head2 normalize_job( \%columns )

Pure: one C<admin> row (with the C<_iso_*> times) to the API shape. The
C<subaction> is what was asked for (a VLAN, a name, C<down-other>), the C<log>
what the backend answered.

=cut

sub normalize_job {
  my $c = shift;
  return {
    id          => 0 + $c->{job},
    action      => _str($c->{action}),
    status      => job_state($c),
    device      => _str($c->{device}),
    port        => _str($c->{port}),
    subaction   => _str($c->{subaction}),
    log         => _str($c->{log}),
    entered_at  => _str($c->{_iso_entered}),
    started_at  => _str($c->{_iso_started}),
    finished_at => _str($c->{_iso_finished}),
  };
}

=head2 my_jobs( $schema, $username, %opts )

The user's most recent jobs, newest first, C<limit> of them (25 by default, 100
at most).

=cut

sub my_jobs {
  my ($schema, $username, %opts) = @_;
  my $limit = (defined $opts{limit} and $opts{limit} =~ m/^\d+$/ and $opts{limit} > 0)
    ? ($opts{limit} > 100 ? 100 : $opts{limit}) : 25;

  my @rows = $schema->resultset('Admin')->search(
    { 'me.username' => $username },
    {
      '+columns' => { map {( "_iso_$_" => \iso8601_sql("me.$_") )} qw/entered started finished/ },
      order_by => { -desc => 'me.job' },
      rows => $limit,
    })->all;

  return [ map { normalize_job({ $_->get_columns }) } @rows ];
}

1;
