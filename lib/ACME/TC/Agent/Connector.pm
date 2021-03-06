package ACME::TC::Agent::Connector;


use strict;
use warnings;

use POE;
use Log::Log4perl;
use Scalar::Util qw(blessed);

use base qw(
  ACME::Util::ObjFactory
  ACME::Util::PoeSession
);

my $VERSION = 0.10;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Connector

tc agent command acceptor base class.

=head1 SYNOPSIS
	
	# connector configuration data...
	my $driver = "HTTP";
	my %opt = (
		port => 9000
	);
	
	$kernel->yield($agent_session, 'connectorInit', $driver, %opt);

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR (key => val, key2 => val2)

Object constructor acceps arbitrary key => value pairs / hash. Listed configuration keys
are accepted by the base class and all derived implementations.

=item B<alias> (string, <auto-generated>)

Specifies desired POE session alias name. POE session names must be unique among perl interpreter instance.
Non-unique session alias name will result with automatic module unload during initialization phase.

=over

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  ##################################################
  #              PUBLIC PROPERTIES                 #
  ##################################################

  ##################################################
  #              PRIVATE PROPERTIES                #
  ##################################################

  # last error...
  $self->{_error} = "";

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);

  return $self;
}

sub DESTROY {
  my ($self) = @_;
  $_log->debug("Destroying: $self") if (defined $_log);
}

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 METHODS

Methods marked with B<[POE]> can be called as POE events.

=cut

=item getError () [POE]

Returns last error accoured.

=cut

sub getError {
  my ($self) = @_;
  return $self->{_error};
}

=item clearParams ()

Resets connector configuration to defaults. Returns 1 on success, otherwise 0.

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->isSpawned());

  # "public" settings

  # private settings

  # agent's poe session id
  $self->{_agentSessionId} = undef;

  # connector is started...
  $self->{__connectorIsStarted} = 0;

  # shutdown in progress...
  $self->{__shutdown} = 0;

  $self->registerEvent(
    qw(
      getError
      getDriver
      run
      mount
      umount
      shutdown
      )
  );

  return 1;
}

=item setParams (key => val, key2 => val2)

Returns number of keys that were successful set.
=cut

sub setParams {
  my $self = shift;

  my $i = 0;
  while (@_) {
    my $key = shift;
    my $val = shift;
    next unless (defined $key && defined $val);
    next if ($key =~ m/^_/);

    $self->{$key} = $val;
    $i++;
  }

  return $i;
}

=item getDriver () [POE]

Returns driver name.

=cut

sub getDriver {
  my $self = shift;
  return $self->_getBasePackage();
}

=item isStarted ()

Returns 1 if plugin was started using spawn() method, otherwise 0.

=cut

sub isStarted {
  my $self = shift;
  return $self->{__connectorIsStarted};
}

=item spawn ()

Creates POE session and starts connector. Returns connector's POE session id on success, otherwise 0.

=cut

=item mount (key => val, key2 => val2) [POE]

Mounts connector context. This method must be implemented by the real implementation.

Returns 1 on success, otherwise 0.

=cut

sub mount {
  my $self = undef;
  my @args;
  my $num       = 0;
  my ($package) = caller();
  my $poe       = ($package =~ m/^POE::Sess/) ? 1 : 0;
  if ($poe) {
    $self = $_[OBJECT];
    @args = @_[ARG0 .. $#_];
  }
  else {
    $self = shift;
    @args = @_;
  }

  $_log->error(
    "Plugin handler '" . $self->_getBasePackage() . "' doesn't implement POE event/method mount().");
  return 0;
}

=item umount ($ctx) [POE]

Umounts specified connector context.

Returns 1 on success, otherwise 0.

=cut

sub umount {
  my ($self) = @_;
  $_log->error(
    "Plugin handler '" . $self->_getBasePackage() . "' doesn't implement POE event/method umount().");
  return 0;
}

=item shutdown () [POE]

Stops connector execution.

Returns 1 on success, otherwise 0.

=cut

sub shutdown : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # disable double shutdown
  return 1 if ($self->{__shutdown});
  $self->{__shutdown} = 1;

  $_log->debug("Shutting down.");

  # call subclass shutdown handler...
  $self->_shutdown();

  # remove alarms...
  $kernel->alarm_remove_all();

  # remove all current session aliases
  map { $kernel->alias_remove($_); } $kernel->alias_list($_[SESSION]);

  # get rid of external ref count
  # $kernel->refcount_decrement( $session, 'my ref name' );

  # propagate shutdown message to children
  # $kernel->call($child_session, "shutdown")...

  # we're not started anymore...
  $self->{__connectorIsStarted} = 0;

  return 1;
}

=item getAgentPoeSessionId () [POE]

Returns tc agent's POE session id.

=cut

sub getAgentPoeSessionId {
  my $self = shift;
  return $self->{_agentSessionId};
}

=item setAgentPoeSessionId ($id)

Sets tc agent's POE session id. Don't use unless you really know what you're doing.

Returns 1 on success, otherwise 0.

=cut

sub setAgentPoeSessionId {
  my ($self, $id) = @_;

  # this one can be set only once.
  if (defined $self->{_agentSessionId}) {
    $self->{_error} = "Agent POE session id is already set.";
    return 0;
  }

  { no warnings; $id = int($id); }
  unless (defined $id && $id > 0) {
    $self->{_error} = "Invalid or undefined POE session id.";
    return 0;
  }

  $_log->debug("Setting tc agent's POE session id: $id.");
  $self->{_agentSessionId} = $id;
  return 1;
}

=item getAgent () [POE]

Returns tc agent object.

=cut

sub getAgent {
  my $self = shift;
  return $poe_kernel->call($self->{_agentSessionId}, "getAgent");
}

=item getObject () [POE]

Returns connector object.

=cut

sub getObject {
  my $self = shift;
  return $self;
}

=item run () [POE]

Connector's entry point. This method is not implemented by the base class.

=cut

sub run : State {
  my $self = $_[OBJECT];
  $_log->error("Connector '" . $self->_getBasePackage() . "' doesn't implement POE event/method run().");
  return 0;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _getBasePackage {
  my ($self) = @_;
  my @tmp = split(/::/, ref($self));
  return pop(@tmp);
}

sub _shutdown {
  my $self = shift;
  $_log->debug("This is no-op connector shutdown handler.");
}

sub sessionStart {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->debug("Starting object ", ref($self), " POE session: " . $self->getSessionId());

  # mark as started...
  $self->{__connectorIsStarted} = 1;

  # run the stuff...
  $_log->debug("Invoking event run().");
  $kernel->yield("run");
}

=head1 EXTENDING

Connector is in fact POE-ized class, which can be simply extended to suit your
greedy needs.

You must implement/override the following methods:

=item B<run ()> (mandatory)

This method is invoked after connector startup, just after POE sessions were created and initialized.

=item B<mount ()> (mandatory)

=item B<umount ()> (mandatory)

=item B<_shutdown ()> (optional)

This method is invoked after connector receives shutdown event. You can implement this method to do clean
up after itself.

=over

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::Util::PoeSession>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Connector::EXAMPLE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
