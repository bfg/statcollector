package ACME::TC::Agent::Plugin::StatCollector::Source::_Socket;


use strict;
use warnings;

# check for IPv6 support...
BEGIN { eval 'require Socket6'; }
my $_has_ipv6 = (exists($INC{'Socket6.pm'}) && defined $INC{'Socket6.pm'}) ? 1 : 0;

# try to load SSL support
my $_has_ssl = 0;
eval {
  require POE::Component::SSLify;
  POE::Component::SSLify->import(qw(Client_SSLify SSLify_GetCipher));
  $_has_ssl = 1;
};

# async DNS resolver session
my $_adns_session = undef;

use Socket;
use Log::Log4perl;
use List::Util qw(shuffle);

use POE;
use POE::Filter::Line;
use POE::Filter::Stream;
use POE::Wheel::ReadWrite;
use POE::Wheel::SocketFactory;

use ACME::Util;
use ACME::Util::PoeSession;
use ACME::TC::Agent::Plugin::StatCollector::Source;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Source);

our $VERSION = 0.05;
my $util = ACME::Util->new();

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Source::_Socket

Abstract TCP/IP statistics source.

=head1 DESCRIPTION

This module is meant as foundation for building source modules that use TCP/IP
connection to fetch statistics data.

B<Features:>

=over

=item Transparent connect failover

If hostname resolves to multiple IP addresses connect routine will try
to connect to all addresses until succesfull connection is made.

=item Transparent IPv6 support

This module can transparently handle IPv4 or IPv6 connections. Requires
perl module L<Socket6>.

=item SSL support

This module includes transparent support for SSL connections. Requires
L<POE::Component::SSLify> perl module.

=item Async DNS resolving

Hostname resolution can block entire process if DNS server is slow or unreachable.
This can be very problematic, becouse one can't afford blocking in single-threaded
process. Async DNS support requires perl module L<Net::DNS>.

Turn on async dns support if you have SLOW or SLUGGISH dns server. It's best to
set up caching nameserver on machine running stat-collector.

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts all named parameters supported by 
L<ACME::TC::Agent::Plugin::StatCollector::Source> plus the
following ones:

=over

=item B<useSSL> (boolean, 0):

Try to establish SSL secured connection. Requires L<POE::Component::SSLify>
perl module.

=item B<preferIpv6> (boolean, 1)

Prefer IPv6 connections over IPv4...

=item B<hostCacheTtl> (integer, 3600)

Store resolved hostname IP addresses in cache for specified amount of seconds. If set to 0,
host IP adress caching functionality is disabled.

=item B<failover> (boolean, 1)

Try to connect to all IP addresses until successful connection is made. Requires working
async dns resolver.

=item B<shuffleAddr> (boolean, 1)

Shuffle list of resolved IP addresses if more than one are found. Requires working
async dns resolver.

=item B<useAsyncDNS> (boolean, 0)

Resolve hosts asynchronously - use if you have slow DNS server. If you want
fast DNS resolving you should probably set up your own caching nameserver on the host
you're running statcollector.

=back

=head1 METHODS

Methods marked with B<[POE]> can be invoked as POE events.

=head2 clearParams ()

Resets object configuration. Returns 1 on success, otherwise 0.

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # public stuff...
  $self->{useSSL}       = 0;
  $self->{preferIpv6}   = 1;
  $self->{hostCacheTtl} = 3600;
  $self->{failover}     = 1;
  $self->{useAsyncDNS}  = 0;
  $self->{shuffleAddr}  = 1;

  # private stuff...

  # list of connection ip addresses...
  $self->{__addrs} = [];

  # dns cache
  $self->{__hostCache} = {};

  # wheels...
  $self->{__sf} = undef;    # POE::Wheel::SocketFactory object...
  $self->{__rw} = undef;    # POE::Wheel::ReadWrite object...

  # exposed POE object events
  $self->registerEvent(
    qw(
      __connOk
      __connErr
      connect
      resolveConnect
      realConnect
      disconnect
      rwInput
      rwFlushed
      rwError
      _resolveHandler
      sendData
      hostCachePurge
      )
  );

  # must return 1 on success
  return 1;
}

=head2 getConnectedHost ()

Returns hostname of connected peer host if object is currently connected, otherwise undef.

=cut

sub getConnectedHost {
  my ($self, $f) = @_;
  $f = 0 unless (defined $f);
  unless ($f) {
    return undef unless ($self->isConnected());
  }
  return $self->{__connHost};
}

=head2 getConnectedAddr ()

