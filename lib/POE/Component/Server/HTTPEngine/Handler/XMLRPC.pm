package POE::Component::Server::HTTPEngine::Handler::XMLRPC;


use strict;
use warnings;

use POE;
use XML::RPC;
use HTTP::Status qw(:constants);
use POE::Component::Server::HTTPEngine::Handler;

use vars qw(@ISA);
@ISA = qw(POE::Component::Server::HTTPEngine::Handler);

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

our $VERSION = 0.01;

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
      )
  );

  # logging object
  if (DEBUG && !defined $_log) {
    $_log = Log::Log4perl->get_logger(__PACKAGE__);
  }

  # list of published methods
  $self->{_methods} = {};

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);
  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

sub getDescription {
  return "XML-RPC module";
}


sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # xml rpc accepts only post http method
  my $method = lc($request->method());
  if ($method ne 'post') {
    $response->setError($request->uri()->path(),
      HTTP_SERVICE_UNAVAILABLE, "XML-RPC requests must use POST HTTP method.");
    return $self->requestFinish();
  }

  # create xml rpc parsing object...
  $_log->debug("Creating xml parser object.") if (DEBUG);
  my $xmlrpc = XML::RPC->new();

  # parse and process xml request...
  $_log->debug("Processing xml rpc request.") if (DEBUG);
  my $result = $xmlrpc->receive(
    $request->content(),
    sub {
      $self->_requestDispatch(@_);
    }
  );

  # check for injuries
  unless (defined $result) {
    $response->content_type("text/xml");
    $response->code(HTTP_SERVICE_UNAVAILABLE);
    return $self->requestFinish();
  }

  # finish it...
  $response->content_type("text/xml");
  $response->code(HTTP_OK);
  $response->content($result);

  if (DEBUG) {
    if ($_log->is_debug()) {
      $_log->debug("XML OUT: ", $result);
    }
  }

  return $self->requestFinish();
}

sub _requestDispatch {
  my ($self, $func, @params) = @_;
  $_log->debug("Will invoke method '$func'") if (DEBUG);

  # system.XXX method?
  if ($func =~ m/^system\.(.+)/) {
    if ($1 eq 'listMethods') {
      return $self->_system_listMethods(@params);
    }
    elsif ($1 eq 'methodHelp') {
      return $self->_system_methodHelp(@params);
    }
    elsif ($1 eq 'methodSignature') {
      return $self->_system_methodSignature(@params);
    }
    else {
      die "Invalid system method name.\n";
    }
  }

  # do we have this method?
  unless (exists($self->{_methods}->{$func})) {
    die "Invalid method name.\n";
  }

  # check handler...
  my $handler = $self->{_methods}->{$func};

  # coderef handler?
  if (ref($handler) eq 'CODE') {
    $_log->debug("Method handler is CODEref.");
    return &{$handler}(@params);
  }

  # poe session handler?
  elsif ($handler =~ m/^([^:]+):(.+)/) {
    my $session = $1;
    my $event   = $2;
    $_log->debug("Method handler is POE session $session:$event");

    return $poe_kernel->call($session, $event);
  }
}

##################################################
#               PRIVATE METHODS                  #
##################################################


sub _system_listMethods {
  my ($self) = @_;
  return sort keys %{$self->{_methods}};
}

sub _system_methodHelp {
  my ($self, $name) = @_;
  return "Method help is not available for method: $name";
}

sub _system_methodSignature {
  my ($self) = @_;
  return ();
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
