package App::Netdisco::Web::UI::Modern::Home;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;

use App::Netdisco::Web::UI 'current_web_ui';
use App::Netdisco::Web::UI::Modern::Shell 'page_segments';
use App::Netdisco::Web::Data::Summary 'network_summary';

=head1 NAME

App::Netdisco::Web::UI::Modern::Home - the home page, in the modern interface

=head1 DESCRIPTION

The home page is the classic route's (C</>, in App::Netdisco::Web::AuthN),
and so is everything it offers: signing in, the search, the admin's discover
form, the System Information panel. The modern interface's F<index.tt> adds
the network at a glance, which this hands it as C<nd2_home>: the same figures
as C<GET /ajax/data/v2/summary>, and which of the reports they point to are there
(a site may leave any out of C<web_plugins>).

=cut

# the reports the figures link to, by what they are for (no report lists the
# error disabled ports, so that figure links nowhere)
my %REPORT_FOR = (half_duplex => 'halfduplex', admin_down => 'portadmindown', blocking => 'portblocking');

hook 'before_template' => sub {
  my $tokens = shift;
  return unless current_web_ui() eq 'modern' and session('logged_in_user');
  return if request->is_ajax or vars->{'notfound'};
  return if scalar page_segments(request->path, setting('path'));

  my $reports = setting('_reports') || {};
  $tokens->{nd2_home} = {
    %{ network_summary(schema(vars->{'tenant'})) },
    reports => { map {( $_ => ($reports->{ $REPORT_FOR{$_} } ? $REPORT_FOR{$_} : undef) )} keys %REPORT_FOR },
  };
};

true;
