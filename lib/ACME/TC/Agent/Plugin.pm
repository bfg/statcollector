package ACME::TC::Agent::Plugin;


use strict;
use warnings;

use POE;
use File::Spec;
use Log::Log4perl;
use Scalar::Util qw(blessed);

use base qw(
  ACME::Util::PoeSession
  ACME::Util::ObjFactory
);

our $VERSION = 0.10;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin

tc agent plugin base class. 

=head1 SYNOPSIS

	#################################
	#  tc agent initialization  #
	#################################
	
	# plugin configuration...
	my $plugin_driver = "Vmstat";
	my %plugin_params = (
	);
	
	$kernel->yield($agent_session, 'pluginInit' $driver, %opt);

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR (key => val, key2 => val2)

Object constructor acceps arbitrary key => value pairs / hash. Listed configuration keys
are accepted by the base class and all derived implementations.

=item B<alias> (string, undef)

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
  $self->{_error} = '';

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);

  return $self;
}

# object destructor...
sub DESTROY {
  my ($self) = @_;
  if (defined $_log) {
    $_log->debug("Destroying: $self");
  }
  else {

    # print STDERR "DESTROYING: $self\n";
  }
}

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 METHODS

Methods marked with B<[POE]> can be invoked as POE events.

=item allowMultipleInstances () [POE]

Returns 1 if specified plugin allows multiple independent instances of itself, otherwise always returns 0.

This is static method that you should to override in your plugin implementation if you
want to force only one running instance of your plugin.  

=cut

sub allowMultipleInstances : State {
  return 0;
}

=item getError () [POE]

Returns last error accoured.

=cut

sub getError : State {
  my $self = shift;
  return $self->{_error};
}

=item clearParams ()

Resets plugin configuration to default values.

B<WARNING:> Plugin configuration can be only reset prior to plugin startup (See method spawn()). 

Returns 1 on success, otherwise 0.

=cut

sub clearParams {
  my ($self) = @_;
  if ($self->isStarted()) {
    $self->{_error} = "Unable to reset plugin configuration: Plugin is already started.";
    return 0;
  }

  # "public" settings
  $self->{alias} = rand();

  # POE session alias
  # $self->{alias} = ref($self) . '_' . time() . '_' . rand();

  # private settings
  $self->{_error}            = "";    # last error message
  $self->{__shutdown}        = 0;     # this plugin is shutting down
  $self->{__pluginIsStarted} = 0;     # this plugin is currently not started
  $self->{_agentSessionId}   = 0;     # tc agent POE session ID

  return 1;
}

=item setParams (key => val, key2 => val2)

Sets plugin configuration parameter(s).

B<WARNING:> Plugin configuration can only be set prior to plugin startup (See method spawn()). 

Returns number of configuration keys actually set.

=cut

