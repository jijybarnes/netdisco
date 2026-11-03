package Dancer::Template::NetdiscoTemplateToolkit;

use strict;
use warnings;

use Dancer::FileUtils 'path';
use base 'Dancer::Template::TemplateToolkit';

# INCLUDE_PATH may hold a code ref returning more directories (the web
# interface overlay, see App::Netdisco::Web::UI). Template Toolkit expands
# those itself for INCLUDE and PROCESS; this does the same for the top-level
# view, which Dancer resolves before Template Toolkit sees it.
sub _search_paths {
    my $self = shift;
    return map { ref $_ eq 'CODE' ? @{ $_->() || [] } : $_ }
           @{ $self->config->{INCLUDE_PATH} };
}

sub view {
    my ($self, $view) = @_;

    foreach my $path ($self->_search_paths) {
        foreach my $template ($self->_template_name($view)) {
            my $view_path = path($path, $template);
            return $view_path if -f $view_path;
        }
    }

    # No matching view path was found
    return;
}

# Dancer looks for a layout only under the views setting, so a site's
# template_paths and a plugin's views could override every template but the
# layouts. They are searched here, in the order of INCLUDE_PATH: the web
# interface's own first, so that it can bring its layout, then the site's.
sub layout {
    my ($self, $layout, $tokens, $content) = @_;

    foreach my $dir ($self->_search_paths) {
        foreach my $name ($self->_template_name($layout)) {
            my $layout_path = path($dir, 'layouts', $name);
            return $self->render($layout_path, {%$tokens, content => $content})
              if -f $layout_path;
        }
    }

    return $self->SUPER::layout($layout, $tokens, $content);
}

1;
