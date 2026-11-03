package App::Netdisco::Web::Plugin::UI::Compact;

use Dancer ':syntax';
use Path::Class 'file';

use App::Netdisco::Web::Plugin;
use App::Netdisco::Web::UI 'current_web_ui';

=head1 NAME

App::Netdisco::Web::Plugin::UI::Compact - the compact web interface

=head1 DESCRIPTION

A web interface (see L<App::Netdisco::Web::UI>), named C<compact>: the classic
pages, denser. It is templates and a style sheet only, F<share/views-compact>
and F<share/public/compact>, and it is not in the shipped C<web_uis>:

    web_uis: [ modern, compact ]

turns it on. It is what a second interface looks like to the support for
several: it brings no route and no data, and every page it does not redraw,
which is all of them, is the classic one.

This web plugin, which C<web_uis> loads for the name C<compact>, says what the
classic menu reads for the switch to it, and tells the layout which layout it
wraps.

=cut

register_web_ui({
  name         => 'compact',
  short_label  => 'Compact UI',
  switch_title => 'Switch this browser to the compact interface',
});

# The layout of this interface is F<layouts/main.tt> in F<views-compact>, so
# the name cannot be looked up for the layout it wraps. That is the first one in
# the engine's template path that is not the interface's own, so that a site's
# layout in template_paths is the one wrapped.
my $base_layout;
sub base_layout {
  return $base_layout if defined $base_layout;

  foreach my $dir (grep { not ref } @{ config->{engines}->{netdisco_template_toolkit}->{INCLUDE_PATH} || [] }) {
    my $candidate = file($dir, 'layouts', 'main.tt');
    return $base_layout = $candidate->stringify if -f $candidate;
  }
  return undef;
}

hook 'before_template' => sub {
  my $tokens = shift;
  return unless current_web_ui() eq 'compact';
  $tokens->{compact_base_layout} = base_layout();
};

true;
