package POE::Component::Server::HTTPEngine::Handler::Rand;


use strict;
use warnings;

use POE;
use bytes;
use HTTP::Status qw(:constants);
use POE::Component::Server::HTTPEngine::Handler;

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

use vars qw(@ISA);
@ISA = qw(POE::Component::Server::HTTPEngine::Handler);

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
      _streamData
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
  return "Dummy nothing-to-do module.";
}

sub random_str {
  my $len = 10 + int(rand() * 30);
  my $s   = "";

  for (my $i = 0; $i < $len; $i++) {
    $s .= chr(65 + int(rand() * 25));
  }

  return $s;
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];
  my $streamed = 1;
  my $chunked  = 1;
  my $x        = $request->uri()->query_param("streamed");
  $streamed = int($x) if (defined $x);
  $x        = $request->uri()->query_param("chunked");
  $chunked  = int($x) if (defined $x);
  $chunked  = 0 unless ($streamed);
  $x        = $request->uri()->query_param("size");
  my $set_size = int($x) if (defined $x);

  if ($request->uri()->query_param("dumb")) {
    $response->code(200);
    $response->header('Content-Type', 'text/plain');
    $response->content('Congratulations, your Mojo is working!');
    return $self->requestFinish();
  }

  # we'll put data here...
  @{$self->{_chunks}} = ();

  # prepare the data...
  my $num_chunks = int(rand() * 30);
  my $size       = 0;

  # some header...
  my $str = "BEGIN FROM " . $response->remote_ip() . ":" . $response->remote_port() . " : $num_chunks\n\n";
  $str .= "This handler accepts the following URL query parameters:\n\n";
  $str .= "	streamed={0|1}	:: enable/disable output streaming\n";
  $str .= "	chunked={0|1}	:: enable/disable of chunked Content-Encoding\n";
  $str .= "	dumb=1		:: spit out the dumb output\n";
  $str .= "\nRESPONSE IS STREAMED: " . (($streamed) ? "YES" : "NO") . "\n";
  $str .= "RESPONSE IS CHUNKED:  " . (($chunked) ? "YES" : "NO") . "\n";
  $str .= "SERVER RUNNING IN DEBUG MODE: " . (($self->getServer()->isDebug()) ? "YES" : "NO") . "\n";
  $str
    .= "Currently serving: "
    . $self->getServer->getNumClients() . " of "
    . $self->getServer()->getMaxClients()
    . " total allowed clients.\n\n";
  $size += length($str);

  push(@{$self->{_chunks}}, $str);
  for (my $i = 0; $i < $num_chunks; $i++) {
    my $s = sprintf("\t%-3.3s: %s\n", ($i + 1), random_str());
    $size += length($s);
    push(@{$self->{_chunks}}, $s);
  }

  # FOOTER
  $str = "\nEND";
  $size += length($str);
  push(@{$self->{_chunks}}, $str);

  # set the header...
  $response->code(HTTP_OK);
  $response->header("Content-Type", "text/plain");

  if ($set_size) {
    $response->header("Content-Length", $size);
  }

  # print STDERR "SIZE: $size vs " . length(join("", @{$self->{_chunks}})) . "\n";

  # start the streaming of data...
  if ($streamed) {
    $kernel->yield("_streamData");
  }
  else {
    $response->content(join("", @{$self->{_chunks}}));
    $self->requestFinish();
  }

  return 1;
}

sub shutdown {
  my ($self) = shift;
  $self->SUPER::shutdown();
  @{$self->{_chunks}} = ();
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _streamData {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  unless (@{$self->{_chunks}}) {
    return $self->requestFinish();
  }

  my $chunk = shift(@{$self->{_chunks}});
  use bytes;
  $_log->debug("    Sending ", length($chunk), " bytes.") if (DEBUG);
  $self->streamSend($chunk);

  $kernel->yield("_streamData");
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
