package POE::Component::Server::HTTPEngine;


#
# Enable debugging support if Log::Log4perl is loaded and if environmental
# variable $DEBUG exist...
#
BEGIN {
  use constant DEBUG => eval '(exists($ENV{DEBUG})) ? 1 : 0';
  if (DEBUG) {
    print STDERR "DEBUG: Starting server in debugging mode: DEBUG => ", DEBUG, "\n";
  }

  # IPv6
  use constant HAVE_IPV6 =>
    eval { require Socket; Socket->import(); require Socket6; Socket6->import(); return 1; };

  # SSL support...
  use constant HAVE_SSL => eval
    "require POE::Component::SSLify; require POE::Component::SSLify::ServerHandle";

  # compression...
  use constant HAVE_ZLIB => eval "require Compress::Zlib;";
}

use strict;
use warnings;

################################################
#                 POE MODULES                  #
################################################

use POE;
use POE::Driver::SysRW;
use POE::Filter::HTTPD;
use POE::Filter::Stream;
use POE::Wheel::ReadWrite;
use POE::Filter::Stackable;
use POE::Wheel::SocketFactory;

################################################
#               OTHER MODULES                  #
################################################

use URI;
use bytes;
use Socket;
use IO::File;
use HTTP::Date;
use Data::Dumper;
use Sys::Hostname;
use Log::Log4perl;
use File::Basename;
use URI::QueryParam;
use Symbol qw(gensym);
use POSIX qw(strftime);
use Scalar::Util qw(blessed);
use HTTP::Status qw(:constants);

################################################
#                 OUR MODULES                  #
################################################

use POE::Component::Server::HTTPEngine::Auth;
use POE::Component::Server::HTTPEngine::Logger;
use POE::Component::Server::HTTPEngine::Response;

################################################
#                  CONSTANTS                   #
################################################

use constant TIMEOUT_IDLE_CLIENT     => 300;
use constant TIMEOUT_ORPHANED_CLIENT => 15;

use constant VHOST_DEFAULT => 'default';
use constant LOG_ERROR     => 'error';
use constant LOG_ACCESS    => 'access';
use constant EVENT_DONE    => 'DONE';
use constant EVENT_CLOSE   => 'CLOSE';
use constant EVENT_STREAM  => 'STREAM';

use constant CONTENT_TYPE_DEFAULT => 'text/plain';

# listener storage constants
use constant SR_WHEEL    => 0;
use constant SR_IP       => 1;
use constant SR_PORT     => 2;
use constant SR_SSL      => 3;
use constant SR_SSL_KEY  => 4;
use constant SR_SSL_CERT => 5;
use constant SR_PAUSED   => 6;
use constant SR_SSL_CTX  => 7;
use constant SR_IPV6     => 7;

# client storage constants...
use constant CL_WHEEL     => 0;
use constant CL_DONE      => 1;
use constant CL_SSLFIED   => 2;
use constant CL_IP        => 3;
use constant CL_PORT      => 4;
use constant CL_SMTIME    => 5;
use constant CL_STREAM    => 6;
use constant CL_SESS      => 7;
use constant CL_SSLCIPH   => 8;
use constant CL_CLOSE     => 9;
use constant CL_REQ       => 10;
use constant CL_WHEEL_SRV => 11;
use constant CL_SOCKET    => 12;
use constant CL_FILTER    => 13;
use constant CL_CHUNKED   => 14;
use constant CL_NREQS     => 15;
use constant CL_DEFLATE   => 16;

################################################
#              OPTIONAL MODULES                #
################################################

###############################################

use vars qw(@ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);

use constant RC_WAIT => -1;
use constant RC_DENY => -2;
@EXPORT = qw(RC_WAIT RC_DENY DEBUG);

# module version
our $VERSION = 1.08;

# list of loaded classes
my @_loaded_classes = ();

# logger object
my $_log = undef;

# initialize debugger...
if (DEBUG) {
  _log4j_init();
}

=head1 NAME

POE::Component::Server::HTTPEngine - POE based, feature-rich HTTP server.

=head1 SYNOPSIS

	#!/usr/bin/perl
	
	use strict;
	use warnings;
	
	# load server component...
	use POE::Component::Server::HTTPEngine;
	
	# constructor options
	my $opt = (
		port => 9002,
	);
	
	# create server object...
	my $srv = POE::Component::Server->HTTPEngine->new(%opt);
	
	# mount some URL handlers...
	$srv->mount(
		# match uri
		uri => '/',
		
		# uri handler stuff...
		handler_type => "class",
		handler_class => "FS",
		handler_opt => {
			
		},
	);

	# start the goddamn server...
	$srv->run();

	exit 0;
	# P.S.: have you noticed that none of POE classes were loaded? ;)

=head1 OBJECT CONSTRUCTOR

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  $self->{_error} = "";

  # initialize log4perl logger if we're debugging...
  if (DEBUG && !defined $_log) {
    $_log = Log::Log4perl->get_logger(__PACKAGE__);
  }

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);
  return $self;
}

sub DESTROY {
  my $self = shift;
  if (DEBUG) {
    $_log->debug("Destroying: $self") if (defined $_log);
  }
}

################################################
#                PUBLIC METHODS                #
################################################

=head1 METHODS

All methods marked with B<[POE]> can be invoked as an object methor or by
issuing POE::Kernel's call(), post(), callback(), or postback().

	# object invocation...
	my $err = $srv->getError()
	
	# POE invocation
	my $err = $_[KERNEL]->call("HTTPD", "getError");
	
Other methods can be invoked only as object methods...


=item COMMON METHODS

=cut

sub haveZlib {
  return (HAVE_ZLIB) ? 1 : 0;
}

sub haveSSL {
  return (HAVE_SSL) ? 1 : 0;
}

sub haveIPv6 {
  return (HAVE_IPV6) ? 1 : 0;
}

=head3 getError () [POE]

Returns last error accoured.

=cut

sub getError {
  my $self = shift;
  return $self->{_error};
}

sub getListenPortByClient {
  my ($self, $wheel_id) = @_;
  return undef unless (defined $wheel_id);
  return undef unless (exists($self->{_clients}->{$wheel_id}));
  my $srv_wheel_id = $self->{_clients}->{$wheel_id}->[CL_WHEEL_SRV];

  # get server...
  return undef unless (exists($self->{_listeners}->{$srv_wheel_id}));

  return $self->{_listeners}->{$srv_wheel_id}->[SR_PORT];
}

sub getListenIpByClient {
  my ($self, $wheel_id) = @_;
  return undef unless (defined $wheel_id);
  return undef unless (exists($self->{_clients}->{$wheel_id}));
  my $srv_wheel_id = $self->{_clients}->{$wheel_id}->[CL_WHEEL_SRV];

  # get server...
  return undef unless (exists($self->{_listeners}->{$srv_wheel_id}));
  my $x = $self->{_listeners}->{$srv_wheel_id}->[SR_IP];
  if ($x eq '*') {
    $x = "0.0.0.0";
  }

  return $x;
}

sub getSessionId {
  my $self = shift;
  return $self->{_poe_session};
}

sub setParams {
  my $self = shift;
  while (@_) {
    my $key = shift;
    my $v   = shift;
    next if ($key =~ m/^_/);
    if (DEBUG) {
      no warnings;
      $_log->debug("Setting config key '$key' to value '$v'");
    }
    $self->{$key} = $v;
  }

  return 1;
}

=head3 addDelayedMessage ($event_name, $delay, [$arg1, $arg2])

Adds delayed message to server session; for example, you can schedule server shutdown :)

=cut

sub addDelayedMessage {
  my ($self, @args) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  if (DEBUG) {
    $_log->debug("Adding delayed message: ", join(", ", @args));
  }

  return $poe_kernel->delay_add(@args);
}

sub clearParams {
  my ($self) = @_;
  $self->{alias}         = __PACKAGE__ . "_" . rand();
  $self->{addr}          = "*";
  $self->{port}          = 9001;
  $self->{server_name}   = hostname();
  $self->{ssl}           = 0;
  $self->{ssl_cert}      = undef;
  $self->{ssl_key}       = undef;
  $self->{max_clients}   = 500;
  $self->{server_string} = sprintf("%s/%-.2f", __PACKAGE__, $VERSION);

  $self->{keepalive}         = 1;
  $self->{keepalive_timeout} = 300;
  $self->{keepalive_num}     = 50;

  $self->{check_interval}       = 5;
  $self->{default_content_type} = "text/plain";

  @{$self->{compress_content_types}} = ('^text\/');

  $self->{error_log}  = *STDERR;
  $self->{access_log} = *STDOUT;
  $self->{log_format} = "";

  ################################################
  #                COMPATIBILITY                 #
  ################################################

  # TODO: PoCo::Server::SimpleHTTP compatibility stuff...
  $self->{ALIAS}        = undef;
  $self->{ADDRESS}      = undef;
  $self->{PORT}         = undef;
  $self->{HOSTNAME}     = undef;
  $self->{HEADERS}      = undef;    # is hashref, when defined...
  $self->{HANDLERS}     = undef;    # is hashref, when defined...
  $self->{KEEPALIVE}    = undef;
  $self->{LOGHANDLER}   = undef;    # is hashref, when defined...
  $self->{LOG2HANDLER}  = undef;    # is hashref, when defined...
  $self->{SETUPHANDLER} = undef;    # is hashref, when defined...
  $self->{SSLKEYCERT}   = undef;    # is arrayref, when defined...
  $self->{PROXYMODE}    = undef;    #

  # TODO: PoCo::Server::HTTP compatibility stuff...
  $self->{TransHandler}   = undef;    # is hashref, when defined...
  $self->{PreHandler}     = undef;    # is hashref, when defined...
  $self->{ContentHandler} = undef;    # is hashref, when defined...
  $self->{ErrorHandler}   = undef;    # is hashref, when defined...
  $self->{PostHandler}    = undef;    # is hashref, when defined...
  $self->{StreamHandler}  = undef;    # is coderef, when defined...

  ################################################
  #              INTERNAL   VARIABLES            #
  ################################################

  # server is spawned...
  $self->{_spawned} = 0;

  # hash containing mounted contexts
  my $vhost = VHOST_DEFAULT;
  $self->{_ctx} = {$vhost => {},};

  # server listener wheels
  $self->{_listeners} = {};

  # client wheels
  $self->{_clients} = {};

  # current number of clients being processed.
  $self->{_num_clients} = 0;

  # logging objects...
  $self->{_loggers} = {};

  return 1;
}

=head3 spawn () 

Spawns POE session. Returns POE session id on success, otherwise 0.

=cut

sub spawn {
  my ($self) = @_;

  # are we already spawned?
  if ($self->{_spawned}) {
    $self->{_error} = "Server has already been spawned.";
    return 0;
  }

  # create POE session...
  my $id = POE::Session->create(
    object_states => [
      $self => [
        qw(
          _start _stop _parent _child _default

          listenerCreate listenerCreateAll
          listenerDestroy listenerDestroyAll
          listenerList listenerInfo
          listenerPause listenerResume

          __listenerNewConnection __listenerError
          __clientInput __clientFlushed __clientError __clientCleanup

          logError logAccess

          mount

          STREAM DONE CLOSE
          addDelayedMessage
          shutdown

          __sigh_CHLD
          )
      ],
    ],
  )->ID();

  # mark ourselves as spawned...
  $self->{_spawned} = 1;

  return $id;
}

