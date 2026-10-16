#!/usr/bin/env perl

use strict;
use warnings;

use Test::More 0.88;
use JSON::PP ();

use App::Netdisco::Web::Data::Jobs qw/normalize_job job_state my_jobs/;
use App::Netdisco::Web::PortsModern 'port_reasons';

# The jobs the modern interface lists, and the reasons a port change is logged
# under. Pure, so pinned without a database (xt/36).

# ---- a job's state ----

is job_state({ status => 'queued', backend => '' }), 'queued', 'jobState__queued_no_backend__queued';
is job_state({ status => 'queued', backend => undef }), 'queued', 'jobState__queued_backend_unset__queued';
is job_state({ status => 'queued', backend => 'host:1234' }), 'running',
  'jobState__queued_with_a_backend__running_the_table_says_queued_for_both';
is job_state({ status => 'done', backend => 'host:1234' }), 'done', 'jobState__done__done_whatever_the_backend';
is job_state({ status => 'error' }), 'error', 'jobState__error__error';
is job_state({ status => 'info' }), 'duplicate', 'jobState__info__is_how_a_duplicate_ends';
is job_state({ status => 'something-new' }), 'queued', 'jobState__unknown__not_claimed_finished';
is job_state({}), 'queued', 'jobState__no_status__not_claimed_finished';

# ---- a job ----

my $job = normalize_job({
  job => '4721', action => 'portcontrol', device => '172.20.20.12', port => 'Ethernet2',
  subaction => 'down-other', status => 'error', backend => '', log => 'Permission denied',
  username => 'someone', userip => '10.1.2.3', debug => 1, device_key => 'k',
  _iso_entered => '2026-10-16T18:50:50+02:00', _iso_started => '2026-10-16T18:50:51+02:00', _iso_finished => undef,
});
is_deeply $job, {
  id => 4721, action => 'portcontrol', status => 'error', device => '172.20.20.12', port => 'Ethernet2',
  subaction => 'down-other', log => 'Permission denied',
  entered_at => '2026-10-16T18:50:50+02:00', started_at => '2026-10-16T18:50:51+02:00', finished_at => undef,
}, 'normalizeJob__a_row__the_documented_fields_and_nothing_else';
is(JSON::PP->new->encode([ $job->{id} ]), '[4721]', 'normalizeJob__id__a_number');

my $poll = normalize_job({ job => 1, action => 'discover', device => '10.0.0.1', port => '', subaction => '', log => '',
  status => 'queued', _iso_entered => 'x' });
is $poll->{port}, undef, 'normalizeJob__empty_port__null';
is $poll->{log}, undef, 'normalizeJob__empty_log__null';
is $poll->{subaction}, undef, 'normalizeJob__empty_subaction__null';

# my_jobs clamps limit before it reaches the database; a limit that is not a
# plain positive number must not be passed on
{
  package XtSchema;
  our @seen;
  sub new { bless {}, shift }
  sub resultset { shift }
  sub search { my ($self, $cond, $attrs) = @_; @seen = ($cond, $attrs); return $self }
  sub all { () }
}
foreach my $case ([undef, 25], ['', 25], ['abc', 25], ['-3', 25], ['0', 25], ['7', 7], ['100', 100], ['5000', 100]) {
  my ($in, $want) = @$case;
  my $jobs = my_jobs(XtSchema->new, 'jdoe', limit => $in);
  is_deeply $jobs, [], 'myJobs__no_rows__empty_list';
  is $XtSchema::seen[1]{rows}, $want, 'myJobs__limit_' . ($in // 'undef') . "__is_$want";
  is $XtSchema::seen[0]{'me.username'}, 'jdoe', 'myJobs__always__only_the_users_own_jobs';
}

# ---- the reasons ----

is_deeply port_reasons({ other => 'Other', address => 'Address Allocation Abuse', dos => 'Denial of Service' }),
  [ { value => 'address', label => 'Address Allocation Abuse' },
    { value => 'dos', label => 'Denial of Service' },
    { value => 'other', label => 'Other' } ],
  'portReasons__reasons__sorted_by_key_as_the_classic_modal_lists_them';
is_deeply port_reasons(undef), [], 'portReasons__none_configured__empty';
is_deeply port_reasons('not a hash'), [], 'portReasons__not_a_hash__empty';

done_testing;