sub setParams {
  my $self = shift;
  if ($self->{__pluginIsStarted}) {
    $self->{_error} = "Unable to set configuration key(s): Plugin is already started.";
    return 0;
  }

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

sub getDriver : State {
  my $self = shift;
  return $self->_getBasePackage();
}

=item isStarted ()

Returns 1 if plugin was started using spawn() method, otherwise 0.

=cut

sub isStarted {
  my $self = shift;
  return $self->{__pluginIsStarted};
}

=item poeGetSessionId () [POE]

Returns connector's POE session ID.

=cut

sub poeGetSessionId {
  my $self = shift;
  return $self->getSessionId();
}

=item getAgentPoeSessionId () [POE]

Returns tc agent's POE session id.

=cut

sub getAgentSessionId : State {
  my $self = shift;
  return $self->{_agentSessionId};
}

=head2 agentCall ($event, [ args ])

Invokes POE synchronous call to event $event in agent's POE session and returns.

=cut 

sub agentCall {
  my $self = shift;
  return $poe_kernel->call($self->getAgentSessionId(), @_);
}

=head2 agentPost ($event, [ args])

Invokes POE event $event in agent's POE session using ($kernel->post()).

=cut

sub agentPost {
  my $self = shift;
  $poe_kernel->post($self->getAgentSessionId(), @_);
  return 1;
}

=head2 getError ()

Returns last error accoured in agent.

=cut

sub agentError {
  my ($self) = @_;
  return $poe_kernel->call($self->getAgentSessionId(), 'getError');
}

=item setAgentPoeSessionId ($id)

Sets tc agent's POE session id. This method is invoked automatically when assigning
plugin to tc agent object; don't call it unless you really know what you're doing.

Returns 1 on success, otherwise 0.

=cut

sub setAgentPoeSessionId {
  my ($self, $id) = @_;
  $id = 0 unless (defined $id);
  $_log->debug("Plugin ", $self->getDriver(), " tc agent POE session id to: $id");
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

sub getAgent : State {
  my $self = shift;
  my $err  = "Error getting agent object: ";
  $_log->debug("Trying to obtain tc agent object from POE session $self->{_agentSessionId}.");

  unless (defined $self->{_agentSessionId}) {
    $self->{_error} = $err . "Undefined agent's POE session.";
    return undef;
  }

  # fetch object...
  my $obj = $poe_kernel->call($self->{_agentSessionId}, "getAgent");

  if ($! != 0) {
    $self->{_error} = $err . $!;
  }
  elsif (!defined $obj) {
    $self->{_error} = $err . $poe_kernel->call($self->{_agentSessionId}, "getError");
  }

  return $obj;
}

=item getObject () [POE]

Returns plugin object.

=cut

sub getObject : State {
  my $self = shift;
  return $self;
}

=item run () [POE]

This method is called as POE event just after spawn() creates new POE session. This method is basically
startup method in your plugin implementation...

No meaningful return value is required.

You should override this method in your plugin implementation.

=cut

sub run : State {
  my $self = $_[OBJECT];
  $_log->error("Plugin handler '" . $self->_getBasePackage() . "' doesn't implement POE event/method run().");
  return 0;
}

=item spawn ()

Starts plugin. Returns plugin's POE session id on success, otherwise 0.

=cut

sub spawn {
  my ($self) = @_;
  return $self->SUPER::spawn($self->{alias});
}

=item shutdown () [POE]

Stops plugin execution.

Returns 1 on success, otherwise 0.

=cut

sub shutdown : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

#	print "SELF: $self, ", join(", ", caller()), "\n";
#	print "odkod: ", join(", ",
#		$_[CALLER_FILE],
#		$_[CALLER_LINE],
#		$_[CALLER_STATE],
#	), "\n";

  # disable double shutdown :)
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
  $self->{__pluginIsStarted} = 0;

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 PROTECTED METHODS/EVENTS

=item _shutdown ()

If you want to do anything special during your plugin shutdown, you should override this method. Return value
of this method is never checked.

=cut

sub _shutdown {
  my $self = shift;
  $_log->debug("This is no-op plugin shutdown handler.");
}

=item _getBasePackage ([$pkg|$obj])

This is basename(3) perl for perl modules/object. Returns basename of plugin object... 

=cut

sub _getBasePackage {
  my ($self, $obj) = @_;
  $obj = $self unless (defined $obj);
  my @tmp = split(/::/, ref($obj));
  return pop(@tmp);
}

=item _which ($program)

which(1) implementation in perl. Returns full program path if found in $PATH, otherwise undef.

=cut

sub _which {
  my ($self, $bin) = @_;
  unless (defined $bin) {
    $self->{error} = "Unable to look for undefined binary.";
    return undef;
  }

  foreach my $d (split(/[:;]+/, $ENV{PATH})) {
    my $x = File::Spec->catfile($d, $bin);

    return $x if (-f $x && -x $x);
  }

  $self->{_error} = "Binary '$bin' not found in \$PATH.";
  return undef;
}

sub sessionStart {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->debug("Starting object ", ref($self), " POE session: " . $self->getSessionId());

  # mark ourselves as started
  $self->{__pluginIsStarted} = 1;

  # run the stuff...
  $_log->info(
    "Plugin " . $self->_getBasePackage() . " version " . sprintf("%-.2f", $self->VERSION()) . " startup.");
  $kernel->yield("run");
}

=pod
sub _stop {
	my $self = shift;
	if (defined $_log) {
		$_log->debug("Stopping object '$self' POE session: " . $_[SESSION]->ID());
	} else {
		print STDERR "Stopping object '$self' POE session: " . $_[SESSION]->ID(), "\n";
	}

	# mark as stopped
	$self->{__pluginIsStarted} = 0;
}
=cut

sub _postback {
  my $self     = shift;
  my $postback = shift;

  # undefined postback?
  unless (defined $postback) {
    $_log->warn("Response postback is not defined, returning my arguments");
    return 0;
  }

  # CODE postback?
  if (ref($postback) eq 'CODE') {
    $_log->debug("Returning response object as CODE postback.");
    &{$postback}->(@_);
    return 1;
  }

  # POE postback?
  elsif (blessed($postback) && $postback->isa('POE::Session::AnonEvent')) {
    $_log->debug("Returning response object as POE postback.");
    $postback->(@_);
  }
  else {
    my ($session, $event) = split(/\s*:\s*/, $postback, 2);
    $_log->debug("Returning response object to session $session, event $event");
    my $x = $poe_kernel->post($session, $event, @_);
    unless ($x) {
      $_log->error("Error posting HTTP response to session $session, event $event: $!");
      return 0;
    }
  }

  return 1;
}

=head1 EXTENDING

Plugin is in fact POE-ized class, which can be simply extended to suit your
greedy needs.

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::Util::PoeSession>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Plugin::EXAMPLE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