sub _start {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  if (DEBUG) {
    $_log->debug("Starting HTTP server.");
    $_log->debug("_start: Starting object ", ref($self), " in POE session ", $_[SESSION]->ID());
  }

  if (defined $self->{alias} && length($self->{alias}) > 0) {
    $_log->debug("Setting POE session alias: '$self->{alias}'.") if (DEBUG);
    $kernel->alias_set($self->{alias});
  }

  # save session id...
  $self->{_poe_session} = $_[SESSION]->ID();

  # create loggers...
  $self->loggerCreateAll();

  # inform loggers that we're starting :)
  $self->logError(sprintf("Starting %s/%-.2f.", __PACKAGE__, $VERSION));

  # enqueue creation of listening sockets...
  $kernel->yield("listenerCreateAll");

  # start client connection cleanup
  $kernel->delay_add("__clientCleanup", $self->{check_interval});

  return 1;
}

sub _stop {
  my $self = shift;
  $_log->debug("Stopping object ", ref($self), " POE session ", $_[SESSION]->ID())
    if (DEBUG && defined $_log);
}

sub _parent {
  my ($self, $old, $new) = @_[OBJECT, ARG0, ARG1];
  $_log->warn("Object ", ref($self), " parent POE session change: from ", $old->ID(), " to ", $new->ID())
    if (DEBUG);
}

sub _child {
  my ($self, $reason, $child) = @_[OBJECT, ARG0, ARG1];
  if ($reason eq 'close') {
    $_log->debug("_child: POE session exit: " . $child->ID()) if (DEBUG);
  }
  else {
    $_log->debug("_child: Reason: $reason; id: " . $child->ID()) if (DEBUG);
  }
}

sub _default {
  my ($self, $event, $args) = @_[OBJECT, ARG0, ARG1];
  my $str
    = "Object "
    . ref($self)
    . ", POE session "
    . $_[SESSION]->ID()
    . " caught unhandled event from session id '"
    . $_[SENDER]->ID()
    . "'. Called event '$event' with arguments: ["
    . join(", ", @{$args}) . "].";

  if (DEBUG) {
    $_log->warn($str);
  }
  else {
    print STDERR __PACKAGE__, " WARNING: $str\n";
  }
}

=head3 run ()

This is blocking shortcut for:

	$srv->spawn();
	POE::Kernel->run();

This method allows you to start http server and poe kernel without importing POE modules in your
namespace. It starts webserver if spawn() method wasn't yet invoked and starts POE kernel if it's not
already running.

Returns 1 on success, otherwise 0.

=cut

sub run {
  my ($self) = @_;

  # spawn poe sessions...
  unless ($self->{_spawned}) {
    $_log->debug("Spawning server.") if (DEBUG);
    return 0 unless ($self->spawn());
  }

  # figure out if POE::Kernel is already running...
  my $kr_run_warning = ${$poe_kernel->[POE::Kernel::KR_RUN()]};
  my $x              = POE::Kernel::KR_RUN_CALLED();
  my $poe_started    = ($kr_run_warning & $x);

  # start POE kernel if it's not yet started
  unless ($poe_started) {
    $_log->debug("POE::Kernel is not started, starting.") if (DEBUG);
    POE::Kernel->run();
  }

  return 1;
}

sub isDebug {
  return DEBUG;
}

=head3 shutdown() [POE]

Stops HTTP server and kills all currently processing clients. Always returns 1.

=cut

sub shutdown {
  my $self = shift;
  $_log->debug("Shutting down HTTP server.") if (DEBUG);
  $self->logError("Shutting down HTTP server.");

  # remove all alarms...
  $poe_kernel->alarm_remove_all();

  # remove all aliases
  map { $poe_kernel->alias_remove($_) } $poe_kernel->alias_list();

  # destroy listeners...
  $poe_kernel->call($self->{_poe_session}, "listenerDestroyAll");

  # destroy all clients
  $self->_clientDestroyAll();

  # destroy all loggers
  $self->loggerDestroyAll();

  $_log->debug("Shutdown complete.") if (DEBUG);

  return 1;
}

=item LISTENER METHODS/POE EVENTS

You can add or remove socket listeners while server is running using methods listed below.

=cut

sub listenerCreateAll {
  my $self = shift;

  # build listener string...
  my $str = "";

  # general stuff?
  if (defined $self->{port}) {
    no warnings;
    $self->{port} = int($self->{port});

    if ($self->{port} > 0 && $self->{port} < 65536) {
      my $addr = "*";

      # do we have listening address defined?
      if (defined $self->{addr}) {
        $self->{addr} =~ s/\s+//g;
        $addr = $self->{addr} if (length($self->{addr}) > 0);
      }
      $str = $addr . ":" . $self->{port};
    }

    # any ssl stuff?
    if ($self->{ssl} && defined $self->{ssl_cert} && defined $self->{ssl_key}) {
      $str .= "," . $self->{ssl_cert} . "," . $self->{ssl_key};
    }

    $str .= ";";
  }

  # any additional listeners?
  if (defined $self->{listeners}) {
    $str .= $self->{listeners};
  }

  # print "SELF", Dumper($self), "\n";

  my $num = 0;
  $_log->debug("Creating socket listeners from string: '$str'") if (DEBUG);
  foreach my $sock_desc (split(/\s*;+\s*/, $str)) {

    # $_log->debug("Creating socket from str: '$sock_desc'");
    my ($addr, $ssl_cert, $ssl_key) = split(/\s*,+\s*/, $sock_desc);
    no warnings;
    $_log->debug("Creating socket addr: '$addr'; ssl_cert: '$ssl_cert'; ssl_key: '$ssl_key'") if (DEBUG);
    if ($self->listenerCreate($addr, $ssl_cert, $ssl_key)) {
      $num++;
    }
    else {
      $_log->debug("Error creating listening socket '$sock_desc': " . $self->getError()) if (DEBUG);
    }
  }

  $_log->debug("Created $num listening socket(s).") if (DEBUG);

  # $self->logError("Created $num listening socket(s).");

  return $num;
}

=head3 listenerCreate ($address, $ssl_cert_file, $ssl_key_file) [POE]

Creates new socket listener.

Returns number of successfully created listening sockets on success, otherwise 0.

=cut

sub listenerCreate {
  my ($self, $address, $ssl_cert, $ssl_key) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;
  $ssl_key = $ssl_cert unless (defined $ssl_key);

  $_log->debug("Creating listener: address = '$address'.") if (DEBUG);

  # check the address specification...
  unless (defined $address && length($address)) {
    $self->{_error} = "Undefined address.";
    return 0;
  }

  my $ssl         = 0;
  my $ssl_context = undef;
  my $addr        = undef;
  my $port        = 0;

  # parse address
  if ($address =~ m/^\s*([0-9a-z\.\:\*]+)\s*:{1}\s*(\d+)\s*$/) {
    $_log->debug("Matched addr '$1'; matched port; '$2'") if (DEBUG);
    $addr = $1;
    $port = int($2);

    # remove any whitechars...
    $addr =~ s/\s+//g;

    # remove multiple stars from address...
    $addr =~ s/\*{1,}/\*/g;
  }
  else {
    $self->{_error} = "Invalid listening socket syntax. Correct syntax: <addr>:<port>";
    return 0;
  }

  # check port number
  if ($port < 1 || $port >= 65536) {
    $self->{_error} = "Invalid port number: $port";
    return 0;
  }

  # check ssl stuff...
  if (defined $ssl_cert) {

    # do we even have SSL support?
    unless (HAVE_SSL) {
      $self->{_error} = "Missing module POE::Component::SSLify; SSL support is unavailable.";
      return 0;
    }

    unless (defined $ssl_cert
      && defined $ssl_key
      && -r $ssl_cert
      && -f $ssl_cert
      && -r $ssl_key
      && -f $ssl_key)
    {
      $self->{_error} = "Invalid SSL certicate file '$ssl_cert' or key file '$ssl_key'.";
      return 0;
    }

    $ssl = 1;

    # create SSL context...
    eval { $ssl_context = POE::Component::SSLify::SSLify_ContextCreate($ssl_key, $ssl_cert); };
    if ($@) {
      $self->{_error} = "Unable to create SSL server context: $@";
      return 0;
    }
  }

  $_log->debug("Parsed addr '$addr'; port '$port'.") if (DEBUG);

  # create socket factory options...
  my $opt = {
    BindPort     => $port,
    Reuse        => 1,
    SuccessEvent => "__listenerNewConnection",
    FailureEvent => "__listenerError",
  };

  # list of sockets to create :)
  my $todo = [];

  # let's inspect listen address...
  if (!defined $addr || length($addr) < 1 || $addr eq '*') {

    # whoa, listen on all available interfaces! This could possibly mean
    # listening on ipv6!!!
    if (HAVE_IPV6) {

      # add ipv6 listening socket...
      $opt->{BindAddress}  = "::";
      $opt->{SocketDomain} = AF_INET6;
      push(@{$todo}, $opt);

      # add ipv4 listening socket...
      my $v4opt = {};
      %{$v4opt} = %{$opt};
      $v4opt->{BindAddress}  = "0.0.0.0";
      $v4opt->{SocketDomain} = AF_INET;
      push(@{$todo}, $v4opt);
    }
    else {

      # ipv4 sockets are default :)
      $opt->{BindAddress}  = "0.0.0.0";
      $opt->{SocketDomain} = AF_INET;
      push(@{$todo}, $opt);
    }
  }
  else {

    # does it look like ipv6 address?
    if ($addr =~ m/:/) {
      if (HAVE_IPV6) {
        $opt->{BindAddress}  = $addr;
        $opt->{SocketDomain} = AF_INET6;
      }
      else {
        $self->{_error} = "Unable to create IPv6 connector $addr port $port: IPv6 support is unavailable.";
        $self->logError($self->{_error});
        return 0;
      }
    }

    # nope, it's just plain old ipv4 address.
    else {
      $opt->{BindAddress}  = $addr;
      $opt->{SocketDomain} = AF_INET;
    }
    push(@{$todo}, $opt);
  }

  # now create all sockets in @{$todo}
  my $i = 0;
  foreach my $o (@{$todo}) {
    next unless (defined $o && ref($o) eq 'HASH');

    # create socketfactory wheel
    my $wheel    = POE::Wheel::SocketFactory->new(%{$o});
    my $wheel_id = $wheel->ID();

    my $is_ipv6 = ($o->{SocketDomain} == AF_INET) ? 0 : 1;
    my $log_str
      = "Started IPv"
      . (($is_ipv6) ? "6"    : "4") . " "
      . (($ssl)     ? "SSL " : "")
      . "socket listener $wheel_id [$o->{BindAddress}/$o->{BindPort}]";
    $self->logError($log_str);
    $_log->debug($log_str) if (DEBUG);

    # save listener object...
    $self->{_listeners}->{$wheel_id}->[SR_WHEEL]    = $wheel;
    $self->{_listeners}->{$wheel_id}->[SR_IP]       = $o->{BindAddress};
    $self->{_listeners}->{$wheel_id}->[SR_PORT]     = $port;
    $self->{_listeners}->{$wheel_id}->[SR_SSL]      = $ssl;
    $self->{_listeners}->{$wheel_id}->[SR_SSL_KEY]  = $ssl_key;
    $self->{_listeners}->{$wheel_id}->[SR_SSL_CERT] = $ssl_cert;
    $self->{_listeners}->{$wheel_id}->[SR_PAUSED]   = 0;
    $self->{_listeners}->{$wheel_id}->[SR_SSL_CTX]  = $ssl_context;
    $self->{_listeners}->{$wheel_id}->[SR_IPV6]     = $is_ipv6;

    # just return the wheel's id indicating success
    # return $wheel_id;
    $i++;
  }

  return $i;
}