Returns IP address of connected peer host if object is currently connected, otherwise undef.

=cut

sub getConnectedAddr {
  my ($self, $f) = @_;
  $f = 0 unless (defined $f);
  unless ($f) {
    return undef unless ($self->isConnected());
  }
  return $self->{__connAddr};
}

=head2 getConnectedPort ()

Returns remote port number of connected peer host if object is currently connected, otherwise undef.

=cut

sub getConnectedPort {
  my ($self, $f) = @_;
  $f = 0 unless (defined $f);
  unless ($f) {
    return undef unless ($self->isConnected());
  }
  return $self->{__connPort};
}

=head2 isConnected ()

Returns 1 if object is connected to remote peer host, otherwise 0.

=cut

sub isConnected {
  my ($self) = @_;
  unless (defined $self->{__sf} && defined $self->{__rw}) {
    $self->{_error} = "Not connected.";
  }

  return 1;
}

=head2 getWheel ()

Returns L<POE::Wheel::ReadWrite> wheel object associated with connected socket on success,
otherwise undef.

=cut

sub getWheel {
  my ($self) = @_;
  return undef unless ($self->isConnected());
  return $self->{__rw};
}

=head2 hostCacheGet ($hostname)

Returns list of cached IP addresses for host $hostname.

=cut

sub hostCacheGet {
  my ($self, $hostname) = @_;
  return [] unless (defined $hostname);
  return [] unless (exists($self->{__hostCache}->{$hostname}));

  # i've got something in cache for ya!
  $_log->debug("Returning $hostname from host cache: ", join(", ", @{$self->{__hostCache}->{$hostname}}));

  # we have it in cache, but there are no ips...
  return unless (@{$self->{__hostCache}->{$hostname}});

  #return @{$self->{__hostCache}->{$hostname}};
  return $self->{__hostCache}->{$hostname};
}

=head2 hostCachePut ($hostname, $ip, $ip2, ...)

Add specified list of IP addresses to host cache for host $hostname.
Entry will dissappear from cache after B<hostCacheTtl> seconds.

Returns 1 on success, otherwise 0.

=cut

sub hostCachePut {
  my ($self, $hostname, @addrs) = @_;

  # no cache for us?
  return 0 unless ($self->{hostCacheTtl} > 0);

  # check arguments...
  return 0 unless (defined $hostname);

  #return 0 unless (@addrs);

  $_log->debug("Adding $hostname to host cache for $self->{hostCacheTtl} seconds: ", join(", ", @addrs));

  # put in cache
  $self->{__hostCache}->{$hostname} = [@addrs];

  # set up removal alarm...
  $poe_kernel->alarm_add('hostCachePurge', (time() + $self->{hostCacheTtl}), $hostname);

  # return success...
  return 1;
}

=head2 hostCachePurge ($hostname) [POE]

Removes $hostname from list of cached hosts.

=cut

sub hostCachePurge {
  my ($self, $hostname);
  if (is_poe(\@_)) {
    ($self, $hostname) = @_[OBJECT, ARG0];
  }
  else {
    ($self, $hostname) = @_;
  }

  return 0 unless (defined $hostname);
  if (exists($self->{__hostCache}->{$hostname})) {
    $_log->debug("Purging hostname cache for host: $hostname");
    delete($self->{__hostCache}->{$hostname});
  }

  return 1;
}

=head2 hostCachePurgeAll ()

Empties whole host cache.

=cut

sub hostCachePurgeAll {
  my $self = shift;
  $_log->debug("Purging whole hostname cache.");
  $self->{__hostCache} = {};
  return 1;
}

=head2 sendData ($data) [POE only]

Sends data to remote endpoint.

=cut

sub sendData {
  my ($self, $data) = (undef, undef);
  if (is_poe(\@_)) {
    ($self, $data) = @_[OBJECT, ARG0];
  }
  else {
    ($self, $data) = @_;
  }

  #my ($self, $kernel, $data) = @_[OBJECT, KERNEL, ARG0];

  unless ($self->isConnected()) {
    $_log->error($self->getFetchSignature(), " " . $self->getError());

    # Unable to send data: not connected.");
    return 0;
  }

  if ($_log->is_trace()) {
    $_log->trace($self->getFetchSignature(), " Sending data:\n$data");
  }

  # no actually enqueue data for sending.
  $self->{__rw}->put($data);
  return 1;
}

=head2 connect ($hostname, $port) [POE only]

Enqueues connect to $hostname port $port. $hostname can be hostname or ipv6/v4 address.

