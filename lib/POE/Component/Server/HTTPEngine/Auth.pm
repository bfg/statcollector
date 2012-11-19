package POE::Component::Server::HTTPEngine::Auth;


use strict;
use warnings;

use POE;

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

# logging object
my $_log = undef;

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  ##################################################
  #              PUBLIC PROPERTIES                 #
  ##################################################

  ##################################################
  #              PRIVATE PROPERTIES                #
  ##################################################

  $self->{_error} = "";

  # logging object
  if (DEBUG && !defined $_log) {
    $_log = Log::Log4perl->get_logger(__PACKAGE__);
  }

  # bless ourselves...
  bless($self, $class);
  return $self;
}

sub DESTROY {
  my $self = shift;
  if (DEBUG) {
    $_log->debug("Destroying: $self") if (defined $_log);
  }
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO
L<POE::Component::Server::HTTPEngine>

=cut

1;
