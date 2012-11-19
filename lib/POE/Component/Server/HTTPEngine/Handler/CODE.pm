package POE::Component::Server::HTTPEngine::Handler::CODE;


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

our $VERSION = 0.04;

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

  # exposed POE object events
  push(
    @{$self->{_exposed_events}}, qw(
      __streamHandler
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
  return "CODE reference execution URL handler module...";
}

sub clearParams {
  my ($self) = @_;
  $self->SUPER::clearParams(@_);

  $self->{handler}        = \&__handler_url;
  $self->{handler_stream} = \&__handler_stream;
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # check coderef...
  unless (defined $self->{handler} && ref($self->{handler}) eq 'CODE') {
    $response->setError($request->uri()->path(),
      HTTP_INTERNAL_SERVER_ERROR, "Undefined or invalid URL CODE ref handler.");
    return $self->requestFinish($response);
  }

  # run it - safely...
  my $r = undef;
  eval { $self->{handler}($request, $response); };

  # check for injuries...
  if ($@) {
    $response->setError($request->uri()->path(),
      HTTP_INTERNAL_SERVER_ERROR,
      "Handler <b>" . ref($self) . "</b> caught exception while running CODE-ref handler:<br>\n$@");
    return $self->requestFinish();
  }

  # if our response is not in streaming mode
  # we should just finish the request...
  unless ($response->streaming()) {
    return $self->requestFinish();
  }

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub __streamHandler {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # try to run stream handler...
  $_log->debug("Running stream handler!") if (DEBUG);

  unless (defined $self->{handler_stream} && ref($self->{handler_stream}) eq 'CODE') {
    $self->{_response}->setError($self->{_request}->uri()->path(),
      HTTP_INTERNAL_SERVER_ERROR, 'Invalid stream handler CODE reference.');
    return $self->requestFinish();
  }

  # run it - safely...
  my $r = undef;
  eval { $self->{handler_stream}($self->{_request}, $self->{_response}); };

  # check for injuries...
  if ($@) {
    $self->{_response}->setError($self->{_request}->uri()->path(),
      HTTP_INTERNAL_SERVER_ERROR,
      "Handler <b>" . ref($self) . "</b> caught exception while running CODE-ref stream handler:<br>\n$@");
    return $self->requestFinish();
  }
}

sub __handler_url {
  my ($request, $response) = @_;
  die "<b>Dude, you should specify 'handler' property with your super-duper url handler coderef.</b>";
}

sub __handler_stream {
  die "<b>Dude, you should specify 'handler_stream' property with your super-duper url handler coderef.</b>";
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
