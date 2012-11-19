package ACME::TC::Agent;


use strict;
use warnings;

use POE;
use Log::Log4perl;
use Scalar::Util qw(blessed);
use POSIX qw(strftime setsid);

use ACME::Util::PoeSession;
use ACME::TC::Agent::Plugin;
use ACME::TC::Agent::Connector;

use base qw(
  ACME::Util::PoeSession
);

##################################################
#                    CONSTANTS                   #
##################################################

use constant NOOP_DELAY => 60;

use constant CLASS_CONNECTOR => 'ACME::TC::Agent::Connector';
use constant CLASS_PLUGIN    => 'ACME::TC::Agent::Plugin';

##################################################
#                    GLOBALS                     #
##################################################

our $VERSION = 0.09;
my $Error           = "";
my %_loaded_classes = ();

my $_optional_plugins = [{driver => 'Cache',}];

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent

tc agent base class.

When you create Agent object it is basically unusable. If you want to "talk" with the agent,
you should load some B<Connectors>, providing you an abstract way to issue agent commands and/or
methods outside from perl interpreter. tc agent itself, even with initialized connectors, is
completely unusable without any assigned plugins, which provide acctual agent functionality; agent
by itself is only some kind ob abstract framework for communication between connectors and plugins
providing functionality.

See L<CLASS_CONNECTOR> and L<CLASS_PLUGIN> for details.

=head1 SYNOPSIS

	# load package
	use ACME::TC::Agent;

	# initialize agent object...
	my $agent = ACME::TC::Agent->new(
		key => value,
		key2 => value2
	);
	unless (defined $agent) {
		die "Unable to construct agent: ", ACME::TC::Agent->getError(), "\n";
	}
	
	# add some connectors
	my $conn_driver = "HTTP";
	my %conn_params = (
		port => 8090,
		ssl => 1,
		ssl_cert => "cert.pem",
		ssl_key => "cert.pem"
	);
	
	my $connector_session_id = $agent->connectorInit($conn_driver, %conn_params);
	unless ($connector_session_id) {
		die "Unable to add connector $conn_driver: ", $agent->getError();
	}
	
	# start the agent! (if POE kernel is already running)
	my $agent_poe_session = $agent->spawn();
	unless ($agent_poe_session) {
		die "Unable to start agent: ", $agent->getError();
	}
	
	# if POE kernel is not running, this one will block
	# until agent is running...
	# $agent->run();
	
	# All methods marked as [POE] can be called
	# as POE events.
	
	# add another connector "by hand"
	my $conn2_driver = "HTTP";
	my $conn2_params = (
		port => 9001,
		ssl => 1,
		ssl_cert => "cert2.pem",
		ssl_key => "cert2.pem",
	);
	my $connector = CLASS_CONNECTOR->factory(
		$conn2_driver,
		%conn2_params,
	);
	unless (defined $connector) {
		die "Unable to initialize connector: ", CLASS_CONNECTOR->getError();
	}
	# register connector synchronously...
	unless ($agent->connectorAdd($connector)) {
		die "Unable to assign connector: ", $agent->getError()
	}
	# ... or via POE post...
	$poe_kernel->post($agent_poe_session, "connectorAdd", $connector);
	# ... or via POE call...
	$poe_kernel->call($agent_poe_session, "connectorAdd", $connector);

	# add some plugins
	my $plugin_driver = "Vmstat";
	my %plugin_params = (
	);
	my $plugin_session_id = $agent->pluginLoad($plugin_driver, %plugin_params);
	unless ($plugin_session_id) {
		die "Unable to load plugin $plugin_driver: ", $agent->getError();
	}
	
	# load new plugin while agent is running...
	my $session_id = $poe_kernel->call(
		$agent_session_id,
		"loadPlugin",
		"CPUFreq",
		check_interval => 5,
	);

	# schedule agent shutdown...
	$poe_kernel->post($agent_session_id, "shutdown");

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = $class->SUPER::new();

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
  $_log->debug("Destroying: $self") if (defined $_log);
}

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Constructor accepts the following key => value pairs:

=item B<alias> (string, <random_generated>): POE session alias

=item B<installSigHandlers> (boolean, 0): Install INT and TERM signal handlers

=item B<loadOptionalPlugins> (boolean, 1): Load some additional plugins.