Returns socketfactory id on success, otherwise 0.

=cut

sub connect {
  my ($self, $kernel, $hostname, $port) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # check hostname
  unless (defined $hostname) {
    $_log->error($self->getFetchSignature() . " Cannot connect to undefined hostname.");
    return 0;
  }

  # strip spaces
  $hostname =~ s/\s+//g;
  unless (length($hostname) > 0) {
    $_log->error($self->getFetchSignature() . " Zero-length hostname.");
    return 0;
  }

  # check port...
  { no warnings; $port = int($port); }
  unless ($port > 0 && $port < 65536) {
    $_log->error($self->getFetchSignature() . " Invalid port number: $port");
    return 0;
  }

  # check for async DNS
  if ($self->{useAsyncDNS}) {
    $self->_initAsyncDNS();
  }

  # if $hostname is ip address, just enqueue the real connect...
  if ($util->isIpv4Addr($hostname) || $util->isIpv6Addr($hostname)) {
    $kernel->yield('realConnect', $hostname, $port);
  }
  else {

    # sheez... we'll need to resolve this one...
    $kernel->yield('resolveConnect', $hostname, $port);
  }

}

sub resolveConnect {
  my ($self, $kernel, $hostname, $port) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # remember hostname && port
  $self->{__connHost} = $hostname;
  $self->{__connPort} = $port;

  # is there anything in host cache?
  my $addrs = $self->hostCacheGet($hostname);
  unless (defined $addrs) {
    $kernel->yield(FETCH_ERR, "Unresolvable host [cache]: $hostname");
    return 0;
  }
  if (@{$addrs}) {

    # skip resolving process, perform connect immediately.
    return $self->_connectResolved(@{$addrs});
  }

  # no async resolver?
  unless (defined $_adns_session) {

    # try to resolve hostname in a blocking way...
    @{$addrs} = $util->resolveHost($hostname);

    # nothing resolved?
    unless (@{$addrs}) {
      $self->hostCachePut($hostname);
      $kernel->yield(FETCH_ERR, "Unable to resolve host using built-in resolver: $!");
      return 0;
    }

    # connect again...
    return $self->_connectResolved(@{$addrs});
  }

  # we have async resolver, use it!
  $_log->debug("Will try to resolve host $hostname using async hostname resolver.");
  my $timeout = $self->{checkTimeout} - 0.2;
  $timeout = 0.2 unless ($timeout > 0);
  $kernel->post(
    $_adns_session, 'resolve',
    event   => '_resolveHandler',
    host    => $hostname,
    timeout => $timeout,
  );
}

sub _resolveHandler {
  my ($self, $kernel, $r) = @_[OBJECT, KERNEL, ARG0];

  # error resolving?
  unless ($r->{ok} || @{$r->{result}}) {

    # $_log->error("Error resolving host '$r->{host}': $r->{error}");
    $kernel->yield(FETCH_ERR, "Error resolving host '$r->{host}': $r->{error}");

    #$kernel->yield('pause');
    #$kernel->delay("resume", $self->{errorResumePause});

    # put to cache
    $self->hostCachePut($r->{host});
    return 1;
  }

  $_log->debug("Resolved addresses for host $r->{host}: ", join(", ", @{$r->{result}}));

  # put resolved addresses to cache
  $self->hostCachePut($r->{host}, @{$r->{result}});

  # start connection ...
  $self->_connectResolved(@{$r->{result}});
}

sub _connectResolved {
  my ($self, @addrs) = @_;

  # separate ipv4 and ipv6 addresses
  my @v6 = ();
  my @v4 = ();
  map { push(@v6, $_) if ($util->isIpv6Addr($_)); } @addrs;
  map { push(@v4, $_) if ($util->isIpv4Addr($_)); } @addrs;

  # should we shuffle list of ip addresses?
  if ($self->{shuffleAddr}) {
    $_log->debug("Shuffling list of IP addresses.");
    @v6 = shuffle(@v6);
    @v4 = shuffle(@v4);
  }

  # now choose first connect address
  # print "se smo kle\n";

  # ipv6 support?
  if ($_has_ipv6) {
    if ($self->{preferIpv6}) {
      $self->{__addrs} = [@v6, @v4];
    }
    else {
      @{$self->{__addrs}} = @addrs;
    }
  }
  else {

    # hm, no ipv6, let's see if there are
    # any ipv4 addresses in resolved
    unless (@v4) {
      $poe_kernel->yield(FETCH_ERR,
        'Missing perl IPv6 support and $r->{host} resolves to IPv6 addresses only: ' . join(", ", @addrs));
      return 0;
    }
  }

  $_log->debug($self->getFetchSignature() . " Address connect order: " . join(", ", @{$self->{__addrs}}));

  # get first address for connection
  my $addr = shift(@{$self->{__addrs}});

  # enqueue connect
  $poe_kernel->yield('realConnect', $addr, $self->{__connPort});
}