=head3 listenerDestroy ($id) [POE]

Destroys listener identified by id $id. Returns 1 on success, otherwise 0.

=cut

sub listenerDestroy {
  my ($self, $wheel_id) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  return 0 unless ($self->listenerIsValid($wheel_id));

  my $addr = $self->{_listeners}->{$wheel_id}->[SR_IP] . ":" . $self->{_listeners}->{$wheel_id}->[SR_PORT];

  $_log->debug("Destroying listener: $wheel_id [$addr]") if (DEBUG);
  $self->logError("Destroying listener: $addr");
  delete($self->{_listeners}->{$wheel_id});

  # no more listeners?
  if (scalar(keys %{$self->{_listeners}}) < 1) {
    my $str = "No active listeners, shutting down the server";
    $_log->debug($str) if (DEBUG);
    $self->logError($str);
    $poe_kernel->yield("shutdown");
  }

  return 1;
}

=head3 listenerDestroyAll [POE]

Destroys all active socket listeners. Returns number of listeners destroyed.

=cut

sub listenerDestroyAll {
  my $self = shift;
  $_log->debug("Destroying all active socket listeners.") if (DEBUG);
  my $num = 0;
  foreach ($self->listenerList()) {
    $num += $self->listenerDestroy($_);
  }
  $_log->debug("Destroyed $num listener(s).") if (DEBUG);
  return $num;
}

=head3 listenerIsValid ($id) [POE]

Returns 1 if specified id $id is valid identificator of active socket listener, otherwise returns 0.

=cut

sub listenerIsValid {
  my ($self, $wheel_id) = @_;
  unless (defined $wheel_id) {
    $self->{_error} = "Undefined wheel ID.";
    return 0;
  }
  unless (exists($self->{_listeners}->{$wheel_id})) {
    $self->{_error} = "Invalid, non-existent listener: $wheel_id.";
    return 0;
  }

  return 1;
}

=head3 listenerInfo ($id) [POE]

Returns list containing info about listener specified by id $id.

=cut

sub listenerInfo {
  my ($self, $wheel_id) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  return undef unless ($self->listenerIsValid($wheel_id));
}

=head3 listenerGetListenAddr ($wheel_id) [POE]

=cut

sub listenerGetListenAddr {
  my ($self, $wheel_id) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  return undef unless ($self->listenerIsValid($wheel_id));

  if (wantarray()) {
    return ($self->{_listeners}->{$wheel_id}->[SR_IP], $self->{_listeners}->{$wheel_id}->[SR_PORT]);
  }

  return $self->{_listeners}->{$wheel_id}->[SR_IP] . ":" . $self->{_listeners}->{$wheel_id}->[SR_PORT];
}

=head3 listenerPause ($id) [POE]

Socket listener identified by $id stops accepting connections. Returns 1 on success, otherwise 0.

=cut

sub listenerPause {
  my ($self, $wheel_id) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  return 0 unless ($self->listenerIsValid($wheel_id));

  $_log->debug("Pausing listener: $wheel_id") if (DEBUG);

  # is this needed?
  # $self->{_listeners}->{$wheel_id}->[SR_WHEEL]->pause_input();
  $self->{_listeners}->{$wheel_id}->[SR_PAUSED] = 1;

  return 1;
}

=head3 listenerIsPaused ($id) [POE]

Returns 1 if listener is paused, otherwise 0.

=cut

sub listenerIsPaused {
  my ($self, $wheel_id) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  return 0 unless ($self->listenerIsValid($wheel_id));
  return $self->{_listeners}->{$wheel_id}->[SR_PAUSED];
}

=head3 listerPauseAll () [POE]

Pauses all currently active socket listeners. Returns number of paused listeners...

=cut

sub listenerPauseAll {
  my $self = shift;
  my $num  = 0;
  foreach ($self->listenerList()) {
    $num += $self->listenerPause($_);
  }

  $_log->debug("Paused $num listener(s).") if (DEBUG);
}

=head3 listenerResume ($id) [POE]

Resume previously paused socket listener identified by id $id. Returns 1 on success, otherwise 0. 

=cut

sub listenerResume {
  my ($self, $wheel_id) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  return 0 unless ($self->listenerIsValid($wheel_id));

  $_log->debug("Resuming listener: $wheel_id") if (DEBUG);

  #$self->{_listeners}->{$wheel_id}->[SR_WHEEL]->resume_input();
  $self->{_listeners}->{$wheel_id}->[SR_PAUSED] = 0;

  return 1;
}

=head3 listerResumeAll () [POE]

Resumes all currently active socket listeners. Returns number of resumed listeners.

=cut

sub listenerResumeAll {
  my $self = shift;
  my $num  = 0;
  foreach ($self->listenerList()) {
    $num += $self->listenerResume($_);
  }

  $_log->debug("Resumed $num listener(s).") if (DEBUG);
  return $num;
}

=head3 listenerList () [POE]

Returns ID list of active socket listeners...

=cut

sub listenerList {
  my $self = shift;
  return sort keys %{$self->{_listeners}};
}

=head3 listenerNum () [POE]

Returns number of active listeners.

=cut

sub listenerNum {
  my $self = shift;
  return scalar keys %{$self->{_listeners}};
}

# some lister accepted new connection!!!
sub __listenerNewConnection {
  my ($self, $client, $remote_addr, $remote_port, $listener_wheel_id) = @_[OBJECT, ARG0 .. $#_];

  # can we accept new client?
  if ($self->{_num_clients} >= $self->{max_clients}) {
    $client = undef;
    $_log->debug("Total number of maximum allowed clients reached, dropping connection.") if (DEBUG);
    $self->logError("Total number of maximum allowed clients reached, dropping connection.");
    return 1;
  }

  my $remote_ip = "";
  if ($self->{_listeners}->{$listener_wheel_id}->[SR_IPV6]) {
    local $@;
    $remote_ip = eval { Socket6::inet_ntop(AF_INET6, $remote_addr) };
    if ($@ && !defined $remote_ip) {
      $remote_ip = eval { inet_ntoa($remote_addr) };
    }
  }
  else {
    $remote_ip = inet_ntoa($remote_addr);
  }
  $_log->debug("[listener $listener_wheel_id]: Accepted new connection from $remote_ip port $remote_port")
    if (DEBUG);

  # Upgrade client socket SSLfied one if requested...
  my $is_sslfied = 0;
  my $ssl_cipher = undef;
  if (HAVE_SSL) {

    # get listener structure reference...
    my $list_ref = $self->{_listeners}->{$listener_wheel_id};

    # was this client accepted from SSLfied socket?
    if ($list_ref->[SR_SSL] == 1) {
      $_log->debug("SSLify: YES") if (DEBUG);

      # yup, this one should be sslfied...
      eval { $client = my_server_sslify($client, $list_ref->[SR_SSL_CTX]); };

      # any injuries?
      if ($@) {
        $_log->debug("[listener $listener_wheel_id]: Unable to SSLify client ($remote_ip:$remote_port): $@")
          if (DEBUG);
        $self->logError("Unable to SSLify client connection $remote_ip:$remote_port: $@");

        # immediately destroy client...
        $client = undef;
        return 0;
      }
      $is_sslfied = 1;

      # try to obtain SSL cipher...
      eval { $ssl_cipher = POE::Component::SSLify::SSLify_GetCipher($client); };

      # no cipher?
      if ($@ || !defined $ssl_cipher) {
        $_log->debug(
          "[listener $listener_wheel_id]: Unable to obtain ssl cipher ($remote_ip:$remote_port): $@")
          if (DEBUG);
        $self->logError("Unable to determine SSL cipher for client $remote_ip:$remote_port: $@");
        $client = undef;
        return 0;
      }

      $_log->debug("[listener $listener_wheel_id]: SSL cipher: $ssl_cipher") if (DEBUG);
    }
    else {
      $_log->debug("[listener $listener_wheel_id]: SSLify: NO") if (DEBUG);
    }
  }

  # create rw wheel...
  my $wheel = POE::Wheel::ReadWrite->new(
    Handle       => $client,
    Driver       => POE::Driver::SysRW->new(),
    InputFilter  => POE::Filter::HTTPD->new(),
    OutputFilter => POE::Filter::HTTPD->new(),
    InputEvent   => "__clientInput",
    FlushedEvent => "__clientFlushed",
    ErrorEvent   => "__clientError",
  );

  my $wheel_id = $wheel->ID();

  # save client's wheel...
  $self->{_clients}->{$wheel_id}->[CL_SOCKET]    = $client;
  $self->{_clients}->{$wheel_id}->[CL_WHEEL]     = $wheel;
  $self->{_clients}->{$wheel_id}->[CL_WHEEL_SRV] = $listener_wheel_id;
  $self->{_clients}->{$wheel_id}->[CL_SSLFIED]   = $is_sslfied;
  $self->{_clients}->{$wheel_id}->[CL_IP]        = $remote_ip;
  $self->{_clients}->{$wheel_id}->[CL_PORT]      = $remote_port;
  $self->{_clients}->{$wheel_id}->[CL_SSLCIPH]   = ($is_sslfied) ? $ssl_cipher : undef;
  $self->{_clients}->{$wheel_id}->[CL_REQ]       = undef;
  $self->{_clients}->{$wheel_id}->[CL_NREQS]     = 0;
  $self->{_clients}->{$wheel_id}->[CL_DEFLATE]   = undef;

  # reset other per-connection related stuff...
  $self->_clientReset($wheel_id);

  # increment number of processed clients..
  $self->{_num_clients}++;

  if (DEBUG) {
    $_log->debug("[listener $listener_wheel_id]: created client wheel: $wheel_id.");
  }

  return 1;
}

# some listener encoutered error!
sub __listenerError {
  my ($self, $operation, $errnum, $errstr, $wheel_id) = @_[OBJECT, ARG0 .. ARG3];
  my ($addr, $port, $is_ipv6) = $self->_getConnector($wheel_id);

  # no address? this is bogus...
  unless (defined $addr) {
    $_log->debug("ConnERR: Invalid wheel: $wheel_id") if (DEBUG);
    return 0;
  }

  my $sock_type = "IPv" . (($is_ipv6) ? "6" : "4");

  # unable to bind listening socket?
  if ($operation eq 'bind') {
    my $str = "[listener $wheel_id]: Unable to bind $sock_type listening socket $addr/$port: $errstr";
    $_log->debug($str) if (DEBUG);
    $self->logError($str);
    $self->listenerDestroy($wheel_id);

    # check if there are any connectors left...
    unless (scalar(keys %{$self->{_listeners}}) > 0) {
      $_log->debug("No more active listeners, shutting down.") if (DEBUG);
      $poe_kernel->yield('shutdown');
    }
  }
  else {
    my $str = "Error ($operation; $errnum) on $sock_type listening socket $addr/$port: $errstr";
    $_log->debug($str) if (DEBUG);
    $self->logError($str);
  }
}

sub clientIsValid {
  my ($self, $wheel_id) = @_;
  return 0 unless (defined $wheel_id);
  return 0 unless (exists($self->{_clients}->{$wheel_id}));
  return 0 unless (defined $self->{_clients}->{$wheel_id}->[CL_WHEEL]);
  return 1;
}

sub loggerCreateAll {
  my ($self) = @_;
  my $num = 0;

  # default error log?
  if (defined $self->{error_log}) {
    my $obj = POE::Component::Server::HTTPEngine::Logger->new($self->{error_log});
    if (defined $obj) {
      $num++;

      # assign logger
      $self->loggerAddObj($obj, LOG_ERROR, VHOST_DEFAULT);
    }
  }

  # default access log?
  if (defined $self->{access_log}) {
    my $obj = POE::Component::Server::HTTPEngine::Logger->new($self->{access_log});
    if (defined $obj) {
      $num++;

      # assign logger
      $self->loggerAddObj($obj, LOG_ACCESS, VHOST_DEFAULT);
    }
  }

  # TODO: create loggers of all vhosts...

  $_log->debug("Created $num logger(s).") if (DEBUG);
  return $num;
}

sub loggerAddObj {
  my ($self, $obj, $type, $vhost) = @_;
  return 0 unless (defined $obj);
  $type  = "error"   unless (defined $type);
  $vhost = "default" unless (defined $vhost);

  my $wheel_id = $obj->ID();

  # logger name
  my $logger_name = $type . "|" . $vhost;

  $_log->debug("Adding logger '$logger_name': $wheel_id") if (DEBUG);

  # save object...
  $self->{_loggers}->{$logger_name} = $obj;

  return 1;
}

sub loggerDestroy {
  my ($self, $wheel_id) = @_;
  $_log->debug("Destroying logger: $wheel_id") if (DEBUG);

  my $id = $self->{_loggers}->{$wheel_id}->ID();

  # try to destroy it gently...
  my $x = $poe_kernel->call($id, "shutdown");

  # destroy logging object...
  $self->{_loggers}->{$wheel_id} = undef;
  delete($self->{_loggers}->{$wheel_id});

  return 1;
}

sub loggerDestroyAll {
  my $self = shift;
  $_log->debug("Destroying all initialized loggers.") if (DEBUG);

  # print "SELF: ", Dumper($self), "\n";

  my $num = 0;
  foreach (keys %{$self->{_loggers}}) {
    $num += $self->loggerDestroy($_);
  }
  $_log->debug("Destroyed $num logger(s).") if (DEBUG);

  # print "_loggers: ", Dumper($self->{_loggers}), "\n";
  return $num;
}

# logging stuff
sub logError {
  my ($self, $msg, $vhost) = @_;

  # compute vhost name
  $vhost = VHOST_DEFAULT unless (defined $vhost);

  # logger name
  my $logger_name = LOG_ERROR . "|" . $vhost;

  # send message to logger
  if (exists($self->{_loggers}->{$logger_name})) {

    # add apache-like timestamp: [Sun May 04 06:46:16 2008]
    my $t = strftime("[%a %b %d %H:%M:%S %Y] ", localtime(time()));

    # send data to logger...
    $self->{_loggers}->{$logger_name}->log($t . $msg);
    return 1;
  }

  # complain!
  #warn "Undefined logger wheel for logger '$logger_name'.\n";
  return 0;
}

sub logAccess {
  my ($self, $response) = @_;
  my $wheel_id = $response->wheel();
  $_log->debug("Wheel accesslog: $wheel_id") if (DEBUG);

  unless (exists($self->{_clients}->{$wheel_id})) {
    $_log->debug("Wheel $wheel_id doesn't exist.") if (DEBUG);
    return 0;
  }

  # get request object...
  my $request = $self->{_clients}->{$wheel_id}->[CL_REQ];

  unless (defined $request) {
    $_log->debug("No request object!") if (DEBUG);
    return 0;
  }

  # we have now request and response object...
  # do the magic!
  my ($user, $pass) = $request->authorization_basic();

  # compute logging string...
  my $str = sprintf(
    "%s - %s [%s] \"%s %s%s %s\" %d %d \"%s\" \"%s\" \"%s\"",
    $response->connection()->remote_ip(),
    $user || "-",
    strftime("%d/%b/%Y:%T %z", localtime(time())),
    $request->method(),
    $request->uri()->path(),
    ($request->uri()->query()) ? "?" . $request->uri()->query() : "",
    $request->protocol(),
    $response->code(),
    $response->getBytes(),
    $request->header("Referer")    || "-",
    $request->header("User-Agent") || "-",
    $request->header("Cookie")     || "-"
  );

  # compute vhost name
  my $vhost = $response->vhost();
  $vhost = VHOST_DEFAULT unless (defined $vhost);

  # logger name
  my $logger_name = LOG_ACCESS . "|" . $vhost;

  # send message to logger
  if (exists($self->{_loggers}->{$logger_name})) {

    # send data to logger...
    $self->{_loggers}->{$logger_name}->log($str, $request, $response);
    return 1;
  }

  # complain!
  # warn "Undefined logger wheel for logger '$logger_name'.\n";
  return 0;
}

sub requestHandlerCode {
  my ($self, $code, $request, $response) = @_;

  # create new session to handle client's request...
  POE::Session->create(
    args          => [$request, $response],
    inline_states => {
      _start => sub {
        $_log->debug("Starting CODE handler POE session: ", $_[SESSION]->ID());

        # save request/response to heap (in case we'll need them...)
        $_[HEAP]->{request}  = $_[ARG0];
        $_[HEAP]->{response} = $_[ARG1];

        # enqueue execution of custom handler...
        $_[KERNEL]->yield("handler", $_[ARG0], $_[ARG1]);
      },
      _stop => sub {
        $_log->debug("Stopping CODE handler POE session: ", $_[SESSION]->ID());
      },

      handler => sub {
        my ($kernel, $request, $response) = @_[KERNEL, ARG0, ARG1];

        # run handler code...
        eval { &{$code}($request, $response); };

        # error while executing custom handler sub?
        if ($@) {
          $response->setError($request->uri()->path(),
            HTTP_INTERNAL_SERVER_ERROR, "Error executing custom handler code: $@");
        }

        # push response to client...
        if (!$response->streaming()) {
          $kernel->post($response->getServerPoeId(), $response->getServerDoneEvent(), $response);
        }
        else {
          $poe_kernel->yield("stream_handler");
        }

        # this is it...
        return 1;
      },

      stream_handler => sub {
        $self->{stream_handler}(@_[ARG0 .. $#_]);
      },
    }
  );

  return 1;
}

sub _getVhost {
  my ($self, $host) = @_;
  return VHOST_DEFAULT;
}

# TODO: This metod should be implemented in a more
#       efficient way...
sub _getRequestHandlerKey {
  my ($self, $uri, $vhost) = @_;
  $uri   = "/"           unless (defined $uri);
  $vhost = VHOST_DEFAULT unless (defined $vhost);

  # no such virthost?
  return undef unless (exists($self->{_ctx}->{$vhost}));

  my @warr = ();

  my @uri_e = split(/\/+/, $uri);
  push(@uri_e, "") unless (@uri_e);
  my $uri_e_last = $#uri_e;

  my @arr = reverse(sort keys %{$self->{_ctx}->{$vhost}});

  #print STDERR "Handler lookup table:\n";
  #print STDERR "\t$uri\n\n";
  foreach (@arr) {

    # print STDERR "\t$_\n";
    my $e = [];
    @{$e} = split(/\/+/, $_);
    push(@{$e}, "") unless (@{$e});

    # shift(@{$e});
    push(@warr, $e);
  }

  #print STDERR "GOT: ", Dumper(\ @warr), "\n";

  my $max_pts = 0;
  my $key     = undef;

  # now compute points...
  my $last = $#warr;
  for (my $i = 0; $i <= $last; $i++) {
    my $pts = 0;

    for (my $j = 1; $j <= $#{$warr[$i]}; $j++) {
      last if ($j > $uri_e_last);

      #print "\t\tComparing: '$warr[$i]->[$j]' vs. '$uri_e[$j]': ";
      if ($warr[$i]->[$j] eq $uri_e[$j]) {

        #print "match.\n";
        $pts++;
      }
      else {

        #print "failure.\n";
        last;
      }
    }

    # exact match? double the points...
    if ($#{$warr[$i]} == $uri_e_last && $pts == $uri_e_last) {
      $pts *= 2;
    }

    # print STDERR "handler: ", join("/", @{$warr[$i]}), "; points: $pts\n";

    if ($pts >= $max_pts) {
      $max_pts = $pts;
      $key     = join("/", @{$warr[$i]});
      $key     = "/" unless (defined $key);
    }
  }

  if ($max_pts < 1) {
    $key = "/";
  }

  # print STDERR "Selected key for uri '$uri' : '$key' ($max_pts points)\n";
  return $key;
}

sub _getRequestHandler {
  my ($self, $uri, $vhost) = @_;
  $uri   = "/"           unless (defined $uri);
  $vhost = VHOST_DEFAULT unless (defined $vhost);
  $_log->debug("Computing request handler for path '$uri' on vhost '$vhost'.") if (DEBUG);

  # handler object/coderef...
  my $obj = undef;

  # get request handler key...
  my $key = $self->_getRequestHandlerKey($uri, $vhost);
  unless (defined $key) {
    $_log->debug("No request handler key was found.");
    return undef;
  }

  # create an object...
  $_log->debug("vhost: '$vhost'; key: '$key'") if (DEBUG);
  my $h     = $self->{_ctx}->{$vhost}->{$key};
  my $class = $h->{class};

  unless (defined $class && length($class) > 0) {
    $_log->debug("No request handler class was found for key '$key'.") if (DEBUG);
    return undef;
  }
  eval { $obj = $class->new(%{$h->{args}}); };

  if ($@) {
    $self->logError("Error creating handler object for uri '$uri' on vhost '$vhost': $@");
    return undef;
  }

  # where is this one mounted?
  $obj->{_mount_path} = $h->{uri};

  if (DEBUG) {
    no warnings;
    $_log->debug("Returning request handler: '$obj'");
  }

  return $obj;
}

sub _getHandlerKey {
  my ($self, $uri) = @_;

  # TODO: really compute handler key...
  return undef;
}

=head3 mount (LOTS_OF_STUFF) [POE]

Mounts new server context. Returns 

=cut

sub mount {
  my ($self, @args) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  my $num  = 0;
  my @opts = ();
  while (@args) {
    if (ref($args[0]) eq 'HASH') {
      push(@opts, shift(@args));
    }
    else {
      my %e = @args;
      @args = ();
      push(@opts, \%e);
    }
  }

  if (DEBUG) {
    if ($_log->is_debug()) {
      $_log->debug("Mount parameters: ", Dumper(\@opts));
    }
  }

  foreach my $e (@opts) {

    # check for struct validity...
    next unless (defined $e && ref($e) eq 'HASH');

    # check for uri
    next unless (exists($e->{uri}) && length($e->{uri}) > 0);

    # check struct validity...
    $e->{vhost} = VHOST_DEFAULT unless (exists($e->{vhost}) && defined($e->{vhost}));
    $e->{dont_load_handler} = 0 unless (exists($e->{dont_load_handler}));
    my $vhost = $e->{vhost};
    my $class = $e->{handler};
    next unless (defined $class);

    # no :: in handler name?
    # looks like our own handler...
    if ($class !~ m/::/) {
      $class = __PACKAGE__ . "::Handler::" . $class;
    }

    # should we try to load handler class?
    if (exists($e->{dont_load_handler}) && !$e->{dont_load_handler}) {

      # check if this class is already loaded...
      unless ($self->_loadClass($class)) {
        $self->logError($self->getError());
        next;
      }
    }

    my $desc = "";
    eval { $desc = $class->getDescription(); };

    # build context structure...
    my $x = {
      uri         => $e->{uri},
      handler     => $e->{handler},
      class       => $class,
      description => $desc,
      args        => $e->{args},
    };

    # add to context struct...
    $self->logError("Mounted server context: '$x->{uri}'.");
    $self->{_ctx}->{$vhost}->{$x->{uri}} = $x;

    $num++;
  }

  # print "CTX: ", Dumper($self->{_ctx}), "\n";
  $_log->debug("Mounted $num server context(s).") if (DEBUG);

  # $self->logError("Mounted $num server context(s).");

  return $num;
}

=head3 umount (uri => <uri>, vhost => <vhost>) [POE]

Umounts previously mounted server context.

=cut

sub umount {
  my ($self, %args) = (is_poe(\@_)) ? @_[OBJECT, ARG0 .. $#_] : @_;

  my $num = 0;

  my $uri   = $args{uri};
  my $vhost = $args{vhost};
  $vhost = VHOST_DEFAULT unless (defined $vhost);

  my $i = 0;
  foreach my $ctx (keys %{$self->{_ctx}->{$vhost}}) {
    if ($ctx eq $uri) {
      delete($self->{_ctx}->{$vhost}->{$ctx});
      $self->logError("Unmounted context: $ctx");
      $i++;
    }
  }

  return $i;
}

sub _loadClass {
  my ($self, $class) = @_;
  $_log->debug("Trying to load class: '$class'.") if (DEBUG);

  # check if it's in loaded classes array...
  foreach (@_loaded_classes) {
    if ($_ eq $class) {
      $_log->debug("Class '$class' is already loaded.") if (DEBUG);
      return 1;
    }
  }

  # no? try to load it...
  eval "require " . $class;

  if ($@) {
    $self->{_error} = "Error loading class '$class': $@";
    return 0;
  }

  # loading succeeded...
  push(@_loaded_classes, $class);
  return 1;
}

sub _fixMountArgs {
  my $self = shift;
  if (!exists($_[0]->{uri})) {
    $_[0]->{uri} = "/";
  }
}

sub __clientInput {
  my ($self, $kernel, $request, $wheel_id) = @_[OBJECT, KERNEL, ARG0, ARG1];
  $_log->debug("Client INPUT: $wheel_id") if (DEBUG);

  # $self->{_clients}->{$wheel_id}->[CL_WHEEL]->pause_input();

  # activity...
  $self->{_clients}->{$wheel_id}->[CL_REQ] = undef;

  #$self->{_clients}->{$wheel_id}->[CL_SMTIME] = time();
  $self->{_clients}->{$wheel_id}->[CL_NREQS]++;
  $self->_clientReset($wheel_id);

  if (DEBUG) {
    if ($_log->is_debug()) {
      $_log->debug("HTTP request:\n" . $request->as_string("\n"));
    }
  }

  # create response object...
  my $response = POE::Component::Server::HTTPEngine::Response->new($wheel_id);

  my $proto = undef;
  eval { $proto = $request->protocol(); };
  $response->protocol($proto);

  # set other important properties...
  # $response->{_server_poe_id} = $self->{_poe_session};
  # $response->{_server_event_done} = "DONE";

  # add ourselves to response object...
  $response->setServer($self);

  #$response->{_server} = $self;

  # do we have a valid request object?
  unless (defined $request && blessed($request) && $request->isa("HTTP::Request")) {
    $_log->debug("   Looks like bad request...") if (DEBUG);
    $response->setError("", $request->code(),
      HTTP::Status::status_message($request->code()) . "<br>" . htmlencode($request->content()));

    # don't waste precious time with this request...
    $kernel->yield("DONE", $response);
    return 1;
  }

  # do some stuff... on connections...
  $self->{_clients}->{$wheel_id}->[CL_CLOSE] = 0;

  # fix URI object...
  my $uri = $request->uri();

  # is listener, from which this request came from, sslfied?
  if ($self->{_clients}->{$wheel_id}->[CL_SSLFIED] == 1) {
    $uri->scheme("https");
  }
  else {
    $uri->scheme("http");
  }

  # hostname:port...
  my $host = $request->header("Host");
  if (defined $host) {
    $uri->host($host);
  }
  else {

    # no host? this is weird...
    # $uri->host($self->{server_name});
    my $srv_wheel = $self->{_clients}->{$wheel_id}->[CL_WHEEL_SRV];
    if (exists($self->{_listeners}->{$srv_wheel})) {
      $uri->host(
        $self->{_listeners}->{$srv_wheel}->[SR_IP] . ":" . $self->{_listeners}->{$srv_wheel}->[SR_PORT]);
    }
    else {
      warn "Unexisting server wheel: $srv_wheel";
    }
  }

  # $_log->debug("URI: ", Dumper($request->uri()));

  # Get the path
  my $path = join("/", $uri->path_segments());
  if (!defined $path || $path eq '') {
    $_log->debug("Request undefined path; fixing with '/'.") if (DEBUG);
    $path = "/";
    $uri->path($path);
  }

  my $x = $request->header("Connection");
  if (defined $x && $x =~ /close/i) {
    $response->header("Connection", "close");
  }

  # which vhost will handle this connection?
  my $vhost = $self->_getVhost($host);
  $vhost = VHOST_DEFAULT unless (defined $vhost);
  $response->vhost($vhost);

  $_log->debug("Request URI: ", Dumper($request->uri())) if (DEBUG);
  $_log->debug("Computed vhost: '$vhost'.") if (DEBUG);

  # add headers...
  $self->basicResponseHeaders($response);

  # get request handler object...
  my $handler = $self->_getRequestHandler($path, $vhost);

  # do we have a valid request handler?
  unless (defined $handler) {
    $response->setError($path, HTTP_NOT_FOUND,
      "No request handler is configured for URI: <b>" . htmlencode($path) . "</b>");

    # we're done with this request...
    $kernel->yield("DONE", $response);
    return 1;
  }

  # we have $request and we have a $handler...

  # does this request handler require authentication?
  if ($handler->authRequired()) {
    my $realm = $handler->authRealm();
    $_log->debug("Auth is REQUIRED for: $path; realm: $realm") if (DEBUG);

    # fetch credentials...
    my ($user, $pass) = $request->authorization_basic();

    # no credentials? inform the client
    unless (defined $user && defined $pass) {
      $response->header("WWW-Authenticate" => "Basic realm=\"$realm\"");
      $response->code(HTTP_UNAUTHORIZED);

      # send error message
      $response->setError($path, HTTP_UNAUTHORIZED, "$path :: authentication required.");
      $_log->debug("Client provided NO credentials.") if (DEBUG);
      return $kernel->yield(EVENT_DONE, $response);
    }

    # validate the credentials...
    unless ($self->_validateAuthCredentials($realm, $user, $pass)) {

      # not good? fuck off the client...
      $response->header("WWW-Authenticate" => "Basic realm=\"$realm\"");
      $response->setError($path, HTTP_UNAUTHORIZED, "$path: " . $self->getError());
      $_log->debug("Client provided INVALID credentials.") if (DEBUG);
      return $kernel->yield(EVENT_DONE, $response);
    }

    # inform object about authenticated state...
    $handler->authRealm($realm);
    $handler->authUser($user);
    $handler->authType("basic");
    $_log->debug("Username: '$user', pass: '$pass', realm: '$realm'.") if (DEBUG);
  }
  else {
    $_log->debug("Auth is not required for: $path") if (DEBUG);
  }

  # associate request object with client connection...
  $self->{_clients}->{$wheel_id}->[CL_REQ] = $request;

  # set various stuff to response object...
  $response->remote_ip($self->{_clients}->{$wheel_id}->[CL_IP]);
  $response->remote_port($self->{_clients}->{$wheel_id}->[CL_PORT]);
  $response->ssl($self->{_clients}->{$wheel_id}->[CL_SSLFIED]);
  $response->ssl_cipher($self->{_clients}->{$wheel_id}->[CL_SSLCIPH]);

  # spawn this request handler in it's own poe session
  my $session_id = $handler->spawn($self, $request, $response);

  $_log->debug("Handler ", ref($handler), " started in POE session: $session_id.") if (DEBUG);

  # store request handler session id...
  $self->{_clients}->{$wheel_id}->[CL_SESS] = $session_id;

  # this is it...
  return 1;
}

sub __clientFlushed {
  my ($self, $kernel, $wheel_id) = @_[OBJECT, KERNEL, ARG0];
  $_log->debug("[client $wheel_id]: client FLUSHED: $wheel_id.") if (DEBUG);
  unless (exists($self->{_clients}->{$wheel_id})) {
    $_log->debug("[client $wheel_id]: client wheel doesn't exist. BUG?") if (DEBUG);
    return 0;
  }

  # should we shutdown the client?
  if ($self->{_clients}->{$wheel_id}->[CL_CLOSE] == 1) {
    $_log->debug("[client $wheel_id]: Connection marked for closing; destroying connection.") if (DEBUG);
    return $self->_clientDestroy($wheel_id);
  }

  # is this connection marked as done?
  elsif ($self->{_clients}->{$wheel_id}->[CL_DONE] == 1) {
    $_log->debug("[client $wheel_id]: Connection marked as done; keeping connection '$wheel_id' alive.")
      if (DEBUG);
    $self->_keepalive($wheel_id);

    # $self->{_clients}->{$wheel_id}->[CL_WHEEL]->resume_input();
  }

  # streaming and we need to change output filter?
  if ($self->{_clients}->{$wheel_id}->[CL_STREAM] == 1) {
    if (defined $self->{_clients}->{$wheel_id}->[CL_FILTER]) {
      my $filter = $self->{_clients}->{$wheel_id}->[CL_FILTER];
      if (DEBUG) {
        $_log->debug("Client was flushed and filter change was requested: '$filter'");
        $_log->debug("Changing output filter.");
      }

      # $self->{_clients}->{$wheel_id}->[CL_WHEEL]->set_output_filter(POE::Filter::Stream->new());

      # undefine it...
      $self->{_clients}->{$wheel_id}->[CL_FILTER] = undef;
    }
  }

  # set time of last activity...
  $self->{_clients}->{$wheel_id}->[CL_SMTIME] = time();

  return 1;
}

sub _keepalive {
  my ($self, $wheel_id) = @_;
  $_log->debug("Startup.") if (DEBUG);
  unless ($self->{_clients}->{$wheel_id}->[CL_DONE]) {
    $_log->debug("[client $wheel_id]: Request on connection is not done yet.") if (DEBUG);
    return 0;
  }

  #$_log->debug("WHEEL BEFORE: ", Dumper($self->{_clients}->{$wheel_id}->[CL_WHEEL])) if (DEBUG);

  # reinit poe::filter::httpd object...
  $_log->debug("[client $wheel_id]: Reinitializing POE::Filter::HTTPD object...") if (DEBUG);
  $_log->debug("REF: ", ref($self->{_clients}->{$wheel_id}->[0]->[2])) if (DEBUG);

  $self->{_clients}->{$wheel_id}->[CL_WHEEL]->[2] = (ref($self->{_clients}->{$wheel_id}->[0]->[2]))->new();
  $self->{_clients}->{$wheel_id}->[CL_WHEEL]->set_output_filter(POE::Filter::HTTPD->new());

  #$_log->debug("WHEEL AFTER: ", Dumper($self->{_clients}->{$wheel_id}->[CL_WHEEL])) if (DEBUG);

  # mark connection no longer as "done"
  $self->{_clients}->{$wheel_id}->[CL_DONE] = 0;

  # mark connection no longer as "streamed"
  $self->{_clients}->{$wheel_id}->[CL_STREAM] = 0;

  return 1;
}

sub __clientError {
  my ($self, $kernel, $operation, $errnum, $errstr, $wheel_id) = @_[OBJECT, KERNEL, ARG0 .. ARG3];
  my $addr = $self->_getClientAddr($wheel_id);
  $_log->debug("[client $wheel_id]: ERROR: [$addr] (operation: $operation; errnum: $errnum; $errstr)")
    if (DEBUG);

  # was this really an error?
  if ($errnum != 0) {
    $_log->debug("Wheel $wheel_id [$addr] got error while performing syscall $operation: $errnum $errstr")
      if (DEBUG);
  }

  # destroy the wheel...
  $self->_clientDestroy($wheel_id);
}

sub __clientCleanup {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  my $idle_s
    = (($self->{keepalive} && $self->{keepalive_timeout} < TIMEOUT_IDLE_CLIENT))
    ? $self->{keepalive_timeout}
    : TIMEOUT_IDLE_CLIENT;
  my $idle_s_orphan = $idle_s + 10;

  # $_log->debug("__clientCleanup(): looking for stalled clients (timeout: $idle_s seconds).");
  my $cur_time = time();

  # check all connections
  my $num = 0;
  foreach my $wheel_id (keys %{$self->{_clients}}) {

    # undefined stuff? we have an orphan...
    unless (defined $self->{_clients}->{$wheel_id}->[CL_WHEEL]) {
      $_log->warn("[client $wheel_id]: cleaning up orphaned client.") if (DEBUG);
      $self->_clientDestroy($wheel_id);
      next;
    }

    # destroy the socket if nothing happened on
    # on it for $self->{keepalive_timeout} seconds?
    if ($self->{_clients}->{$wheel_id}->[CL_DONE] == 1) {

      # client is served, but connection is stil alive...
      if ($cur_time >= ($self->{_clients}->{$wheel_id}->[CL_SMTIME] + $idle_s)) {
        $_log->warn("[client $wheel_id]: Destroying too long lived keep-alive connection.") if (DEBUG);
        $self->_clientDestroy($wheel_id);
        $num++;
      }
    }
    else {
      if ($cur_time >= ($self->{_clients}->{$wheel_id}->[CL_SMTIME] + $idle_s_orphan)) {
        $_log->warn(
          "[client $wheel_id]: Destroying too long lived un-served connection. This is probably a bug in URI handler."
        ) if (DEBUG);
        $self->_clientDestroy($wheel_id);
        $num++;
      }
    }
  }

  if ($num > 0) {
    $_log->debug("Removed $num client connection(s).") if (DEBUG);
  }

  # reinstall ourselves...
  $kernel->delay("__clientCleanup", $self->{check_interval});
}

sub _getClientAddr {
  my ($self, $wheel_id) = @_;
  my ($ip, $port) = (undef, undef);

  if (defined $wheel_id && exists($self->{_clients}->{$wheel_id})) {
    $ip   = $self->{_clients}->{$wheel_id}->[CL_IP];
    $port = $self->{_clients}->{$wheel_id}->[CL_PORT];
  }

  if (wantarray()) {
    return ($ip, $port);
  }
  else {
    if (defined $ip) {
      return "$ip:$port";
    }
    else {
      return undef;
    }
  }
}

sub _getConnector {
  my ($self, $wheel_id) = @_;
  my ($addr, $port, $ipv6) = (undef, undef, undef);

  if (defined $wheel_id && exists($self->{_listeners}->{$wheel_id})) {
    $addr = $self->{_listeners}->{$wheel_id}->[SR_IP];
    $port = $self->{_listeners}->{$wheel_id}->[SR_PORT];
    $ipv6 = $self->{_listeners}->{$wheel_id}->[SR_IPV6];
  }

  return ($addr, $port, $ipv6);
}

sub _clientDestroy {
  my ($self, $wheel_id) = @_;
  if (defined $wheel_id && exists($self->{_clients}->{$wheel_id})) {
    my $addr = "";
    {
      no warnings;
      $addr = sprintf("[%s:%d]", $self->{_clients}->{$wheel_id}->[CL_IP],
        $self->{_clients}->{$wheel_id}->[CL_PORT]);
    }

    if (DEBUG) {
      $_log->debug("[client $wheel_id]: destroying client wheel ($addr).");
    }

    # destroy the reference...
    delete($self->{_clients}->{$wheel_id});
    $self->{_num_clients}--;
    return 1;
  }

  return 0;
}

sub _clientDestroyAll {
  my $self = shift;
  $_log->debug("Destroying all clients") if (DEBUG);
  map { $self->_clientDestroy($_); } keys %{$self->{_clients}};

  return 1;
}

sub _clientReset {
  my ($self, $wheel_id) = @_;
  return 0 unless (exists($self->{_clients}->{$wheel_id}));

  $_log->debug("Reset client's wheel metadata: $wheel_id.") if (DEBUG);

  if (defined $self->{_clients}->{$wheel_id}->[CL_WHEEL]) {
    $self->{_clients}->{$wheel_id}->[CL_WHEEL]->set_output_filter(POE::Filter::HTTPD->new());
  }

  $self->{_clients}->{$wheel_id}->[CL_DONE]   = 0;
  $self->{_clients}->{$wheel_id}->[CL_SMTIME] = time();
  $self->{_clients}->{$wheel_id}->[CL_STREAM] = 0;
  $self->{_clients}->{$wheel_id}->[CL_SESS]   = -1;
  $self->{_clients}->{$wheel_id}->[CL_CLOSE]  = 0;

  # $self->{_clients}->{$wheel_id}->[CL_REQ] = undef;
  $self->{_clients}->{$wheel_id}->[CL_FILTER]  = undef;
  $self->{_clients}->{$wheel_id}->[CL_CHUNKED] = 0;

  return 1;
}

sub _checkResponseObj {
  my ($self, $obj, $operation) = @_;
  $operation = "<undefined operation>" unless (defined $operation);

  # check response object...
  unless (defined $obj && blessed($obj) && $obj->isa(__PACKAGE__ . "::Response")) {
    $_log->debug("$operation: invalid response object.");
    return 0;
  }

  # check wheel id
  #my $wheel_id = $obj->getWheelID();
  my $wheel_id = $obj->wheel();
  unless (defined $wheel_id) {
    $_log->debug("$operation: undefined wheel_id. This is weird.") if (DEBUG);
    return 0;
  }

  # seems ok, return wheel id...
  return $wheel_id;
}

# stream content to the client
sub STREAM {
  my ($self, $kernel, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # do we have a valid http::response-like object?
  unless (defined $response && ref($response) && $response->isa("HTTP::Response")) {
    no warnings;
    $_log->warn("GOT bad HTTP response object: '$response'.") if (DEBUG);
    return 0;
  }

  # check response object..
  my $wheel_id = $self->_checkResponseObj($response, "STREAM");

  #return 0 unless ($wheel_id);

  # content length...
  my $len = 0;
  { no warnings; $len = length($response->content()); }
  $response->addBytes($len);

  # is client ok?
  if (!defined $self->{_clients}->{$wheel_id}->[CL_WHEEL]) {
    $_log->error("[client $wheel_id]: invalid client wheel id (socket closed?).") if (DEBUG);
    $_log->error("[client $wheel_id]: shutting down calling session: ", $_[SENDER]->ID()) if (DEBUG);
    $kernel->call($_[SENDER]->ID(), "shutdown");
    $self->_clientDestroy($wheel_id);
    return 0;
  }

  # is streaming started?
  if (!$self->{_clients}->{$wheel_id}->[CL_STREAM]) {

    # nope, we need to start it...
    $_log->debug("[client $wheel_id]: Starting STREAMING.") if (DEBUG);

    # do we have content-length response header?
    if (defined $response->header("Content-Length")) {

      # nope! deal with the situation...
    }
    else {
      if (lc($response->protocol()) eq 'http/1.1') {
        $_log->debug("[client $wheel_id]: Content-Length is not set, setting Transfer-Encoding to 'chunked'.")
          if (DEBUG);
        $response->header('Transfer-Encoding', 'chunked');
        $self->{_clients}->{$wheel_id}->[CL_CHUNKED] = 1;
      }
      else {
        $_log->debug(
          "[client $wheel_id]: Content-Length is not set, not a HTTP/1.1 request, setting Connection to 'close'."
        ) if (DEBUG);
        $response->header("Connection", "close");
      }
    }

    # fix headers...
    $self->_fixResponseHeaders($response, 1);

    # content-length and connection=close?
    # TODO: remove
    my $cn = $response->header("Connection");
    if (defined $response->header("Content-Length") && defined $cn && lc($cn) eq 'close') {
      $response->remove_header("Content-Length");
    }

    # compress content?
    my $compress = 0;
    if (HAVE_ZLIB) {

      # streamed request requires Transfer-Encoding == chunked, which
      # requires protocol HTTP/1.1
      if (lc($response->protocol()) eq 'http/1.1'
        && $self->_compressResponse($self->{_clients}->{$wheel_id}->[CL_REQ], $response))
      {
        $compress = 1;
        $_log->debug("STREAM COMPRESS: will compress streamed response.") if (DEBUG);
        $response->header("Content-Encoding", "deflate");
        $response->header("Vary",             "Accept-Encoding");

        $_log->debug("STREAM COMPRESS: Setting Transfer-Encoding to 'chunked'.") if (DEBUG);
        $response->header('Transfer-Encoding', 'chunked');
        $self->{_clients}->{$wheel_id}->[CL_CHUNKED] = 1;

        $_log->debug("STREAM COMPRESS: Removing Content-Length header.") if (DEBUG);
        $response->remove_header("Content-Length");
      }
    }

    # we're now streaming
    $self->{_clients}->{$wheel_id}->[CL_STREAM] = 1;

    # set streaming output handler...
    $self->{_clients}->{$wheel_id}->[CL_WHEEL]->set_output_filter(POE::Filter::Stream->new());

    # write headers!
    my $h_str = $response->protocol() . " " . $response->status_line() . "\r\n";
    $response->scan(
      sub {
        $h_str .= "$_[0]: $_[1]\r\n";
      }
    );

    if (DEBUG) {
      if ($_log->is_debug()) {
        $_log->debug("[client $wheel_id]: Response headers:");
        $_log->debug("--- BEGIN HEADERS ---");
        $_log->debug("\n" . $h_str);
        $_log->debug("--- END HEADERS ---");
      }
    }

    # terminate header string
    $h_str .= "\r\n";

    $self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($h_str);

    # are we in chunked mode and content-length > 0?
    # send first transfer-encoding=chunked data chunk :)
    if ($len > 0) {
      if ($compress) {
        $_log->debug("STREAM COMPRESS: Headers were sent. Flushing output.") if (DEBUG);
        eval { $self->{_clients}->{$wheel_id}->[CL_WHEEL]->flush(); };

        # initialize deflate engine
        unless ($self->_deflateStreamInit($wheel_id)) {
          return $kernel->yield("CLOSE", $response);
        }
      }

      # send content-body
      if ($self->{_clients}->{$wheel_id}->[CL_CHUNKED]) {
        my $chunk = "";
        if ($compress) {
          my $compressed_content = $self->_deflateStreamCompress($wheel_id, $response->content());
          unless (defined $compressed_content) {
            return $kernel->yield("CLOSE", $response);
          }
          $len = length($compressed_content);
          $chunk = sprintf("%x\r\n", $len);
          $chunk .= $compressed_content;
          $chunk .= "\r\n";
        }
        else {
          $chunk = sprintf("%x\r\n", $len);
          $chunk .= $response->content();
          $chunk .= "\r\n";
        }

        if ($len > 0) {
          if (DEBUG) {
            if ($_log->is_debug()) {
              $_log->debug("[client $wheel_id]: STREAMing $len bytes of "
                  . (($compress) ? "compressed" : "")
                  . " chunked data");
            }
          }
          $self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($chunk);
        }
      }
      else {
        $self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($response->content());
      }
    }
  }
  else {

    # chunked transfer encoding?
    if ($self->{_clients}->{$wheel_id}->[CL_CHUNKED]) {

=pod
			my $chunk = sprintf("%x\r\n", $len);
			$chunk .= $response->content();
			$chunk .= "\r\n";
			if (DEBUG) {
				if ($_log->is_debug()) {
					$_log->debug("[client $wheel_id]: streaming $len bytes of chunked data.");
				}
			}
			$self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($chunk);
=cut

      my $chunk = "";
      my $compress = (defined $self->{_clients}->{$wheel_id}->[CL_DEFLATE]) ? 1 : 0;
      if ($compress) {
        my $compressed_content = $self->_deflateStreamCompress($wheel_id, $response->content());
        unless (defined $compressed_content) {
          return $kernel->yield("CLOSE", $response);
        }
        $len = length($compressed_content);
        $chunk = sprintf("%x\r\n", $len);
        $chunk .= $compressed_content;
        $chunk .= "\r\n";
      }
      else {
        $chunk = sprintf("%x\r\n", $len);
        $chunk .= $response->content();
        $chunk .= "\r\n";
      }

      if ($len > 0) {
        if (DEBUG) {
          if ($_log->is_debug()) {
            $_log->debug("[client $wheel_id]: STREAMing $len bytes of "
                . (($compress) ? "compressed" : "")
                . " chunked data");
          }
        }
        $self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($chunk);
      }

    }
    else {
      $_log->debug("[client $wheel_id]: streaming $len bytes of data.") if (DEBUG);
      $self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($response->content());
    }
  }

outta_stream:

  # call back original session??
  if ($response->_callback()) {
    my $session = $response->_callbackSession();
    my $event   = $response->_callbackEvent();

    $_log->debug("[client $wheel_id]: Calling back POE streaming handler: '$session:$event'.") if (DEBUG);
    my $r = 0;

    # poco::server:simplehttp?
    if ($response->_callbackStreamTypeIsSimpleHTTP()) {
      $r = $kernel->post($session, $event, $response);
    }
    else {

      # poco::server:http...
      my $request = $self->{_clients}->{$wheel_id}->[CL_REQ];
      $r = $kernel->post($session, $event, $request, $response);
    }

    # post failed?
    unless ($r) {
      $_log->debug("[client $wheel_id]: Error calling back streaming handler '$session:$event': $!")
        if (DEBUG);
      $_log->debug("[client $wheel_id]: Closing connection.") if (DEBUG);

      # $kernel->yield("CLOSE", $response);
      $self->_clientDestroy($wheel_id);
      return 0;
    }
  }

  return 1;
}

# forcibly shutdown the request...
sub CLOSE {
  my ($self, $kernel, $response) = @_[OBJECT, KERNEL, ARG0];

  # $_log->debug("CLOSE: startup.") if (DEBUG);

  # check response object..
  my $wheel_id = $self->_checkResponseObj($response, "CLOSE");
  return 0 unless ($wheel_id);

  # check if client has any bytes left to write...
  if (defined $self->{_clients}->{$wheel_id}->[CL_WHEEL]) {
    my $pending = $self->{_clients}->{$wheel_id}->[CL_WHEEL]->get_driver_out_octets();
    if ($pending > 0) {
      $_log->debug(
        "[client $wheel_id]: client has still $pending bytes in output buffer, will close the socket after flush."
      ) if (DEBUG);
      $self->{_clients}->{$wheel_id}->[CL_CLOSE] = 1;
      return 1;
    }
  }

  $_log->debug("[client $wheel_id]: CLOSE: forcibly closing client.") if (DEBUG);
  $self->_clientDestroy($wheel_id);

  # perform logging...
  $self->logAccess($response);

  return 1;
}

# mark request as done
sub DONE {
  my ($self, $kernel, $response) = @_[OBJECT, KERNEL, ARG0];

  # check response object..
  my $wheel_id = $self->_checkResponseObj($response, "DONE");
  return 0 unless ($wheel_id);

  $_log->debug("[client $wheel_id]: Request handler is DONE handling URL request.") if (DEBUG);

  # check wheel validity...
  if (!$self->{_clients}->{$wheel_id}->[CL_WHEEL]) {
    $_log->error("[client $wheel_id]: wheel disappeared!") if (DEBUG);
    $self->_clientDestroy($wheel_id);
    return 0;
  }

  # was DONE event already sent?
  if ($self->{_clients}->{$wheel_id}->[CL_DONE] == 1) {
    warn "[client $wheel_id]: DONE event was already sent using the same response object!";
    $kernel->yield("CLOSE", $response);
    return 0;
  }

  # perform error logging...
  my $code = $response->code();
  if (!defined $code) {
    $self->logError("No HTTP status code defined in response object.", $response);
  }
  elsif ($code < 200 || $code >= 399) {

    # some error...
  }

  # did this client connection exceed maximum number of
  # keepalive requests?
  if ($self->{keepalive} && $self->{_clients}->{$wheel_id}->[CL_NREQS] >= $self->{keepalive_num}) {
    $_log->debug("[client $wheel_id]: connection exceeded keepalive request limit '$self->{keepalive_num}' = "
        . $self->{_clients}->{$wheel_id}->[CL_NREQS])
      if (DEBUG);
    $response->header("Connection", "close");
  }

  # fix headers...
  $self->_fixResponseHeaders($response);

  # should we keep this connection alive?
  my $conn_str   = $response->header("Connection");
  my $c_len      = $response->header("Content-Length");
  my $tx_enc     = $response->header("Transfer-Encoding");
  my $keep_alive = (

    # Connection: header should not be set to 'close'
    (!defined $conn_str || $conn_str !~ m/close/) &&

      # HTTP/1.1 protocol with content-type or with content-encoding header
      # lc($response->protocol()) eq 'http/1.1' &&

      # Response must have headers Content-Length or Transfer-Encoding=chunked
      ((defined $c_len) || (defined $tx_enc && $tx_enc eq 'chunked'))
  ) ? 1 : 0;

  # Keep-Alive support.... Should we keep this connection alive?
  if ($keep_alive) {
    $_log->debug(
      "[client $wheel_id]: connection will be kept alive for $self->{keepalive_timeout} second(s).")
      if (DEBUG);
  }
  else {

    # connection should be closed ASAP.
    $self->{_clients}->{$wheel_id}->[CL_CLOSE] = 1;

    # $response->header("Connnection", "close");
    # $response->remove_header("Keep-Alive");
    $_log->debug("[client $wheel_id]: connection will be closed at the next wheel flush.") if (DEBUG);
  }

  # is this STREAM-ed request?
  if ($self->{_clients}->{$wheel_id}->[CL_STREAM] == 1) {

    # we need to push only content-body,
    # headers should be already sent by the event STREAM

    $_log->debug("[client $wheel_id]: stream is done.") if (DEBUG);

    # Is this Transfer-Encoding == "chunked" stream?
    if ($self->{_clients}->{$wheel_id}->[CL_CHUNKED]) {
      my $compress = (defined $self->{_clients}->{$wheel_id}->[CL_DEFLATE]) ? 1 : 0;
      if ($compress) {

        # shutdown the deflate engine (something may still be in buffer)
        my $compressed_data = $self->_deflateStreamDone($wheel_id);
        unless (defined $compressed_data) {
          return $kernel->yield("CLOSE", $response);
        }
        my $len = length($compressed_data);

        my $chunk = "";
        if ($len > 0) {
          $chunk = sprintf("%x\r\n", $len);
          $chunk .= $compressed_data;
          $chunk .= "\r\n";
        }

        $_log->debug(
          "[client $wheel_id]: Compress buffer contained $len bytes of data. Streaming and sending last terminating chunk."
        ) if (DEBUG);

        # add terminating chunk
        $chunk .= "0\r\n\r\n";
        $self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($chunk);
      }
      else {
        my $chunk = "0\r\n\r\n";
        $_log->debug("[client $wheel_id]: Transfer-Encoding is chunked; sending last, terminating chunk.")
          if (DEBUG);
        $self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($chunk);
      }
      $self->{_clients}->{$wheel_id}->[CL_CHUNKED] = 0;
    }
    else {
      eval { $self->{_clients}->{$wheel_id}->[CL_WHEEL]->flush(); };
    }

    # this is no longer streaming request...
    $self->{_clients}->{$wheel_id}->[CL_STREAM] = 0;

    # this is non-STREAMed request
  }
  else {

    # is compression available?
    if (HAVE_ZLIB) {
      if ($self->_compressResponse($self->{_clients}->{$wheel_id}->[CL_REQ], $response)) {
        $_log->debug(
          "[client $wheel_id]: Will compress response with content type: " . $response->content_type())
          if (DEBUG);

        # get compressed content
        my $compressed_content = $self->_deflateCompress($response->content());
        if (defined $compressed_content) {
          my $len = length($compressed_content);
          $response->content_length($len);
          $response->header("Content-Encoding", "deflate");
          $response->header("Vary",             "Accept-Encoding");
          $response->content($compressed_content);
        }
        else {
          $self->logError("Error compressing output content: " . $self->getError());
        }
      }
    }

    $self->{_clients}->{$wheel_id}->[CL_WHEEL]->put($response);

    # calculate content length
    my $len = 0;
    { no warnings; $len = length($response->content()); }
    $response->addBytes($len);

    # $_log->debug("DONE [client $wheel_id]: Adding $len bytes to output queue.");
  }

  # perform access logging...
  $self->logAccess($response);

  # reset client...
  $self->{_clients}->{$wheel_id}->[CL_DONE]   = 1;
  $self->{_clients}->{$wheel_id}->[CL_SMTIME] = time();

  return 1;
}


sub _compressResponse {
  my ($self, $request, $response) = @_;
  return 0 unless (HAVE_ZLIB);

  # does response contain Content-Encoding header?
  # don't do anything if it does...
  my $ce = $response->header("Content-Encoding");
  return 0 if (defined $ce);

  # does the client support compressed content?
  my $ae = undef;
  $ae = $request->header("Accept-Encoding") if (defined $request);

  # we support only deflate compression...
  return 0 unless (defined $ae && $ae =~ m/deflate/);

  # check if response content type is ok...
  my $ct = $response->content_type();
  unless (defined $ct) {
    $ct = CONTENT_TYPE_DEFAULT;
    $response->content_type($ct);
  }

  # TODO: this should be implemented in a more efficient manner!
  foreach (@{$self->{compress_content_types}}) {
    return 1 if ($ct =~ m/$_/);
  }

  return 0;
}

sub _deflateStreamInit {
  my ($self, $wheel_id) = @_;
  unless (HAVE_ZLIB) {
    $_log->warn("ZLIB is not available.") if (DEBUG);
    return 0;
  }

  if (defined $self->{_clients}->{$wheel_id}->[CL_DEFLATE]) {
    $_log->debug("Deflate object is already initialized.") if (DEBUG);
    return 0;
  }

  # initialize deflate engine
  # Z_BEST_COMPRESSION == 9
  my ($d, $s) = Compress::Zlib::deflateInit(-Level => 9,);

  # Z_OK == 0
  unless (defined $d && $s == 0) {
    $self->logError("Error initializing deflate engine: $s");
    $_log->error("Error initializing deflate engine: $s") if (DEBUG);
    return 0;
  }

  # save object
  $self->{_clients}->{$wheel_id}->[CL_DEFLATE] = $d;
  return 1;
}

sub _deflateStreamCompress {
  my ($self, $wheel_id, $data) = @_;
  unless (HAVE_ZLIB) {
    $_log->warn("ZLIB is not available.") if (DEBUG);
    return undef;
  }
  unless (defined $self->{_clients}->{$wheel_id}->[CL_DEFLATE]) {
    $_log->error("Deflate engine is not initialized.") if (DEBUG);
    return undef;
  }

  # compress the data...
  my ($r, $s) = $self->{_clients}->{$wheel_id}->[CL_DEFLATE]->deflate($data);

  # Z_OK == 0
  unless ($s == 0) {
    $self->logError("Error compressing deflate buffer: $s");
    $r = undef;
  }

  return $r;
}

sub _deflateStreamDone {
  my ($self, $wheel_id) = @_;
  unless (HAVE_ZLIB) {
    $_log->warn("ZLIB is not available.") if (DEBUG);
    return undef;
  }

  unless (defined $self->{_clients}->{$wheel_id}->[CL_DEFLATE]) {
    $_log->error("Deflate engine is not initialized.") if (DEBUG);
    return undef;
  }

  # flush deflate object...
  # Z_FINISH == 4
  my ($r, $s) = $self->{_clients}->{$wheel_id}->[CL_DEFLATE]->flush(4);

  # Z_OK == 0
  unless ($s == 0) {
    $self->logError("Error flushing deflate buffer: $s");
    $r = undef;
  }

  # destroy deflate object...
  $self->{_clients}->{$wheel_id}->[CL_DEFLATE] = undef;

  return $r;
}

sub _deflateCompress {
  my ($self, $data) = @_;

  # compressed content
  my $compressed = undef;

  # initialize compression engine
  # Z_BEST_COMPRESSION == 9
  my ($deflate, $status) = Compress::Zlib::deflateInit(-Level => 9,);

  if (defined $deflate && $status == 0) {

    # compress data...
    ($compressed, $status) = $deflate->deflate($data);
    unless ($status == 0) {
      $self->logError("Error deflating content: $status");
      return undef;
    }

    # flush compression object...
    # Z_FINISH == 4
    ($compressed, $status) = $deflate->flush(4);

    # Z_OK == 0
    unless ($status == 0) {
      $self->logError("Error flushing deflate buffer: $status");
      return undef;
    }

    if (DEBUG) {
      my $len_before = length($data);
      my $len_after  = length($compressed);
      $_log->debug("Compressed/uncompressed content length: $len_before/$len_after bytes.");
    }
  }
  else {
    $self->logError("Error initializing zlib compression engine: $status");
  }

  return $compressed;
}

sub _fixResponseHeaders {
  my ($self, $response, $streamed) = @_;
  $streamed = 0 unless (defined $streamed);

  # add user's custom headers...
  map {
    $_log->debug("Adding custom header '$_' => '$self->{header}->{$_}'.") if (DEBUG);
    $response->header($_, $self->{header}->{$_});
  } keys %{$self->{headers}};

  # server?
  unless ($response->header("Server")) {
    if (defined $self->{server_string}) {
      $_log->debug("No Server header, fixing.") if (DEBUG);
      $response->header("Server", $self->{server_string});
    }
  }

  # content-type?
  unless ($response->header("Content-Type")) {
    $_log->debug("No Content-Type header, fixing.") if (DEBUG);
    $response->header("Content-Type", $self->{default_content_type});
  }

  # content-length?
  if (!defined $response->header("Content-Length")) {
    if ($streamed) {

      # streamed connection?
      my $te = $response->header("Transfer-Encoding");
      unless (defined $te && lc($te) eq 'chunked') {
        $_log->debug("No Content-Length header in streamed request, fixing.") if (DEBUG);
        $response->header("Content-Length", length($response->content()));
      }
    }
    else {

      # unstreamed connection? content-length should be always set!
      $_log->debug("No Content-Length header in non-streamed request, fixing.") if (DEBUG);
      $response->header("Content-Length", length($response->content()));
    }
  }

  # connection?
  if (!defined $response->header("Connection")) {
    $_log->debug("No Connection header, fixing.") if (DEBUG);
    $response->header("Connection", "keep-alive");
    $response->header("Keep-Alive", "timeout=$self->{keepalive_timeout}, max=$self->{keepalive_num}");
  }

  # Date header should be always set...
  $response->header("Date", HTTP::Date::time2str());

  # Code?
  unless (defined $response->code()) {
    $_log->warn("Handler didn't defined HTTP status code, fixing with: " . HTTP_OK . ".") if (DEBUG);
    $response->code(HTTP_OK);
  }

  return 1;
}

sub basicResponseHeaders {
  my ($self, $response) = @_;

  foreach (keys %{$self->{headers}}) {
    $response->header($_, $self->{headers}->{$_});
  }

  return 0;
}

sub getEventDONE {
  return EVENT_DONE;
}

sub getEventCLOSE {
  return EVENT_CLOSE;
}

sub getEventSTREAM {
  return EVENT_STREAM;
}

sub getServerString {
  my ($self) = @_;
  return $self->{server_string};
}

sub getServerSignature {
  my ($self) = @_;
  return
      "<b>"
    . $self->getServerString()
    . "</b> running on host <b>"
    . hostname()
    . "</b> @ "
    . strftime("%Y/%m/%d %H:%M:%S", localtime(time()));
}

sub getNumClients {
  my ($self) = @_;
  return scalar(keys %{$self->{_clients}});
}

sub getMaxClients {
  my ($self) = @_;
  return $self->{max_clients};
}

sub getHTTPErrorString {
  my ($self, $uri, $code, $message) = @_;
  $uri     = "<undefined_uri>"         unless (defined $uri);
  $code    = HTTP_SERVICE_UNAVAILABLE  unless (defined $code);
  $message = "undefined error message" unless (defined $message);
  $message = htmlencode($message);

  my $msg = HTTP::Status::status_message($code);
  my $sig = $self->getServerSignature();

  my $str = <<EOT
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
<title>Error $code: $uri</title>
<style type="text/css">
a, a:active {text-decoration: none; color: blue;}
a:visited {color: #48468F;}
a:hover, a:focus {text-decoration: underline; color: red;}
body {background-color: #F5F5F5;}
h2 {margin-bottom: 12px;}
table {margin-left: 12px;}
th, td { font: 90% monospace; text-align: left;}
th { font-weight: bold; padding-right: 14px; padding-bottom: 3px;}
td {padding-right: 14px;}
td.s, th.s {text-align: right;}
div.list { background-color: white; border-top: 1px solid #646464; border-bottom: 1px solid #646464; padding-top: 10px; padding-bottom: 14px;}
div.foot { font: 90% monospace; color: #787878; padding-top: 4px;}
</style>
</head>
<body>
<h2>Error $code: $msg</h2>
<div class="list">
<table summary="Error details" cellpadding="0" cellspacing="0">
<thead>
	<tr>
		<th class="n">Error Details:</th>
	</tr>
</thead>
<tbody>
<tr>
	<td class="n">
		<pre>$message</pre>
	</td>
	</tr>
</tbody>
</table>
</div>
<div class="foot">$sig</div>
</body>
</html>
EOT
    ;
  return $str;
}

sub __sigh_CHLD {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  warn "SIGCHLD: ", join(", ", @_[ARG0 .. $#_]), "\n";

  $kernel->sig_handled();
}

sub htmlencode {
  shift if ($_[0] eq __PACKAGE__);
  my $str = shift;

  $str =~ s/</&lt;/g;
  $str =~ s/>/&gt;/g;

  $str =~ s/&lt;(\/?br)&gt;/<$1>/gmi;
  $str =~ s/&lt;(\/?b)&gt;/<$1>/gmi;

  return $str;
}

# slightly modified Server_SSLify() taken from POE::Component::SSLify
sub my_server_sslify {

  # Get the socket & ssl context!
  my $socket = shift;
  my $ctx    = shift;

  # Validation...
  if (!defined $socket) {
    die "Did not get a defined socket";
  }

  # If we don't have a ctx ready, we can't do anything...
  if (!defined $ctx) {
    die 'Did not get a valid SSL context!';
  }

  # Set blocking on
  $socket = POE::Component::SSLify::Set_Blocking($socket);

  # Now, we create the new socket and bind it to our subclass of Net::SSLeay::Handle
  my $newsock = gensym();
  tie(*$newsock, 'POE::Component::SSLify::ServerHandle', $socket, $ctx)
    or die "Unable to tie to our subclass: $!";

  # All done!
  return $newsock;
}

# tries to authenticate supplied credentials...
sub _validateAuthCredentials {
  my ($self, $realm, $user, $pass) = @_;

  #unless (defined $realm && defined $user && defined $pass) {
  #	$self->{_error} = "Incomplete credentials.";
  #	return 0;
  #}

  # validate password...
  my $r = 0;
  $r = $poe_kernel->call("AUTHENTICATOR", "auth", $user, $pass);

=pod
	if ($user eq 'test' && $pass eq 'njami') {
		return 1;
	}
=cut

  # bad, bad, bad
  $self->{_error} = "Invalid credentials.";
  return $r;
}

sub real_debug {
  use Time::HiRes qw(time gettimeofday);
  no warnings;
  my ($seconds, $microseconds) = gettimeofday();
  my $t     = "[" . strftime("%Y/%m/%d %H:%M:%S,", localtime($seconds)) . $microseconds . "]";
  my $s_str = $poe_kernel->get_active_session()->ID();
  my $e_str = $poe_kernel->get_active_event();
  print STDERR "$t ", sprintf("%-45.45s ", "$s_str|$e_str"), join("", @_), "\n";
}

sub is_poe {
  no warnings;
  return (defined($_[0]->[KERNEL]) && $_[0]->[KERNEL] == $poe_kernel) ? 1 : 0;
}

sub _log4j_init {

  # no debugging?
  return 0 unless (DEBUG);

  # try to load log4perl
  eval "require Log::Log4perl";
  if ($@) {
    print STDERR "Unable to enable log4perl debugging: Log::Log4perl is not installed.\n";
    exit 1;
  }

  # log4perl logger configured?
  unless (Log::Log4perl->initialized()) {
    print STDERR "DEBUG: Log::Log4perl is not initialized, configuring it with built-in configuration.\n";
    my $log_config_str = q(
			log4j.rootLogger=ALL,Console
			
			# appenders...
			log4perl.appender.Console          = Log::Log4perl::Appender::Screen
			log4perl.appender.Console.stderr   = 1
			log4perl.appender.Console.layout   = Log::Log4perl::Layout::PatternLayout
			log4perl.appender.Console.layout.ConversionPattern   = [%d{DATE}] [%P] %-7.7p: %F{1}, line %-4.4L: %M{1}(): %m%n
		);

    # configure log4perl...
    eval { Log::Log4perl->init(\$log_config_str); };

    if ($@) {
      print STDERR "Log4perl initialization failed: $@\n";
    }
  }

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE::Component::Server::HTTPEngine::Request>
L<POE::Component::Server::HTTPEngine::Response>
L<POE::Component::Server::HTTPEngine::Handler>
L<POE::Component::Server::HTTPEngine::Handler::ExampleSimple>
L<POE::Component::Server::HTTPEngine::Handler::ExampleComplex>

=cut

1;
