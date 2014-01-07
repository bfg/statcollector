package ACME::TC::Agent::Plugin::StatCollector::Storage::Graphite;

# check for IPv6 support...
BEGIN { eval 'require Socket6'; }
my $_has_ipv6 = (exists($INC{'Socket6.pm'}) && defined $INC{'Socket6.pm'}) ? 1 : 0;

use strict;
use warnings;

use POE;
use POE::Wheel::Run;
use POE::Wheel::SocketFactory;
use POE::Filter::Stream;
use POE::Wheel::ReadWrite;

use Log::Log4perl;
use Scalar::Util qw(blessed);

use ACME::Util;
use ACME::TC::Agent::Plugin::StatCollector::Storage;

use Socket;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Storage);

use constant DNS_RESOLVE_INT => 600;

our $VERSION = 0.01;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

my $u = ACME::Util->new();

# async DNS support
my $_adns_session = undef;

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Storage::Graphite

L<Graphite|http://graphite.wikidot.com/> storage implementation for StatCollector.

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin::StatCollector::Storage>
and the following ones:

=over

=item B<host> (string, "localhost")

Graphite server hostname or IP address.

=item B<port> (integer, 2004)

Graphite server listening port.

=back

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # public stuff
  $self->{host} = "localhost";
  $self->{port} = 2004;

  # private stuff...
  $self->{_wtcps} = undef;      # tcp socketfactory wheel
  $self->{_wconn} = undef;      # tcp connection rewrite wheel
  $self->{_queue} = [];         # storage queue...

  # exposed POE object events
  $self->registerEvent(
    qw(
      _doStore
      _resolve
      _connect
      _tcpConnOk
      _tcpConnErr
      _tcpInput
      _tcpFlushed
      _tcpError
      _queueFlush
      )
  );

  # must return 1 on success
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _run {
  my ($self) = @_;

  # check graphite server address
  unless (defined $self->{host} && length($self->{host}) > 0) {
    $self->{_error} = "Undefined Graphite server hostname.";
    return 0;
  }

  # check graphite server port
  { no warnings; $self->{port} = int($self->{port}); }
  unless ($self->{port} > 0 && $self->{port} <= 65536) {
    $self->{_error} = "Invalid Graphite server port: $self->{port}";
    return 0;
  }


  # try to resolve graphite server address if we're using tcp mode...
  $self->{_serverAddr} = $self->{host};
  $poe_kernel->yield('_resolve', 1);

  # start queue flush process
  # $poe_kernel->yield("_queueFlush", 1);

  return 1;
}

# enqueue storage...
sub _store {
  my ($self, $id, $data) = @_;
  
  # are we connected?
  unless (defined $self->{_wconn}) {
    # try to connect...
    $poe_kernel->yield('_connect');
  }

  push(@{$self->{_queue}}, { id => $id, data => $data });

  # storage request was successfully enqueued
  $self->_queueFlush();
  return 1;
}

sub _queueFlush {
  my ($self) = @_;
  unless ($self->{_wconn}) {
    $_log->warn("No connection; not flushing the queue.");
    return;
  }

  # get something to work with...
  my $e = $self->_getNextQueuedItem();
  unless (defined $e) {
    $_log->trace("Empty queue, nothing to flush.");
    return;    
  }
  
  my $bytes = $self->_marshall($e->{data});
  unless (defined $bytes) {
    $_log->warn("Error marshalling queue tail, removing element.");
    shift(@{$self->{_queue}});
    return $poe_kernel->yield('_queueFlush');
  }
  
  # ok, we have bytes and connection, let's just write to connection
  $self->{_wconn}->put($bytes);
  $_log->trace("Enqueued " . length($bytes) . " bytes to graphite connection.") if ($_log->is_trace());
  
  $poe_kernel->yield('_queueFlush');
}