sub realConnect {
  my ($self, $addr, $port) = @_[OBJECT, ARG0, ARG1];

  # check if we're already connected.
  if (defined $self->{__sf}) {
    $_log->error($self->getFetchSignature() . " Another connection is already active.");
    return $self->{__sf}->ID();
  }

  # check hostname and port
  unless (defined $addr) {
    $_log->error("Undefined connect IP address.");
    return 0;
  }
  unless (defined $port) {
    $_log->error("Undefined connect port number.");
    return 0;
  }

  $_log->debug("Performing connect to: $addr port $port");

  # create socketfactory wheel options...
  my $socket_domain = AF_INET;
  eval {
    no warnings;
    $socket_domain = ($_has_ipv6 && $util->isIpv6Addr($addr)) ? AF_INET6 : AF_INET;
  };
  my %opt = (
    Reuse         => 1,
    SocketDomain  => $socket_domain,
    RemoteAddress => $addr,
    RemotePort    => $port,
    SuccessEvent  => "__connOk",
    FailureEvent  => "__connErr",
  );

  if ($_log->is_trace()) {
    $_log->trace(
      $self->getFetchSignature(),
      " Creating socket factory wheel with options: ",
      $util->dumpVarCompact(\%opt)
    );
  }

  # create socket wheel
  my $sf = POE::Wheel::SocketFactory->new(%opt);
  my $id = $sf->ID();
  $_log->debug($self->getFetchSignature(), " Created socket factory wheel id $id.");

  # save it...
  $self->{__sf} = $sf;

  # ... just to remember...
  $self->{__connAddr} = $addr;
  $self->{__connPort} = $port;

  return $id;
}

=head2 disconnect () [POE only]

Disconnects remote endoint.

=cut