=head1 METHODS

=item clearParams ()

Resets agent parameters.

=cut

sub clearParams {
  my $self = shift;
  return 0 if ($self->isSpawned());

  # "public" settings...

  # poe session alias
  $self->{alias} = ref($self) . '_' . time() . '_' . rand();

  $self->{connectors}          = [];     # connector configuration...
  $self->{plugins}             = [];     # plugin configuration
  $self->{installSigHandlers}  = 0;      # install some signal handlers.
  $self->{loadOptionalPlugins} = 1;      # load optional plugins.
  $self->{cacheTtl}            = 600;    # optional plugin Cache cache TTL

  # private settings
  $self->{_error}        = '';           # last error accoured
  $self->{_poe_session}  = 0;            # agend POE session ID
  $self->{__shutdown}    = 0;            # agent instance shutdown in progress
  $self->{__connectors}  = {};           # connector POE hash
  $self->{__plugins}     = {};           # plugin POE object hash
  $self->{_agentStarted} = 0;

  # register event handlers...
  # $self->registerEvent(@_poe_events);

  return 1;
}

=head1 METHODS 

B<NOTICE>: Methods marked with B<[POE]> can be called as POE events or as normal instance methods.

B<WARNING>: Methods marked with B<[POE only]> can be called only as POE events.

=head2 getError () [POE]

Returns last error accoured in object or in package.

=cut

sub getError : State {
  my $self = shift;

  # return package error.
  unless (blessed($self) && $self->isa(__PACKAGE__)) {
    return $Error;
  }

  # return instance error
  return $self->{_error};
}

=item setParams (key => value, key2 => value2)

Sets agent configuration parameters. Returns number of parameters successfully set.

=cut

sub setParams {
  my $self = shift;
  if ($self->isSpawned()) {
    $self->{_error} = "Unable to clear agent parameters: agent is running";
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

=pod
=item poeGetAlias () [POE]

Returns tc agent's POE session alias.


sub poeGetAlias {
	my $self = shift;
	return $self->{alias};
}

sub getAlias {
	my $self = shift;
	return $self->{alias};
}
=cut

=item poeGetSessionId () [POE]

Returns tc agent's POE session ID.

=cut

sub poeGetSessionId {
  my $self = shift;
  return $self->getSessionId();
  return $self->getSessionId();
}

=item getAgent () [POE]

Returns agent object.

=cut

sub getAgent : State {
  my $self = shift;
  return $self;
}

=item connectorAdd ($obj) [POE]

Adds already initialized connector. Returns connector's POE session id on success, otherwise 0.

=cut

sub connectorAdd : State {

  # not called via poe?
  unless (is_poe(\@_)) {
    return $poe_kernel->call($_[0]->getSessionId(), 'connectorAdd', @_[1 .. $#_]);
  }
  my ($self, $kernel, $obj) = @_[OBJECT, KERNEL, ARG0];
  unless (defined $obj && blessed($obj) && $obj->isa(CLASS_CONNECTOR)) {
    $self->{_error} = "Invalid connector object: " . ref($obj);
    $_log->error($self->{_error});
    return 0;
  }

  # spawn ourselves if we're not already spawned
  $self->spawn();

  # set our session id to newly initialized connector
  $obj->setAgentPoeSessionId($self->getSessionId());

  # is this connector already started?
  my $id = 0;
  if ($obj->isStarted()) {
    $id = $obj->getSessionId();
  }
  else {

    # start it!
    $id = $obj->spawn();
    unless ($id) {
      $self->{_error} = "Unable to start connector: " . $obj->getError();
    }
  }

  # check for injuries
  return 0 unless ($id);

  # is this connector already assigned?
  if (exists($self->{__connectors}->{$id})) {
    $self->{_error} = "Specified connector is already assigned.";
    return 0;
  }

  # get driver
  my $driver = $obj->getDriver();

  # save && register the plugin
  $self->{__connectors}->{$id} = {driver => $driver, obj => $obj,};

  $_log->info("Connector '$driver' was successfully added as id $id.");
  return $id;
}

=item connectorInit ($driver, %params) [POE]

Initializes and starts connector identified by $driver with driver parameters stored in hash %params. 

Returns newly initialized connector's POE session id on success, otherwise 0.

=cut

sub connectorInit : State {

  # not called via poe?
  unless (is_poe(\@_)) {
    return $poe_kernel->call($_[0]->getSessionId(), 'connectorInit', @_[1 .. $#_]);
  }

  # poe call
  my ($self, $kernel, $driver, @opt) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  # try to initialize connector...
  my $connector = CLASS_CONNECTOR->factory($driver, @opt);
  unless (defined $connector) {
    $_log->error("Error initializing connector: " . CLASS_CONNECTOR->factoryError());
    $self->{_error} = "Error initializing connector: " . CLASS_CONNECTOR->factoryError();
    return 0;
  }

  $_log->debug("Connector object was successfully created, now adding.");

  # add connector
  $kernel->yield('connectorAdd', $connector);

  return 1;
}

=item connectorMountContext (key => value, key2 => value2) [POE]

=cut

sub connectorMountContext : State {
  unless (is_poe(\@_)) {
    return $poe_kernel->call($_[0]->getSessionId(), 'connectorMountContext', @_[1 .. $#_]);
  }

  my ($self, $kernel, @args) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  unless (@args) {
    $self->{_error} = "No arguments were provided.";
    $_log->error($self->{_error});
    return 0;
  }
  if ($_log->is_debug()) {
    $_log->debug("startup.");
    $_log->debug("Called by: ", join(", ", caller()));
    $_log->debug("Arguments: ", join(", ", @args));
  }

  my $i = 0;
  foreach my $c (keys %{$self->{__connectors}}) {
    my $obj = $self->{__connectors}->{$c}->{obj};
    my $r   = 0;
    eval { $r = $obj->mount(@args); };

    if ($@) {
      $_log->error("Exception while mounting connector context: $@");
    }
    elsif (!$r) {
      $_log->error("Error mounting connector context: " . $obj->getError());
    }
    else {
      $i++;
    }
  }

  $_log->debug("Mounted context on $i connector(s).");
  return $i;
}

=item connectorUmountContext ($context)

=cut

sub connectorUmountContext : State {
  unless (is_poe(\@_)) {
    return $poe_kernel->call($_[0]->getSessionId(), 'connectorUmountContext', @_[1 .. $#_]);
  }

  my ($self, $kernel, @args) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  my $i = 0;
  foreach my $c (keys %{$self->{__connectors}}) {
    my $obj = $self->{__connectors}->{$c}->{obj};
    my $r   = 0;
    eval { $r = $obj->umount(@args); };

    if ($@) {
      $_log->error("Exception while unmounting connector context: $@");
    }
    elsif (!$r) {
      $_log->error("Error unmounting connector context: " . $obj->getError());
    }
    else {
      $i++;
    }
  }
}

=item connectorList () [POE]

Returns list of available connector drivers.

=cut

sub connectorList : State {
  return CLASS_CONNECTOR->getDirectSubClasses();
}

=item connectorListActive () [POE]

Returns list containing ids of running connectors.

=cut

sub connectorListActive : State {
  my $self = shift;
  return sort keys %{$self->{__connectors}};
}

=item connectorUnloadAll () [POE]

Stops and unloads all initialized and running connectors. Returns number of removed connectors.

=cut

sub connectorUnloadAll : State {

  # no POE?
  return $poe_kernel->call($_[0]->getSessionId(), 'connectorUnloadAll', @_[1 .. $#_]) unless (is_poe(\@_));

  # POE
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  $_log->info("Unloading all connectors.");

  my $i = 0;
  foreach ($self->connectorListActive()) {
    $i += $self->connectorUnload($_);
  }

  $_log->info("Unloaded $i connector(s).");
  return $i;
}

=item connectorUnload ($id) [POE]

Stops and unloads connector identified by id $id. Returns 1 on success, otherwise 0.

=cut

sub connectorUnload : State {

  # no POE?
  return $poe_kernel->call($_[0]->getSessionId(), 'connectorUnload', @_[1 .. $#_]) unless (is_poe(\@_));

  # POE
  my ($self, $kernel, $id) = @_[OBJECT, KERNEL, ARG0];

  unless (exists($self->{__connectors}->{$id})) {
    $self->{_error} = "Invalid connector id.";
    return 0;
  }

  my $driver = $self->{__connectors}->{$id}->{driver};
  $_log->info("Unloading connector id $id [$driver].");

  # force connector shutdown
  $kernel->call($id, "shutdown");

  # destroy the connector object (this is done in _child())
  delete($self->{__connectors}->{$id});

  return 1;
}

=item pluginList () [POE]

Returns list of available plugins.

=cut

sub pluginList : State {
  my ($self) = @_;
  return CLASS_PLUGIN->getDirectSubClasses();
}

=item pluginAdd ($obj) [POE]

Adds initialized plugin object. Returns plugin's POE session id on success, otherwise 0.

=cut

sub pluginAdd : State {

  # no POE
  unless (is_poe(\@_)) {
    return $poe_kernel->call($_[0]->getSessionId(), 'pluginAdd', @_[1 .. $#_]);
  }

  # POE
  my ($self, $kernel, $obj) = @_[OBJECT, KERNEL, ARG0];

  unless (defined $obj && blessed($obj) && $obj->isa(CLASS_PLUGIN)) {
    $self->{_error} = "Invalid plugin object.";
    return 0;
  }

  # set our session id to newly initialized connector
  $obj->setAgentPoeSessionId($self->getSessionId());

  # is this connector already started?
  my $id = 0;
  if ($obj->isStarted()) {
    $id = $obj->poeGetSessionId();
  }
  else {

    # start it!
    $id = $obj->spawn();
    unless ($id) {
      $self->{_error} = "Unable to start plugin: " . $obj->getError();
    }
  }

  # check for injuries
  return 0 unless ($id);

  # is this connector already assigned?
  if (exists($self->{__plugins}->{$id})) {
    $self->{_error} = "Specified plugin is already assigned.";
    return 0;
  }

  # get driver
  my $driver = $obj->getDriver();

  # save && register the plugin
  $self->{__plugins}->{$id} = {driver => $driver, obj => $obj,};

  $_log->debug("Plugin '$driver' was successfully assigned as agent plugin id $id.");
  return $id;
}

=item pluginInit ($driver, %params) [POE]

Loads and initializes plugin using driver $driver with driver parameters identified by
hash %params. Returns it's POE session id on success, otherwise 0.

=cut

sub pluginInit : State {

  # no POE
  unless (is_poe(\@_)) {
    return $poe_kernel->call($_[0]->getSessionId(), 'pluginInit', @_[1 .. $#_]);
  }

  # POE
  my ($self, $kernel, $driver, @opt) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  $driver = "" unless (defined $driver);
  $_log->debug("Initializing plugin '$driver'.");

  # try to initialize object
  my $obj = CLASS_PLUGIN->factory($driver, @opt);
  unless (defined $obj) {
    my $str = "Unable to initialize plugin: " . CLASS_PLUGIN->factoryError();
    $self->{_error} = $str;
    $_log->error($str);
    return 0;
  }

  $_log->debug("Plugin '$driver' was successfully initialized.");

  # add plugin
  $kernel->yield('pluginAdd', $obj);
  return 1;
}

=item pluginUnload ($id) [POE]

Unloads loaded and running plugin identified by $id. Id is it's POE session id. Returns 1 on success, otherwise 0. 

=cut

sub pluginUnload : State {

  # no POE
  unless (is_poe(\@_)) {
    return $poe_kernel->call($_[0]->getSessionId(), 'pluginUnload', @_[1 .. $#_]);
  }

  # POE
  my ($self, $kernel, $id) = @_[OBJECT, KERNEL, ARG0];

  # check for existence...
  unless (exists($self->{__plugins}->{$id})) {
    $self->{_error} = "Invalid plugin id.";
    return 0;
  }

  my $driver = $self->{__plugins}->{$id}->{driver};
  $_log->info("Unloading plugin id $id [$driver].");

  # call plugin shutdown
  $kernel->call($id, "shutdown");

  # destroy the plugin object
  delete($self->{__plugins}->{$id});

  return 1;
}

=item pluginListActive () [POE]

Returns list containing ids of currently running plugins. 

=cut

sub pluginListActive : State {
  my $self = shift;
  return sort keys %{$self->{__plugins}};
}

=item pluginUnloadAll () [POE]

Stops and removes all initialized plugins. Returns number of removed plugins.

=cut

sub pluginUnloadAll : State {

  # no POE
  unless (is_poe(\@_)) {
    return $poe_kernel->call($_[0]->getSessionId(), 'pluginUnloadAll', @_[1 .. $#_]);
  }

  my $self = shift;

  $_log->info("Unloading all plugins.");
  my $i = 0;
  foreach ($self->pluginListActive()) {
    $i += $self->pluginUnload($_);
  }

  $_log->info("Unloaded $i plugin(s).");

  return $i;
}

sub spawn {
  my ($self) = @_;
  return $self->SUPER::spawn($self->{alias});
}

=item shutdown () [POE only]

=cut

sub shutdown : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # don't try to shutdown more than once :)
  return 0 if ($self->{__shutdown});

  # add shutdown flag...
  $self->{__shutdown} = 1;

  $_log->info("Shutting down agent.");

  # unload all plugins...
  $_log->debug("Unloading plugins.");
  $poe_kernel->call($self->getSessionId(), "pluginUnloadAll");

  # stop all connectors
  $_log->debug("Unloading connectors.");
  $poe_kernel->call($self->getSessionId(), "connectorUnloadAll");

  # unregister signal handlers...
  if ($self->{installSigHandlers}) {
    $_log->info("Unregistering signal handlers.");
    $kernel->sig('TERM',    undef);
    $kernel->sig('INT',     undef);
    $kernel->sig('__DIE__', undef);
  }

  # remove alarms...
  $kernel->alarm_remove_all();

  # remove all current session aliases
  map { $kernel->alias_remove($_); } $kernel->alias_list($_[SESSION]);

  $_log->info("Shutdown complete.");
  return 1;
}

# filehandle stuff
sub TIEHANDLE {
  my ($self) = @_;
  return $self;
}

sub PRINT {
  my $self = shift;
  $_log->warn("Catched STDOUT/STDERR: ", @_);
  return 1;
}

=item cacheGet ($key) [POE]

Checks internal cache for value identified by $key. Returns value if key was found,
otherwise returns undef. 

=cut

sub cacheGet : State {
  my ($self, $key) = (undef, undef);

  # called sync or over POE?
  my ($package, $filename, $line) = caller();
  my $poe = ($package =~ m/^POE::/);
  if ($poe) {
    $self = $_[OBJECT];
    $key  = $_[ARG0];
  }
  else {
    ($self, $key) = @_;
  }

  $_log->debug("Retrieving from cache: '$key'.");

  return $poe_kernel->call($self->{_cache}, "get", $key);
}

=item cacheAdd ($key, $value, [ $expire ]) [POE]

Adds $value to internal cache with cache key $key. Cache will hold the item for $expire seconds.
If $expire is set to value of 0, item will stay in cache forever. If $expire is omitted, $expire is
set to value of property B<cache_ttl>. If cache already holds any item with the same key already existing
item will be replaced with the new one.

Returns 1 on success, otherwise 0.

=cut

sub cacheAdd : State {
  my ($self, $key, $value, $expire) = (undef, undef, undef, undef);

  # called sync or over POE?
  my ($package, $filename, $line) = caller();
  my $poe = ($package =~ m/^POE::/);
  if ($poe) {
    $self = $_[OBJECT];
    ($key, $value, $expire) = @_[ARG0 .. $#_];
  }
  else {
    ($self, $key, $value, $expire) = @_;
  }

  # set defaults...
  $expire = $self->{cacheTtl} unless (defined $expire);

  $_log->debug("Storing to cache: '$key', '$value', expire = $expire.");

  return $poe_kernel->call($self->{_cache}, "replace", $key, $value, $expire);
}

sub cachePurge : State {
  my ($self) = @_;
  return $poe_kernel->call($self->{_cache}, "purge");
}

sub cacheDump : State {
  my ($self) = @_;
  return $poe_kernel->call($self->{_cache}, "dump");
}

# execute command and return result...

=item executeCmd ($cmd, arg1, arg2) [POE]

Executes Agent or plugin command. Returns

=cut

sub executeCmd : State {
  my $self = undef;

  # called sync or over POE?
  my ($package, $filename, $line) = caller();
  my $poe = ($package =~ m/^POE::/);
  if ($poe) {
    $self = $_[OBJECT];
  }
  else {
    $self = shift;
    return $poe_kernel->call($self->getSessionId(), "executeCmd", @_);
  }

  # :)
  my ($cmd, @args) = @_[ARG0 .. $#_];
  if ($_log->is_debug()) {
    $_log->debug("Executing command '$cmd' with arguments: ", join(", ", @args));
  }

  # hmmm... parse command name...
  my $plugin     = undef;
  my $plugin_cmd = undef;
  if ($cmd =~ m/^\s*(\w+)\s*\.\s*(\w+)\s*$/) {
    $plugin     = $1;
    $plugin_cmd = $2;
  }
  else {
    return undef;
  }
  $plugin_cmd = "" unless (defined $plugin_cmd);

  $_log->debug("Plugin: '$plugin', plugin_cmd: '$plugin_cmd'");
  my $plugin_session = undef;

  # get plugin session id...
  if (lc($plugin) ne 'agent') {
    $plugin_session = $self->_getPluginPoeSessionByName($plugin);
  }
  else {
    $plugin_session = $self->getSessionId();
  }

  unless ($plugin_session) {
    return undef;
  }

  $_log->debug("Will call POE session: $plugin_session.");
  my $x = $poe_kernel->call($plugin_session, $plugin_cmd, @args);

  if ($!) {
    $self->{_error} = "Error calling plugin POE session: $!";
    return undef;
  }

  # prepare return structure...
  my $result = {return => $x, error => $poe_kernel->call($plugin_session, "getError"),};

  return $result;
}

sub execCmd : State {
  my $self = undef;

  # called sync or over POE?
  my ($package, $filename, $line) = caller();
  my $poe = ($package =~ m/^POE::Sess/);
  if ($poe) {
    $self = $_[OBJECT];
  }
  else {
    $self = shift;
    return $poe_kernel->call($self->getSessionId(), "execCmd", @_);
  }

  # fetch parameters...
  my ($postback, $cmd, @args) = @_[ARG0 .. $#_];
  if ($_log->is_debug()) {
    $_log->debug("Executing command '$cmd' with arguments: ", join(", ", @args));
  }

  # no postback?
  unless (defined $postback) {
    $postback = $_[SENDER]->postback('');
  }

  # hmmm... parse command name...
  my $plugin     = undef;
  my $plugin_cmd = undef;
  if ($cmd =~ m/^\s*(\w+)\s*\.\s*(\w+)\s*$/) {
    $plugin     = $1;
    $plugin_cmd = $2;
  }
  else {
    return undef;
  }
  $plugin_cmd = "" unless (defined $plugin_cmd);

  $_log->debug("Plugin: '$plugin', plugin_cmd: '$plugin_cmd'");
  my $plugin_session = undef;

  # get plugin session id...
  if (lc($plugin) ne 'agent') {
    $plugin_session = $self->_getPluginPoeSessionByName($plugin);
  }
  else {
    $plugin_session = $self->getSessionId();
  }

  unless ($plugin_session) {
    return undef;
  }

  $_log->debug("Will call POE session: $plugin_session.");
  my $x = $poe_kernel->post($plugin_session, $plugin_cmd, $postback, @args);

  if ($!) {
    $self->{_error} = "Error calling plugin POE session: $!";
    return undef;
  }

  return 1;
}

sub dumpStructure : State {
  my $self = shift;
  use Data::Dumper;
  return Dumper($self);
}

sub authenticate {
  my ($self, $user, $pass, $realm);
  my ($package, $filename, $line) = caller();
  my $poe = ($package =~ m/^POE::/);
  if ($poe) {
    ($self, $user, $pass, $realm) = @_[OBJECT, ARG0 .. $#_];
  }
  else {
    $self = shift;
    return $poe_kernel->call($self->getSessionId(), "authenticate", @_);
  }

}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _getPluginPoeSessionByName {
  my ($self, $name) = @_;
  return undef unless (defined $name && length($name) > 0);
  $name = lc($name);
  my $session = undef;

  map {
    if (lc($self->{__plugins}->{$_}->{driver}) eq $name)
    {
      $session = $_;
    }
  } keys %{$self->{__plugins}};

  unless (defined $session) {
    $self->{_error} = "Nonexistent plugin.";
  }

  return $session;
}

=item _loadClass ($name)

Tries to safely load class identified by B<$name>. Returns 1 on success, otherwise 0.

=cut

sub _loadClass {
  my $self   = shift;
  my $class  = shift;
  my $is_obj = (blessed($self) && $self->isa(__PACKAGE__)) ? 1 : 0;
  unless (defined $class && length($class) > 0) {
    my $str = "Undefined class name.";
    if ($is_obj) {
      $self->{_error} = $str;
    }
    else {
      $Error = $str;
    }
  }

  # check if class was already loaded...
  if (exists($_loaded_classes{$class})) {
    if ($is_obj) {
      $_log->debug("Class '$class' is already loaded, returning success.");
    }
    return 1;
  }

  $_log->debug("Loading class '$class'.") if ($is_obj);

  # try to load it...
  eval "require $class";

  if ($@) {
    my $str = "Unable to load class '$class': $@";
    $str =~ s/\s+$//g;
    if ($is_obj) {
      $self->{_error} = $str;
    }
    else {
      $Error = $str;
    }
    return 0;
  }

  $_log->debug("Class '$class' loaded successfully.") if ($is_obj);
  $_loaded_classes{$class} = 1;

  return 1;
}

sub sessionStart : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->debug("Starting POE session: " . $_[SESSION]->ID());
  $self->setSessionId($_[SESSION]->ID());

  # mark agent startup time
  $self->{_agentStarted} = CORE::time();

  # start stupid, nothing todo loop.
  $kernel->delay('_noop', 5);

  # install signal handlers...
  if ($self->{installSigHandlers}) {
    $_log->info("Installing signal handlers.");
    $kernel->sig("TERM", "_sighGeneric");
    $kernel->sig("INT",  "_sighGeneric");

    # register exception signal handler
    $kernel->sig("DIE", "_sighDIE");
  }

  # load mandatory plugins...
  unless ($self->_optionalPluginsLoad()) {
    $_log->error("Error loading optional plugins: " . $self->{_error});
    return $kernel->yield("shutdown");
  }

  # initialize connectors...
  unless ($self->_connectorsLoad()) {
    return $kernel->call("shutdown");
  }

  # initialize plugins...
  unless ($self->_pluginsLoad()) {
    return $kernel->yield("shutdown");
  }


  # set poe alias

=pod
	if (defined $self->{alias} && length($self->{alias})) {
		$_log->debug("Setting POE Session alias: " . $self->{alias});
		my $r = $kernel->alias_set($self->{alias});
		if ($r) {
			$_log->error("Error setting POE session alias '$self->{alias}': $!");
			# destroy ourselves...
			return $kernel->call("shutdown");
		}
	}
=cut

}

sub _child {
  my ($self, $reason, $child) = @_[OBJECT, ARG0, ARG1];
  my $ref = ref($self);

  # is some of our children gone?
  if ($reason eq 'lose') {
    my $id = $child->ID();

    # connector?!?
    if (exists($self->{__connectors}->{$id})) {
      my $driver = $self->{__connectors}->{$id}->{driver};
      $_log->info("Connector [$driver] session $id stopped, removing.");
      return $self->connectorUnload($id);

      #delete($self->{__connectors}->{$id});
    }

    # plugin?!?
    elsif (exists($self->{__plugins}->{$id})) {
      my $driver = $self->{__plugins}->{$id}->{driver};
      $_log->info("Plugin [$driver] session $id stopped, removing.");
      delete($self->{__plugins}->{$id});
    }

    # mandatory plugin
    elsif (exists($self->{__mandatory}->{$id})) {
      my $driver = $self->{__mandatory}->{$id}->{driver};
      $_log->info("Mandatory plugin [$driver] session $id stopped, removing.");
      delete($self->{__mandatory}->{$id});
    }
    else {
      $_log->debug("_child: Object $ref; Child POE session exit: $id.");
    }
  }
  else {
    if ($_log->is_debug()) {
      $_log->debug("_child: Object $ref; Reason: $reason; id: " . $child->ID());

      #$_log->debug("SESSION: ", Dumper($child));
    }
  }
}

# loads and initializes all plugins...
sub _pluginsLoad {
  my ($self) = @_;
  $_log->trace("Startup in session: ", $self->getSessionId());

  my $i = 0;
  foreach my $e (@{$self->{plugins}}) {

    # print "PLUGIN  DUMP: ", Dumper($e), "\n";
    # ignore bad settings...
    next unless (defined $e && ref($e) eq 'HASH');
    unless (exists($e->{driver}) && length($e->{driver})) {
      $_log->warn("Ignoring plugin configuration structure $i: no driver key.");
      next;
    }
    if (exists($e->{enabled}) && !$e->{enabled}) {
      $_log->debug("Skipping disabled plugin: $e->{driver}");
      next;
    }

    # try to load it...
    $_log->debug("Initializing plugin: $e->{driver}.");
    unless ($self->pluginInit($e->{driver}, %{$e->{params}})) {
      $_log->error("Error initializing plugin $e->{driver}: " . $self->getError());
      return 0;
    }

    $i++;
  }

  $_log->info("Successfully initialized $i plugin(s).");
  return 1;
}

# loads and initializes all connectors;
# returns 1 on success, otherwise 0
sub _connectorsLoad {
  my ($self) = @_;
  my $i = 0;
  $_log->trace("Startup in session: ", $self->getSessionId());
  foreach my $e (@{$self->{connectors}}) {

    # ignore bad settings...
    next unless (defined $e && ref($e) eq 'HASH');
    unless (exists($e->{driver}) && length($e->{driver})) {
      next;
    }

    $_log->debug("Initializing connector: $e->{driver} with params: ", join(", ", %{$e->{params}}));

    unless ($self->connectorInit($e->{driver}, %{$e->{params}})) {
      $_log->error("Unable to initialize connector: ", $self->getError());
      return 0;
    }

    $i++;
  }

  $_log->info("Successfully initialized $i connector(s).");
  return 1;
}

sub _noop : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # no connectors running?
  my $t = CORE::time();
  if ($self->{_agentStarted} < ($t + 4)) {
    unless (scalar(keys %{$self->{__connectors}}) > 0) {
      $_log->error("Agent has no connectors, shutting down.");

      #return 1;
      return $kernel->yield('shutdown');
    }
  }

  $kernel->delay_add("_noop", NOOP_DELAY);
}

# sigterm
sub _sighGeneric : State {
  my ($self, $kernel, $name) = @_[OBJECT, KERNEL, ARG0];
  $_log->info("Got SIG$name.");
  $kernel->yield("shutdown");
  $kernel->sig_handled();
}

sub _sighDIE : State {
  my ($self, $kernel, $sig, $ex) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  no warnings;
  $_log->error("Exception in file "
      . $ex->{file}
      . ", line "
      . $ex->{line}
      . "; Source session: "
      . $ex->{source_session}->ID()
      . ", event: "
      . $ex->{event}
      . "; From state: "
      . $ex->{from_state}
      . "; Destination session: "
      . $ex->{dest_session}->ID());
  $_log->error("Exception: " . $ex->{error_str});
  $kernel->sig_handled();
}

sub _optionalPluginsLoad {
  my ($self) = @_;

  # TODO: remove
  return 1;

  # don't load unless it's enabled
  return 1 unless ($self->{loadOptionalPlugins});

  my @tmp  = getpwuid($>);
  my $user = $tmp[0];
  $user = "undefined_user" unless (defined $user);
  $_log->info("Loading mandatory plugins.");

  my $session = undef;
  my $driver  = undef;
  my %opt     = ();
  my $i       = 0;

  # cache
  $_log->debug("Initializing mandatory plugin: Cache");
  $driver = "Cache";
  %opt    = (
    default_ttl    => $self->{cacheTtl},
    purge_interval => 5,
    store_interval => 60,
    cache_file     => File::Spec->catfile(File::Spec->tmpdir(), $user . "-agentd-cache.bin"),
  );
  $session = $self->pluginInit($driver, %opt);
  return 0 unless ($session);
  $self->{_cache} = $session;
  $i++;

  $_log->info("Loaded $i mandatory plugin(s).");
  return 1;
}

=head1 EXTENDING

tc agent is in fact POE-ized class, which can be simply extended to suit your
greedy needs.

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO
L<POE>
L<ACME::TC::Agent::Connector>
L<ACME::TC::Agent::Plugin>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