sub _getNextQueuedItem {
  my ($self) = @_;
  $_log->debug("Queue contains " . ($#{$self->{_queue}} + 1) . " element(s).") if ($_log->is_debug());

  while (@{$self->{_queue}}) {
    # undefined record?
    unless (defined $self->{_queue}->[0]) {
      shift(@{$self->{_queue}});
      next;
    }
    return $self->{_queue}->[0];
  }
  
  return undef;
}

sub _storeCancel {
  my ($self, $sid) = @_;
  my $last = $#{$self->{_queue}};
  for (my $i = 0; $i <= $last; $i++) {
    next unless (defined $self->{_queue}->[$i]);
    if ($self->{_queue}->[$i]->{id} == $sid) {
      $self->{_queue}->[$i] = undef;
      return 1;
    }
  }
  return 0;
}

# shutdown!
sub _shutdown {
  my ($self) = @_;
  if (defined $self->{_wconn}) {
    # flush output
    $self->{_wconn}->flush() while ($self->{_wconn}->get_driver_out_octets());
    $self->{_wconn} = undef;
  }
  
  $self->{_wtcp} = undef;

  return 1;
}

sub _marshall {
  my ($self, $data) = @_;
  return undef unless (blessed($data) && $data->isa('ACME::TC::Agent::Plugin::StatCollector::ParsedData'));
  my $buf = '';
  
  my $host = $data->getHost();
  $host =~ s/\./_/g;

  my $ts   = int($data->getFetchDoneTime());
  
  my $dict = $data->getContent();
  foreach my $key (keys %{$dict}) {
    $buf .= $host . '.' . $key . " " . $dict->{$key} . " " . $ts . "\n";
  }
  
  return $buf;
}

sub _resolve {
  my ($self, $kernel, $do_connect) = @_[OBJECT, KERNEL, ARG0];
  my $host = $self->{host};
  if ($u->isIpv4Addr($host) || $u->isIpv6Addr($host)) {
    $_log->debug($self->getStorageSignature()
        . "Graphite server hostname '$host' looks like IP address, skipping resolving process.");
    $self->{_serverAddr} = $host;
    return 1;
  }

  my @addrs = $u->resolveHost($host);
  unless (@addrs) {
    $_log->error("Unable to resolve Graphite server address: " . $!);
    return 0;
  }


  $_log->debug($self->getStorageSignature() . "Resolved addresses for host $self->{host}: ",
    join(", ", @addrs));

  my $addr = shift(@addrs);
  $_log->debug($self->getStorageSignature() . "Assigning zabbix server $self->{host} address: $addr");

  # re-enqueue
  $_log->debug($self->getStorageSignature()
      . "Next hostname resolution will start in "
      . DNS_RESOLVE_INT
      . " seconds.");
  $kernel->delay('_resolve', DNS_RESOLVE_INT);
  
  # connect, maybe?
  if ($do_connect) {
    $_log->debug("Flag do_connect flag is on, initiating connect.");
    $kernel->yield('_connect');
  }

  return 1;
}

sub _connect {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  my $addr          = $self->{_serverAddr};
  my $port          = $self->{port};
  my $socket_domain = AF_INET;
  {
    no strict;
    no warnings;
    $socket_domain = ($_has_ipv6 && $u->isIpv6Addr($addr)) ? AF_INET6 : AF_INET;
  }

  # create tcp connection wheel
  $_log->debug($self->getStoreSig() . "Connecting to Graphite server $addr port $port.");
  my %opt = (
    Reuse         => 1,
    SocketDomain  => $socket_domain,
    RemoteAddress => $addr,
    RemotePort    => $port,
    SuccessEvent  => "_tcpConnOk",
    FailureEvent  => "_tcpConnErr",
  );

  my $wheel = POE::Wheel::SocketFactory->new(%opt);
  my $wid   = $wheel->ID();

  # save this wheel and wait for connection
  $self->{_wtcps} = $wheel;

  # wait for connection.
  return 1;
}

sub _tcpConnOk {
  my ($self, $kernel, $sock, $addr, $port, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  if ($_log->is_debug()) {
    my $remote_ip = "";
    if (length($addr) > 4) {
      $remote_ip = Socket6::inet_ntop(AF_INET6, $addr);
    }
    else {
      $remote_ip = inet_ntoa($addr);
    }
    $_log->debug($self->getStorageSignature()
        . "Connection has been successfuly established with host $remote_ip port $port.");
  }

  # create rw/wheel on socket handle...
  my %opt = (
    Handle       => $sock,
    Driver       => POE::Driver::SysRW->new(BlockSize => 1024),
    Filter       => POE::Filter::Stream->new(),
    InputEvent   => "_tcpInput",
    FlushedEvent => "_tcpFlushed",
    ErrorEvent   => "_tcpError",
  );
  if ($_log->is_trace) {
    $_log->trace($self->getStoreSig() . "Creating graphite server socket read-write wheel with options: ",
      $u->dumpVarCompact(\%opt));
  }
  my $rw     = POE::Wheel::ReadWrite->new(%opt);
  my $rw_wid = $rw->ID();
  $_log->debug($self->getStoreSig() . "Created graphite server socket read-write wheel id $rw_wid.");
  
  # save the goddamn wheel
  $self->{_wconn} = $rw;
  return 1;
}

sub _tcpConnErr {
  my ($self, $kernel, $operation, $errno, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  my $err
    = "Error $errno on graphite server connection wheel $wid "
    . "[$self->{host} port $self->{port}]: "
    . $errstr;
  $_log->error($self->getStorageSignature(), $err);

  # destroy wheels
  $self->{_wconn} = undef;
  $self->{_wtcp} = undef;
  return 1;
}

sub _tcpInput {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  if ($_log->is_trace()) {
    $_log->trace($self->getStorageSignature() . "Got ",
      length($data) . " bytes of data from graphite server socket wheel $wid: " . $data);
  }
}

sub _tcpFlushed {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  if ($_log->is_trace()) {
    $_log->trace(
      $self->getStorageSignature() . "graphite server connection read-write wheel $wid was flushed.");
  }
  
  # looks like we succeeded...
  $self->_reportStorageStatus(1);
}

sub _tcpError {
  my ($self, $kernel, $operation, $errno, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  # errno == 0; this is usually EOF...
  if ($errno == 0) {
    $self->_reportStorageStatus(1, undef);
    # destroy wheel
    $self->{_wconn} = undef;
  }
  else {
    $self->_reportStorageStatus(
      0,
      "Error $errno accoured while performing operation $operation on graphite server socket wheel $wid: $errstr"
    );
  }  
}

sub _reportStorageStatus {
  my ($self, $ok, $err) = @_;
  my $e = shift(@{$self->{_queue}});
  
  if ($ok) {
    $poe_kernel->yield(STORE_OK, $e->{id}, "ok");
  } else {
    $poe_kernel->yield(STORE_ERR, $e->{id}, $err);
  }
  
  $poe_kernel->yield('_queueFlush');
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::ParsedData>
L<ACME::TC::Agent::Plugin::StatCollector::Storage>
L<ACME::TC::Agent::Plugin::StatCollector>
L<POE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF