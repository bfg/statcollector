package ACME::Util::PoeDNS;

use strict;
use warnings;

use IO::File;
use Net::DNS::Packet;
use Net::DNS::Resolver;
use Scalar::Util qw(blessed);

use POE;
use ACME::Util::PoeSession;

use base qw(ACME::Util::PoeSession);

use constant REFCOUNT_KEY    => 'x';
use constant TIMEOUT_DEFAULT => 30.0;

our $VERSION = 0.10;
my $_singleton    = undef;
my $_singleton_tm = TIMEOUT_DEFAULT;

=head1 ACME::Util::PoeDNS

Simple (A and AAAA only) POE based async DNS resolver

=head1 SYNOPSIS

 # get session (uses singleton pattern)
 $resolver_session_id = ACME::Util::PoeDNS->spawn();

 sub sendRequest { 	
 	# create resolver question
 	%question = (
 		host => "www.najdi.si",
 		event => "handleResponse",
 	);
 	
 	# send question to resolver
 	$poe_kernel->yield(
 		$resolver_session_id,
 		'resolve',
 		%question
 	);
 }
 
 sub handleResponse {
 	my ($kernel, $r) = @_[KERNEL, ARG0];
 	
 	print "Resolving of ", $r->{host}, " was ", (($r->{ok}) ? "success" : "failure"), "\n";
 	unless ($r->{ok}) {
 		print "Resolver error: ", $r->{error}, "\n";
 	} 
 	print "Resolved addresses: ", join(", ", @{$r->{result}}), "\n";
 }

=head1 DESCRIPTION

This is L<POE> based async resolver with minimalistic interface
and functionality - it is able to resolve only A, AAAA and PTR records. Transparent
support for hosts file is also available.

=head1 SINGLETON

This class can be used in two different ways:

=over

=item Singleton

Only one object instance will exist in whole perl interpreter.

Example:

 # get resolver session
 my $res_session_id = ACME::Util::PoeDNS->new();
 
 # ask questions
 $kernel->post($res_session_id, 'resolve', %opt);

=item Using it in fully OO style

Create your own resolver instance and play with it. 

Example:
 # create resolver object
 my $resolver = ACME::Util::PoeDNS->new();
 
 # spawn it in it's own session
 my $res_session_id = $resolver->spawn(["optional_session_alias"])
 
 # ask questions
 $kernel->post($res_session_id, 'resolve', %opt);
 
 # shut the resolver down
 $kernel->post($res_session_id, 'shutdown');

=back

=head2 getInstance ()

Returns singleton object instance.

=cut

sub getInstance {

  # already initialized?
  return $_singleton if (defined $_singleton);

  # nope, initialize it...
  $_singleton = __PACKAGE__->new();
}

=head1 OBJECT CONSTRUCTOR

Object constructor doesn't accept any arguments.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = $class->SUPER::new();
  bless($self, $class);
  $self->clearParams();
  return $self;
}

sub clearParams {
  my ($self) = @_;

  # public stuff
  $self->{alias}   = __PACKAGE__ . "." . rand();
  $self->{timeout} = TIMEOUT_DEFAULT;

  # private stuff...

  # poco dns poe session alias...
  $self->{_ra} = rand();

  # resolver object...
  $self->{_resolver} = Net::DNS::Resolver->new();

  # hosts cache...
  $self->{_hosts}           = {};    # hosts file cache
  $self->{_hostsMtime}      = 0;     # hosts file mtime
  $self->{_hostsReloadTime} = 0;     # last time that hosts file was reloaded

  # pending requests
  $self->{_req} = {};

  # register events...
  $self->registerEvent(
    qw(
      resolve
      resolvePtr
      shutdown
      _responseHandler
      _responseHandlerPtr
      _sockReadReady
      _sockWriteReady
      _timeout
      _loadHosts
      )
  );
}

=head1 METHODS

=head2 spawn ([$session_alias])

Spawns object in it's own session if it's not already spawned.
Returns spawned POE session id.

=cut

sub spawn {
  my ($self, $alias) = @_;

  my $ref = ref($self);

  # we're not object?
  unless (ref($self)) {
    $self = __PACKAGE__->getInstance();
  }

  # assign alias
  $self->{alias} = $alias if (defined $alias);

  # spawn ourselves...
  return $self->SUPER::spawn($self->{alias});
}

=head2 setTimeout ($timeout)

Sets default DNS resolve timeout. This method can be
invoked on package or instance.

Returns 1 on success, otherwise 0.

=cut

sub setTimeout {
  my ($self, $timeout) = @_;
  {
    no warnings;
    $timeout += 0;
  }
  return 0 unless ($timeout > 0);

  # instance or class invocation?
  if (ref($self) && blessed($self) && $self->isa(__PACKAGE__)) {

    # this is instance...
    $self->{timeout} = $timeout;
  }
  else {

    # this is class variable...

    # apply default timeout
    $_singleton_tm = $timeout;

    # do we have singleton?
    # update it's timeout too.
    if (defined $_singleton) {
      $_singleton->setTimeout($timeout);
    }
  }

  return 1;
}

# make PoeSession class happy.
sub sessionStart {
  my ($self) = @_;

  # This is necessary...
  $self->_loadHosts();
  return 1;
}

sub _stop {
  my $self = $_[0];

  # print "[", ref($self), "/$self] resolver session ", $self->getSessionId(), " is stopping: \n";
  # print "_stop: Me $self, singleton = $_singleton\n";
  if (defined $_singleton && $self == $_singleton) {

    # print "I AM THE LAST DYING SINGLETON\n";
    undef $_singleton;
  }
}

=head1 ACCEPTED EVENTS

Object instance accepts the following events:

=head2 resolve (%opt) [POE]

Starts new resolve (DNS name => IP address) operation. The following (case insensitive) keys are accepted:

=over

=item B<host> (string, undef, required): Query hostname.

=item B<event> (string, undef, required): Postback session event name.

=item B<context> (string, undef): Optional context that will be included in result structure.

=item B<timeout> (float, 30.0): Resolve timeout in seconds

=item B<ipv4_only> (boolean, 0): Return only IPv4 addresses (A records)

=item B<ipv6_only> (boolean, 0): Return only IPv6 addresses (AAAA records)

=back

=cut

sub resolve {
  my ($self, $kernel, %opt) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  # apply configuration
  my $c = $self->_cfgDefault();
  map {
    my $k = lc($_);
    if (exists($c->{$k})) {
      $c->{$k} = $opt{$_};
    }
  } keys %{opt};

  # check configuration...
  return 0 unless (defined $c->{host});
  return 0 unless (defined $c->{event});
  if ($c->{ipv4_only} && $c->{ipv6_only}) {
    $c->{ipv6_only} = 0;
    $c->{ipv4_only} = 0;
  }
  $c->{timeout} = $self->{timeout} unless (defined $c->{timeout} && $c->{timeout} > 0);

  # check source session - who called us?
  my $cid = $_[SENDER]->ID();
  return 0 unless (defined $cid);

  # check if we something in hosts...
  if (exists($self->{_hosts}->{$c->{host}})) {

    # print "[$c->{host}]: Hit from hosts\n";
    return $kernel->post($cid, $c->{event},
      {ok => 1, error => undef, host => $c->{host}, result => [@{$self->{_hosts}->{$c->{host}}}]});
  }

  # print "[$c->{host}]: Query DNS\n";

  my $ct = time();

  # enqueue hosts reload if necessary...
  if (($self->{_hostsReloadTime} + 120) < $ct) {
    $kernel->yield('_loadHosts');
  }

  # create DNS packets...
  my @packets = ();
  if ($c->{ipv4_only}) {
    push(@packets, Net::DNS::Packet->new($c->{host}, "A", "IN"));
  }
  elsif ($c->{ipv6_only}) {
    push(@packets, Net::DNS::Packet->new($c->{host}, "AAAA", "IN"));
  }
  else {
    push(@packets, Net::DNS::Packet->new($c->{host}, "A",    "IN"));
    push(@packets, Net::DNS::Packet->new($c->{host}, "AAAA", "IN"));
  }

  # create context
  my $ctx = $ct . "_" . rand();
  $self->{_req}->{$ctx} = {
    timeout  => $c->{timeout},
    host     => $c->{host},
    session  => $cid,
    event    => $c->{event},
    ctx      => $c->{context},
    error    => undef,
    aid      => undef,
    result   => [],
    num_resp => 0,               # currently we have 0 dns responses...
    req_resp => 0,               # how many dns responses we want...
    sockets  => [],
  };

  return $self->_startQuery($ctx, @packets);

=pod
	# create UDP sockets that will carry packets...
	my @sockets = ();
	map {
		push(
			@sockets,
			$self->{_resolver}->bgsend($_)
		);
	} @packets;

	# create socket io watches...
	map { $kernel->select_write($_, '_sockWriteReady', $ctx) } @sockets;

	# create timeout alarm...
	print "[$c->{host}]: timeout $c->{timeout}\n";
	my $aid = $kernel->alarm_set(
		'_timeout',
		(time() + $c->{timeout}),
		$ctx
	);
	
	# save to context struct...
	$self->{_req}->{$ctx} = {
		host => $c->{host},
		session => $cid,
		event => $c->{event},
		ctx => $c->{context},
		error => undef,
		aid => $aid,
		result => [],
		num_resp => 0,					# currently we have 0 dns responses...
		req_resp => ($#sockets + 1),	# how many dns responses we want...
		sockets => [ @sockets ]
	};

	# increment refcount
	$poe_kernel->refcount_increment(
		$c->{session},
		REFCOUNT_KEY
	);
	
	return 1;
=cut

}

=head2 resolvePtr (%opt)

Resolves IP address to DNS name. The following (case insensitive) keys are accepted:

=over

=item B<host> (string, undef, required): Query IP address.

=item B<event> (string, undef, required): Postback session event name.

=item B<context> (string, undef): Optional context that will be included in result structure.

=item B<timeout> (float, 60.0): Resolve timeout in seconds

=back

=cut

sub resolvePtr {
  my ($self, $kernel, %opt) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  # apply configuration
  my $c = $self->_cfgDefault();
  map {
    my $k = lc($_);
    if (exists($c->{$k})) {
      $c->{$k} = $opt{$_};
    }
  } keys %{opt};

  # check configuration...
  return 0 unless (defined $c->{host});
  return 0 unless (defined $c->{event});
  $c->{timeout} = $self->{timeout} unless (defined $c->{timeout} && $c->{timeout} > 0);

  # check source session - who called us?
  my $cid = $_[SENDER]->ID();
  return 0 unless (defined $cid);

  # create context struct...
  my $ct  = time();
  my $ctx = $ct . "_" . rand();
  $self->{_req}->{$ctx} = {
    timeout  => $c->{timeout},
    host     => $c->{host},
    session  => $cid,
    event    => $c->{event},
    ctx      => $c->{context},
    error    => undef,
    aid      => undef,
    result   => [],
    num_resp => 0,               # currently we have 0 dns responses...
    req_resp => 0,               # how many dns responses we want...
    sockets  => [],
  };

  # create query packet...
  my $packet = Net::DNS::Packet->new($c->{host}, "PTR", "IN");

  # start query...
  return $self->_startQuery($ctx, $packet);
}

sub _startQuery {
  my ($self, $ctx, @packets) = @_;
  return 0 unless (defined $ctx && @packets);

  # check structure...
  return 0 unless (exists($self->{_req}->{$ctx}));
  my $s = $self->{_req}->{$ctx};

  # create UDP sockets that will carry packets...
  my @sockets = ();
  map { push(@sockets, $self->{_resolver}->bgsend($_)); } @packets;

  # create socket io watches...
  map { $poe_kernel->select_write($_, '_sockWriteReady', $ctx) } @sockets;

  # create timeout alarm...
  my $aid = $poe_kernel->alarm_set('_timeout', (time() + $s->{timeout}), $ctx);

  # save data to request context...
  $s->{req_resp} = $#sockets + 1;
  $s->{sockets}  = [@sockets];

  # increment refcount
  $poe_kernel->refcount_increment($s->{session}, REFCOUNT_KEY);

  return 1;
}

sub _cfgDefault {
  return {
    host      => undef,
    event     => undef,
    context   => undef,
    timeout   => $_[0]->{timeout},
    ipv4_only => 0,
    ipv6_only => 0,
  };
}

=head2 shutdown () [POE]

Shuts down resolver instance.

B<NOTICE:> You don't need to shutdown singleton instance, isn't that just fucking great? :)
You'll get nasty warning message if you'll try to shutdown singleton session :)

=cut

sub shutdown {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # disable double shutdown :)
  return 1 if ($self->{__shutdown});
  $self->{__shutdown} = 1;

  # are we singleton?
  # singleton can't be shut down
  if (defined $_singleton && $self == $_singleton) {
    warn("I AM THE SINGLETON RESOLVER OBJECT ([$self])!!! I AM IMMORTAL!!!\n");
    warn("Called by: ", join(", ", caller()));
    return 0;
  }

  # print "Resolver ", ref($self), " [$self] POE session ", $self->getSessionId(), " is shutting down!\n";

  # remove alarms...
  $kernel->alarm_remove_all();

  # remove all current session aliases
  map {

    # print "Removing POE alias '$_'\n";
    $kernel->alias_remove($_);
  } $kernel->alias_list($_[SESSION]);

  # destroy all pending requests
  my $err = 'Component ' . ref($self) . ' is shutting down';
  map {

    # are there any sockets?
    map {

      # remove io watchers
      $kernel->select_read($_);
      $kernel->select_write($_);

      # close socket
      $_->close();
    } @{$_->{sockets}};

    # create result structure with erroreus response...
    my $res = {ok => 0, host => $_->{host}, error => $err, context => $_->{ctx}, result => []};

    # post it back to calling session
    $kernel->post($_->{session}, $_->{event}, $res);

    # decrement refcount
    $kernel->refcount_decrement($_->{session}, REFCOUNT_KEY);
  } values %{$self->{_req}};

  # destroy request structure...
  $self->{_req} = {};

  # kill underlying POCO DNS component...
  $kernel->call($self->{_ra}, 'shutdown');

  # print "Object ", ref($self), " shutdown\n";
}

# this one blocks... badly...
sub _loadHosts {
  my ($self) = @_;

  # I WAS HERE :)
  $self->{_hostsReloadTime} = time();

  # which file to parse...
  my $file = "/etc/hosts";

  # windows?
  if ($^O =~ m/^win/i) {
    $file = 'C:/windows/system32/drivers/etc/hosts';
  }

  # get file's mtime...
  my @s = stat($file);
  if (@s) {

    # check if we have fresh copy...
    return 1 if ($s[9] == $self->{_hostsMtime});
  }

  # print "Reading hosts...\n";
  my $fd = IO::File->new($file, 'r');
  return 0 unless (defined $fd);

  # apply file mtime
  $self->{_hostsMtime} = $s[9];

  # read hosts...
  while (<$fd>) {
    $_ =~ s/^\s+//g;
    $_ =~ s/\s+$//g;
    next unless (length($_) > 0);
    next if ($_ =~ m/^#/);

    my ($address, @hosts) = split(/\s+/, $_);
    next unless (@hosts);

    map {
      unless (exists($self->{_hosts}->{$_}))
      {
        $self->{_hosts}->{$_} = [];
      }
      push(@{$self->{_hosts}->{$_}}, $address);
    } @hosts;
  }

  return 1;
}


sub _sockWriteReady {
  my ($self, $kernel, $sock, $ctx) = @_[OBJECT, KERNEL, ARG0, ARG2];

  # stop watcher for this socket
  $kernel->select_write($sock);

  return 0 unless (exists($self->{_req}->{$ctx}));
  my $s = $self->{_req}->{$ctx};

  # create read watcher for this socket...
  $kernel->select_read($sock, '_sockReadReady', $ctx);

  #print "method writeready done\n";
}

sub _sockReadReady {
  my ($self, $kernel, $sock, $ctx) = @_[OBJECT, KERNEL, ARG0, ARG2];

  # stop watcher for this socket
  $kernel->select_read($sock);

  return 0 unless (exists($self->{_req}->{$ctx}));
  my $s = $self->{_req}->{$ctx};

  #print "sock read ready ($sock): $ctx\n";

  my $buf = '';
  my $len = 512;
  $sock->recv($buf, $len);

  # close socket
  $sock->close();

  # print "[$s->{host}]: Neki smo dobli v buf: '$buf'\n";

  my $packet = Net::DNS::Packet->new(\$buf);

  # print "GOT response: \n" . $packet->string(). "\n";
  # $packet->print();

  # increment number of responses...
  $s->{num_resp}++;

  #use Data::Dumper;
  #print "Struct: ", Dumper($s), "\n";

  # inspect packet
  $self->_inspectPacket($packet, $ctx);

  # inspect if we're done...
  return $self->_isDone($ctx);
}

sub _timeout {
  my ($self, $kernel, $ctx) = @_[OBJECT, KERNEL, ARG0, ARG1 .. $#_];

  # get context...
  return 0 unless (exists($self->{_req}->{$ctx}));
  my $s = $self->{_req}->{$ctx};

  # cleanup sockets
  map {
    if (defined $_)
    {

      # print "Destroying socket: $_\n";
      # remove io watchers
      $kernel->select_read($_);
      $kernel->select_write($_);

      # close socket
      $_->close();
    }
  } @{$s->{sockets}};

  $s->{error} = "Timeout";
  $s->{ok}    = 0;

  # force response...
  $self->_isDone($ctx, 1);
}

sub _inspectPacket {
  my ($self, $packet, $ctx) = @_;

  #return 0 unless (defined $packet);
  return 0 unless (exists($self->{_req}->{$ctx}));
  my $s = $self->{_req}->{$ctx};

  # return 0 unless (defined $packet);

  # read stuff from packet
  foreach my $answer ($packet->answer()) {
    next unless (defined $answer);
    my $type = lc($answer->type());
    next unless ($type eq 'a' || $type eq 'aaaa' || $type eq 'ptr');

    #print "Adding: ", $answer->rdatastr(), "\n";
    push(@{$s->{result}}, $answer->rdatastr());
  }

  return 1;
}

sub _isDone {
  my ($self, $ctx, $force) = @_;
  $force = 0 unless (defined $force);

  # check ctx struct...
  return 0 unless (exists($self->{_req}->{$ctx}));
  my $s = $self->{_req}->{$ctx};

  # do we have enough responses?
  if ($s->{num_resp} < $s->{req_resp}) {
    return 0 unless ($force);
  }

  #print "method readready done\n";

  #use Data::Dumper;
  #print "DONE (force: $force): ", Dumper($s), "\n";
  #print "===========================\n";

  # remove timeout alarm
  $poe_kernel->alarm_remove($s->{aid});

  # send result back...
  my $res = {
    ok => (@{$s->{result}}) ? 1 : 0,
    host   => $s->{host},
    result => $s->{result},
    error  => (@{$s->{result}}) ? undef : ((defined $s->{error}) ? $s->{error} : 'NXDOMAIN'),
  };
  $poe_kernel->post($s->{session}, $s->{event}, $res);

  # decrement refcount
  $poe_kernel->refcount_decrement($s->{session}, REFCOUNT_KEY);

  # delete struct...
  delete($self->{_req}->{$ctx});
}

=head1 RESPONSE MESSAGES

Methods B<resolve> and B<resolvePtr> post back to specified event to caller session single hash reference
type argument:

 $struct = {
 	ok => 1,		# resolve status (boolean)
 	error => '',		# resolve error, if any
 	
 	# question
 	host => 'www.kame.net',
 	
 	# your provided context (if any)
 	context => '',
 	
 	# resolved addresses
 	result => [
		'203.178.141.194',
		'2001:200:0:8002:203:47ff:fea5:3085'
 	]
 };

=cut

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<POE::Component::Client::DNS>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
