package POE::Component::Server::HTTPEngine::Handler::Dummy;


use strict;
use warnings;

use POE;
use HTTP::Status qw(:constants);
use POE::Component::Server::HTTPEngine::Handler;

# inherit everything from base class
use base 'POE::Component::Server::HTTPEngine::Handler';

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

our $VERSION = 0.02;

my $_log = undef;

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

  # additional POE session exposed events;
  # add method names you want to be accessible as
  # POE events
  push(
    @{$self->{_exposed_events}}, qw(
      finishThisDummyRequest
      )
  );

  # logging object
  if (DEBUG && !defined $_log) {
    $_log = Log::Log4perl->get_logger(__PACKAGE__);
  }

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);
  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

sub getDescription {
  return "Dummy nothing-to-do module...";
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];

  $response->code(HTTP_OK);
  $response->header("Content-Type", "text/plain");

  #$response->add_content("Some content: " . rand() . "\n");
  #$response->add_content("Some more content: " . rand() . "\n");

  $kernel->yield("finishThisDummyRequest");

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub finishThisDummyRequest {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  my $server   = $self->getServer();
  my $response = $self->getResponse();

  my $num_clients = $server->getNumClients();
  my $max_clients = $server->getMaxClients();

  $response->add_content("Currently processing $num_clients of $max_clients total allowed connection(s).\n");
  $response->add_content("\nThis is final handler on " . $server->getServerString() . "\n");

  # let's add some delay (just for fun)...
  #if (rand() > 0.5) {
  #	$kernel->delay("non_existent_event", rand());
  #}
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO
L<HTTP::Request>
L<HTTP::Response>
L<POE::Component::Server::HTTPEngine::Handler>
L<POE::Component::Server::HTTPEngine::Response>

=cut

1;