sub disconnect {
  my ($self) = @_;

  # destroy socket factory wheel
  if (defined $self->{__sf}) {
    $_log->debug($self->getFetchSignature(), " Destroying socket factory wheel.");
    undef $self->{__sf};
    $self->{__sf} = undef;
  }

  # destroy rw wheel
  if (defined $self->{__rw}) {
    $_log->debug($self->getFetchSignature(), " Destroying read-write wheel.");
    undef $self->{__rw};
    $self->{__rw} = undef;
  }

  # destroy variables...
  $self->{__connHost} = undef;
  $self->{__connAddr} = undef;
  $self->{__connPort} = undef;
  $self->{__addrs}    = [];

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 EXTENDING

This class is meant as a raw async TCP/IP client component,
enabling you to build more complex statistics sources.

You should reimplement the following methods/events:

=head2 _run()

Source initialization. Must return 1 on success, otherwise 0.

=cut

sub _run {
  my ($self) = @_;
  return 1;

  # this source driver is completely useless by itsef
  $self->{_error}
    = "Class " . __PACKAGE__ . " is only tcp client infrastructure; you must implement your own stuff.";
  return 0;
}

sub _shutdown {
  my ($self) = @_;
  $self->_fetchCancel();
}

sub _fetchCancel {
  my ($self) = @_;

  # destroy wheels...
  undef $self->{__sf};
  undef $self->{__rw};

  # remove list of connection addresses
  $self->{__addrs} = [];

  return 1;
}

sub __connOk {
  my ($self, $kernel, $sock, $addr, $port, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  # determine remote ip address
  my $remote_ip = "";
  if ($_has_ipv6 && length($addr) > 4) {
    no warnings;
    $remote_ip = Socket6::inet_ntop(AF_INET6, $addr);
  }
  else {
    $remote_ip = inet_ntoa($addr);
  }

  # add some stuff...
  $self->{__connAddr} = $remote_ip;


  $_log->debug($self->getFetchSignature(),
    " Connection has been successfuly established with host $remote_ip port $port.");

  # SSL?
  if ($self->{useSSL}) {
    unless ($_has_ssl) {
      $kernel->yield(FETCH_ERR, "SSL connection requested, but perl SSL support is unavailable.");
      return 0;
    }

    # try to sslify it...
    eval { $sock = Client_SSLify($sock); };
    if ($@) {
      $kernel->yield(FETCH_ERR, "Unable to establish SSL connection: $@");
      return 0;
    }

    if ($_log->is_debug()) {
      $_log->debug($self->getFetchSignature(),
        " Successfully established SSL connection using cipher " . SSLify_GetCipher($sock));
    }
  }


  # create rw/wheel...
  my %opt = (
    Handle       => $sock,
    Filter       => POE::Filter::Line->new(),
    InputEvent   => "rwInput",
    FlushedEvent => "rwFlushed",
    ErrorEvent   => "rwError",
  );
  if ($_log->is_trace) {
    $_log->trace(
      $self->getFetchSignature(),
      " Creating read-write wheel with options: ",
      $util->dumpVarCompact(\%opt)
    );
  }
  my $rw = POE::Wheel::ReadWrite->new(%opt);
  my $id = $rw->ID();

  $_log->debug($self->getFetchSignature(), " Created read-write wheel id $id.");

  # save it...
  $self->{__rw} = $rw;

  # fire something...
  $self->_connOk($sock, $addr, $port, $wid);
}

=head2 _connOk ($sock, $addr, $port, $wheel_id)

This method is invoked after connection has been successfully established;
Connection read-write wheel L<POE::Wheel::ReadWrite> is already initialized
with filter L<POE::Filter::Line>.

=cut

sub _connOk {

}

sub __connErr {
  my ($self, $kernel, $operation, $errno, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  my $err = "Error $errno on connection wheel $wid";

  my $host = $self->getConnectedHost(1);
  my $addr = $self->getConnectedAddr(1);
  my $port = $self->getConnectedPort(1);
  if (defined $addr && defined $port) {
    no warnings;
    $err .= " [host: $host; address: $addr; port: $port]";
  }

  $err .= ": " . $errstr;

  # fire something...
  $self->_connErr($operation, $errno, $err, $wid);

  # destroy socketfactory wheel...
  $self->{__sf} = undef;

  # destroy rw wheel...
  $self->{__rw} = undef;

  # are there any more ip addresses left in queue?
  if ($self->{failover} && @{$self->{__addrs}}) {
    my $addr = shift(@{$self->{__addrs}});
    $_log->debug($err);

    # enqueue connection to another address...
    $kernel->yield('realConnect', $addr, $self->{__connPort});

  }
  else {

    # Nope, all we can do is to give up...
    $kernel->yield(FETCH_ERR, $err);
  }

}

=head2 _connErr ($operation, $errno, $errstr, $wheel_id)

This method is called when connection to remote endpoint failed. All internal wheels
are automatically destroyed and source's event FETCH_ERR is invoked automatically.

=cut

sub _connErr {
  return 1;
}

=head2 rwInput ($data, $wheel_id) [POE only]

This event is invoked after something has been read from remote endpoint.
Type of $data variable depends on read-write wheel's Filter object.

B<You must implement this method!>

=cut

sub rwInput {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  $_log->error("Class ", ref($self), " does not implement method rwInput()");
  return $kernel->yield('shutdown');
}

=head2 rwFlushed ($wheel_id) [POE only]

This event is invoked when you enqued some data by invoking event
L<sendData()> and all data has been sent.

=cut

sub rwFlushed {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  $_log->trace($self->getFetchSignature(), " Read-write wheel $wid flushed.");
}

=head2 rwError ($operation, $errnum, $errstr, $wheel_id) [POE only]

This event is invoked when read-write wheel encountered error or EOF
has been reached.

=cut

sub rwError {
  my ($self, $kernel, $operation, $errnum, $errstr, $id) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  $_log->error("Class ", ref($self), " does not implement method rwError()");
  return $kernel->yield('shutdown');
}

sub _initAsyncDNS {
  my ($self) = @_;

  # return immediately if async dns resolver is already spawned...
  return $_adns_session if (defined $_adns_session);

  # uf, looks like we need to load and initalize it...
  eval {

    # try to load module...
    require ACME::Util::PoeDNS;

    # EVIL: Spawn it immediately :)
    $_adns_session = ACME::Util::PoeDNS->spawn();
  };

  if ($@) {
    $self->{_error} = $@;
    $self->{_error} =~ s/\s+$//g;
  }

  # report success...
  return (defined $_adns_session) ? $_adns_session : 0;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent::Plugin::StatCollector::Source>
L<POE::Wheel::ReadWrite>
L<POE::Wheel::SocketFactory>
L<ACME::Util::PoeDNS>
L<ACME::TC::Agent::Plugin::StatCollector>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
