package POE::Component::Server::HTTPEngine::Handler::POESession;


use strict;
use warnings;

use POE;
use HTTP::Status qw(:constants);
use POE::Component::Server::HTTPEngine::Handler;

use base 'POE::Component::Server::HTTPEngine::Handler';

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

our $VERSION = 0.05;

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
  push(@{$self->{_exposed_events}}, qw());

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

sub clearParams {
  my $self = shift;
  $self->SUPER::clearParams();
  $self->{session} = undef;
  $self->{event}   = undef;

  # never...
  $self->{_check_done} = 0;
}

sub getDescription {
  return "This request handler passes requests to other POE sessions";
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # check if we have everything we need...
  unless (defined $self->{session} && defined $self->{event}) {
    $response->setError($request->uri()->path(),
      HTTP_INTERNAL_SERVER_ERROR, "Invalid/undefined receiving POE session name and/or event");
    $self->requestFinish();
  }

  if (DEBUG) {
    $_log->debug("Sending HTTP request/response to session '$self->{session}', event '$self->{event}'.");
  }

  # post to another session
  my $r = $kernel->post($self->{session}, $self->{event}, $request, $response);

  # check for injuries...
  unless ($r) {

    # $self->logError("Error posting to session '$self->{session}', event '$self->{event}': $!");
    $response->setError($request->uri()->path(),
      HTTP_INTERNAL_SERVER_ERROR, "Error posting to session '$self->{session}', event '$self->{event}': $!");
    $self->requestFinish();
  }
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
