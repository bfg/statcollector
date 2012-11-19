package POE::Component::Server::HTTPEngine::Handler::ServerInfo;


use strict;
use warnings;

use POE;
use POE::Component::Server::HTTPEngine::Handler;

use vars qw(@ISA);
@ISA = qw(POE::Component::Server::HTTPEngine::Handler);

our $VERSION = 0.01;

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = $class->SUPER::new(@_);

  ##################################################
  #              PUBLIC PROPERTIES                 #
  ##################################################

  ##################################################
  #              PRIVATE PROPERTIES                #
  ##################################################

  # exposed POE object events
  # @{$self->{_exposed_events}} = qw();

  bless($self, $class);

  # $self->clearParams();
  # $self->setParams(@_);
  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

sub getDescription {
  return "Server information module...";
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];

}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO
L<HTTP::Request>
L<HTTP::Response>
L<POE::Component::Server::HTTPEngine::Handler>
L<POE::Component::Server::HTTPEngine::Response>

=cut

1;
