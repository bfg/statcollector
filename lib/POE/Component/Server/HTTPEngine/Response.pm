package POE::Component::Server::HTTPEngine::Response;


use strict;
use warnings;

use POE;
use HTTP::Response;
use HTTP::Status qw(:constants);

use vars qw(@ISA);
@ISA = qw(HTTP::Response);

use constant STREAM_SIMPLEHTTP => 1;
use constant STREAM_HTTP       => 2;

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;

  my $wheel_id = shift;
  unless (defined $wheel_id) {
    die "Usage: my \$response = POE::Component::Server::HTTPEngine::Response->new(\$connection_wheel_id);";
  }

  my $self = $class->SUPER::new(@_);

  $self->{_wheel}             = $wheel_id;    # client's wheel id
  $self->{_obj}               = undef;        # httpengine object
  $self->{_bytes_total}       = 0;            # total bytes of content-body...
  $self->{_vhost}             = "";           # virtualhost name
  $self->{_streaming}         = 0;            # we're in streaming mode...
  $self->{_streaming_session} = undef;
  $self->{_streaming_event}   = undef;

  # connection stuff...
  $self->{_conn_ssl_cipher} = "";
  $self->{_conn_ssl}        = 0;
  $self->{_conn_remote_ip}  = "";
  $self->{_conn_ssl_port}   = 0;

  # path_info
  $self->{_path_info} = undef;

  bless($self, $class);
  return $self;
}


sub wheel {
  my ($self, $val) = @_;
  return $self->{_wheel} unless (defined $val);
  $self->{_wheel} = $val;
  return $val;
}

sub _wheel {
  return wheel(@_);
}

=item streaming ([1])

POE::Component::Server::HTTP compatibility method. 

=cut

sub streaming {
  my ($self, $val) = @_;
  return $self->{_streaming} unless (defined $val);

  # once streaming has been started it cannot be stopped...
  if ($self->{_streaming} && !$val) {
    die "Streaming was already started; this behaviour cannot be changed during the life of response object.";
  }
  return 0 unless ($val);

  $self->{_streaming}      = $val;
  $self->{_streaming_type} = STREAM_HTTP;

  # TODO: this client should enter the streaming mode...
  print "Sending: '$self->{_srv_poe_id}':STREAM\n";
  return $poe_kernel->post($self->{_srv_poe_id}, $self->{_srv_ev_stream}, $self, 1,);

  return $val;
}

=item stream (session => $session, event => $event, [ dont_flush => 1])

POE::Component::Server::SimpleHTTP compatibility method. 

=cut

sub stream {
  my ($self, %opt) = @_;
  $opt{dont_flush} = 0 unless (exists($opt{dont_flush}));
  $opt{dont_flush} = int($opt{dont_flush});

  # check if we already started streaming...
  if ($self->{_streaming}) {
    die "Streaming was already started.";
  }
  $self->{_streaming}          = 1;
  $self->{_streaming_type}     = STREAM_SIMPLEHTTP;
  $self->{_streaming_session}  = $opt{session};
  $self->{_streaming_event}    = $opt{event};
  $self->{_streaming_callback} = (!$opt{dont_flush});

  return 1;
}

sub _callback {
  my $self = shift;
  return $self->{_streaming_callback};
}

sub _callbackSession {
  my $self = shift;
  return $self->{_streaming_session};
}

sub _callbackEvent {
  my $self = shift;
  return $self->{_streaming_event};
}

sub _callbackStreamTypeIsSimpleHTTP {
  my $self = shift;
  if ($self->{_streaming_type} == STREAM_SIMPLEHTTP) {
    return 1;
  }

  return 0;
}

=item send ($data)

POE::Component::Server::HTTP compatibility method. 

=cut

sub send {
  my ($self, $data) = @_;
  unless ($self->{_streaming}) {
    die "Streaming was not started.";
  }

  # data, data, data... :)
  $self->content($data) if (defined $data);

  # enqueue sending...
  print "Sending: '$self->{_srv_poe_id}':STREAM\n";
  return $poe_kernel->post($self->{_srv_poe_id}, $self->{_srv_ev_stream}, $self, 1,);
}

=item continue ()

POE::Component::Server::HTTP compatibility method. 

=cut

sub continue {
  die "continue() is not implemented yet.";
}

=item close ()

POE::Component::Server::HTTP compatibility method. 

=cut

sub close {
  my ($self) = @_;

  # well, stream has been closed just call the server to end up our request...
  #$self->content("");
  return $poe_kernel->post($self->{_srv_poe_id}, $self->{_srv_ev_done}, $self);
}

sub getServerPoeId {
  my ($self) = @_;
  return $self->{_srv_poe_id};
}

sub getServerEventDONE {
  my ($self) = @_;
  return $self->{_srv_ev_done};
}

sub getServerEventCLOSE {
  my ($self) = @_;
  return $self->{_srv_ev_close};
}

sub getServerEventSTREAM {
  my ($self) = @_;
  return $self->{_srv_ev_stream};
}

sub getServer {
  my ($self) = @_;
  return $self->{_srv};
}

sub setServer {
  my ($self, $obj) = @_;

  if (defined $obj) {
    $self->{_srv}           = $obj;
    $self->{_srv_poe_id}    = $obj->getSessionId();
    $self->{_srv_ev_done}   = $obj->getEventDONE();
    $self->{_srv_ev_stream} = $obj->getEventSTREAM();
    $self->{_srv_ev_close}  = $obj->getEventCLOSE();

    return 1;
  }

  return 0;
}

sub setError {
  my ($self, $uri, $code, $message) = @_;
  $uri     = "<undefined_uri>"          unless (defined $uri);
  $code    = HTTP_INTERNAL_SERVER_ERROR unless (defined $code);
  $message = ""                         unless (defined $message);

  $self->code($code);
  $self->header("Content-Type", "text/html");
  $self->content($self->getServer()->getHTTPErrorString($uri, $code, $message));

  return 1;
}

sub pathInfo {
  my ($self, $val) = @_;
  return $self->{_path_info} unless (defined $val);
  $self->{_path_info} = $val;
}

sub connection {
  my $self = shift;
  return $self;
}

sub remote_ip {
  my ($self, $val) = @_;
  return $self->{_conn_remote_ip} unless (defined $val);
  $self->{_conn_remote_ip} = $val;
}

sub remote_port {
  my ($self, $val) = @_;
  return $self->{_conn_remote_port} unless (defined $val);
  $self->{_conn_remote_port} = $val;
}

sub ssl {
  my ($self, $val) = @_;
  return $self->{_conn_ssl} unless (defined $val);
  $self->{_conn_ssl} = $val;
}

sub sslcipher {
  my ($self, $val) = @_;
  return $self->{_conn_ssl_cipher} unless (defined $val);
  $self->{_conn_ssl_cipher} = $val;
}

sub ssl_cipher {
  my $self = shift;
  return $self->sslcipher(@_);
}

# todo: rename
sub getBytes {
  my $self = shift;
  return $self->{_bytes_total};
}

sub addBytes {
  my ($self, $val) = @_;
  return 0 unless (defined $val);
  no warnings;
  $self->{_bytes_total} += int($val);
  return 1;
}

sub vhost {
  my ($self, $val) = @_;
  return $self->{_vhost} unless (defined $val);
  $self->{_vhost} = $val;
  return $val;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<HTTP::Request>
L<HTTP::Response>

=cut

1;
