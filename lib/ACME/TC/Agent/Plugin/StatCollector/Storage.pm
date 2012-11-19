package ACME::TC::Agent::Plugin::StatCollector::Storage;


use strict;
use warnings;

use POE;
use POE::Wheel::ReadWrite;

use IO::File;
use Data::Dumper;
use Log::Log4perl;
use Time::HiRes qw(time);
use File::Glob qw(:glob);
use Scalar::Util qw(blessed);

use ACME::Util::PoeSession;
use ACME::Util::ObjFactory;
use ACME::TC::Agent::Plugin::StatCollector::ParsedData;

use constant STORE_OK   => "storeDone";
use constant STORE_ERR  => "storeError";
use constant CLASS_DATA => 'ACME::TC::Agent::Plugin::StatCollector::ParsedData';

use vars qw(@ISA @EXPORT @EXPORT_OK);

@ISA = qw(
  Exporter
  ACME::Util::ObjFactory
  ACME::Util::PoeSession
);
@EXPORT    = qw(STORE_OK STORE_ERR);
@EXPORT_OK = qw();

our $VERSION = 0.04;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Storage

Abstract statistics storage implementation.

=head1 SYNOPSIS

 my $storage = ACME::TC::Agent::Plugin::StatCollector::Storage->factory(
 	$driver,
 	%opt
 );
 
 my $storage_session_id = $storage->spawn();
 
 $poe_kernel->post(
 	$storage_session_id,
 	'store',
 	$parsed_data_obj
 );

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

  bless($self, $class);
  $self->resetStatistics();
  $self->clearParams();
  $self->setParams(@_);

  $self->registerEvent(
    qw(
      run
      store
      storeError
      storeDone
      storeTimeout
      shutdown
      deferData
      deferCheck
      deferLoadFile
      resetStatistics
      _noop
      _deferFileInput
      _deferFileError
      _deferFileFlushed
      _deferWheelRemove
      )
  );

  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=over

=item B<name> (string, "<driver_name>")

Sets storage name.

=item B<deferEnabled> (boolean, 1):

Enable deferral of failed storage requests.

=item B<deferDir> (string, "/tmp"):

Directory for storing failed storage requests.

=item B<deferFileMode> (string, "0600"):

Permissions for deferred files.

=item B<deferCount> (integer, 1):

Maximum number of storage errors for each deferred data.

=item B<deferInterval> (integer, 0):

Check for deferred files in B<deferDir> every specified amount of seconds. If set to 0,
deferred file checking is disabled.

=item B<deferStartupCheck> (boolean, 0):

Check for deferred files on storage startup.

=item B<deferOnly> (boolean, 0):

Immediately defer requested data instead of actually storing them.

=item B<storeTimeout> (integer, 30): Maximum single storage request duration in seconds

=back

=cut

=head1 METHODS

Methods marked with B<[POE]> can be invoked as POE events.

=head2 getError ()

Returns last error accoured in this source.

=cut

sub getError {
  my $self = shift;
  return $self->{_error};
}

=head2 clearParams ()

Resets storage configuration to default values.

B<WARNING:> Storage configuration can be only reset prior to plugin startup (See method spawn()). 

Returns 1 on success, otherwise 0.

=cut

sub clearParams {
  my ($self) = @_;
  if ($self->{__storageIsStarted}) {
    $self->{_error} = "Unable to set configuration key(s): Storage is already started.";
    return 0;
  }

  # "public"

  # POE session alias
  # $self->{alias} = ref($self) . '_' . time() . '_' . rand();
  # $self->{alias} = rand();

  $self->{name}              = $self->getDriver();
  $self->{deferEnabled}      = 1;
  $self->{deferDir}          = "/tmp";
  $self->{deferFileMode}     = "0600";
  $self->{deferCount}        = 1;
  $self->{deferInterval}     = 0;
  $self->{deferStartupCheck} = 0;
  $self->{storeTimeout}      = 30;
  $self->{deferOnly}         = 0;

  # private stuff
  $self->{_error}               = "";       # last error message
  $self->{__stopping}           = 0;        # flag; storage is stopping
  $self->{__storageIsStarted}   = 0;        # this plugin is currently not started
  $self->{__collectorSessionId} = undef;    # StatCollector POE session ID

  # statistics
  $self->{__stats} = {};
  $self->resetStatistics();

  # store records...
  $self->{__data} = {};

  # defer stuff...
  $self->{__defer} = {};                    # defer file rw wheels

  # must return 1 on success
  return 1;
}

=head2 setParams (key => $value, key2 => $value2, ...)

Sets multiple parameters at once. Returns number of parameters successfully set. See also L<setParam()>.

=cut

sub setParams {
  my $self = shift;
  my $i    = 0;
  while (@_) {
    my $name  = shift;
    my $value = shift;
    $i += $self->setParam($name, $value);
  }

  return $i;
}

=head2 getParam ($name)

Returns value of param identified by $name.

=cut

sub getParam {
  my ($self, $name) = @_;
  return undef unless (defined $name && length($name) > 0 && $name !~ m/^_/);
  return $self->{$name};
}

=head2 setParam ($name, $value)

Sets parameter $name to value $value. Returns 1 on success, otherwise 0.

=cut

sub setParam {
  my ($self, $name, $value) = @_;
  unless (defined $name) {
    $self->{_error} = "Undefined parameter name.";
    return 0;
  }
  if ($name !~ m/^[a-z]+/) {
    $self->{_error} = "Invalid parameter name.";
    return 0;
  }
  unless (exists($self->{$name})) {
    $self->{_error} = "Nonexisting parameter: '$name'";
    return 0;
  }

  if ($_log->is_trace()) {
    $_log->trace("Setting param '$name' => '$value'");
  }

  $self->{$name} = $value;
  return 1;
}

sub dumpVar {
  shift if ($_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));
  my $d = Data::Dumper->new([@_]);
  $d->Terse(1);
  $d->Indent(0);
  return $d->Dump();
}

=head2 isStarted ()

Returns 1 if plugin was started using spawn() method, otherwise 0.

=cut

sub isStarted {
  my $self = shift;
  return $self->{__storageIsStarted};
}

=head2 generateStoreId ()

Generates and returns new fetch identificator string.

=cut

sub generateStoreId {
  my ($self) = @_;
  my $len    = 14;
  my $str    = "";

  while (length($str) < $len) {
    my $r = int(rand() * 43) + 48;
    if (($r >= 48 && $r <= 57) || ($r >= 65 && $r <= 90)) {
      $str .= chr($r);
    }
  }

  return $str;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  if ($self->isStarted()) {
    $_log->warn($self->getStorageSignature()
        . " POE session "
        . $_[SENDER]->ID()
        . " tried to start me twice! Ignoring.");
    return 0;
  }

  $_log->info($self->getStorageSignature() . " Starting storage.");

  # set proper name :)
  $self->setName($self->{name});

  # run implementation specific _run()
  unless ($self->_run()) {
    $_log->error($self->getStorageSignature()
        . " Error initializing implementation specific stuff: "
        . $self->getError());
    return $kernel->yield("shutdown");
  }

  if ($self->{deferOnly}) {
    $self->{deferInterval}     = 0;
    $self->{deferStartupCheck} = 0;
    $_log->warn($self->getStorageSignature()
        . " deferOnly in effect, disabling startup and periodic deferred file checking.");
  }

  # mark this source as started
  $self->{__storageIsStarted} = 1;

  # start inifinite loop
  $kernel->yield('_noop');

  # check for deferred files on storage startup...
  if ($self->{deferStartupCheck}) {
    $kernel->yield("deferCheck");
  }

  # stats...
  $self->{__stats}->{started} = time();

  $_log->info($self->getStorageSignature(), " Storage started, waiting for data.");
  return 1;
}

sub _noop {
  $_[KERNEL]->delay('_noop', 60);
}

=head2 store ($parsed_data) [POE]

Stores ParsedData object into implementation.

=cut

sub store {
  my ($self, $kernel, $data) = @_[OBJECT, KERNEL, ARG0];
  return 1 unless ($self->isStarted());

  # check received object...
  unless (defined $data && blessed($data) && $data->isa(CLASS_DATA)) {
    no warnings;
    $_log->warn($self->getStorageSignature()
        . "Got invalid record to store from POE session: "
        . $_[SENDER]->ID() . "/"
        . $_[STATE] . ": "
        . $data
        . "; Ignoring.");
    return 0;
  }
  unless ($data->isValid()) {
    $_log->warn($self->getStorageSignature()
        . "Got incomplete record to store from POE session: "
        . $_[SENDER]->ID() . "/"
        . $_[STATE] . ": "
        . $data->getError()
        . "; Ignoring.");
    return 0;
  }

  # generate store id...
  my $sid = $data->getId();

  # only defer file?
  if ($self->{deferEnabled} && $self->{deferOnly}) {
    $kernel->yield('deferData', $data);
    $kernel->yield(STORE_OK,    $sid);
    return 1;
  }

  $_log->debug($self->getStoreSig($sid), "Starting new storage operation.");

  # mark startup of fetching...
  my $ct = abs(time());

  # stat counters...
  $self->{__stats}->{storeStarted}++;

  # store object [ <object>, <store start time>, <alarmid> ]
  $self->{__data}->{$sid} = [$data, $ct, undef];

  # invoke real store function...
  my $r = $self->_store($sid, $data);

  # fetch start method failed?
  unless ($r) {

    # remove error alarms
    # $kernel->alarm("fetchError");
    $_log->error($self->getStoreSig($sid) . "Store request failed by implementation: " . $self->getError());

    # immediately schedule error event
    $kernel->yield("storeError", $sid, $self->getError());
  }

  # this storage request must be done in finite time!
  my $alarm_id = $kernel->alarm_set('storeTimeout', (abs(time()) + $self->{storeTimeout}), $sid);
  $self->{__data}->{$sid}->[2] = $alarm_id;

  return $r;
}

sub storeTimeout {
  my ($self, $kernel, $sid) = @_[OBJECT, KERNEL, ARG0];

  # storage must implement this method...
  unless ($self->_storeCancel($sid)) {
    $_log->error($self->getStoreSig($sid) . "Storage cancelation failed: " . $self->getError());
  }

  # report storage error
  $kernel->yield(STORE_ERR, $sid, "Storage didn't report in $self->{storeTimeout} second(s).");
}

sub _storeCancel {
  my ($self, $sid) = @_;
  return 0;
}

=head2 storeDone ($store_id, [$message [, $num_stored_keys]]) [POE]

Notifies storage implementation, that single parsed data storage was successful.

=cut

sub storeDone {
  my ($self, $kernel, $sid, $str, $num) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # don't waste precious time...
  return 0 unless (defined $sid && exists($self->{__data}->{$sid}));

  $str = '' unless (defined $str);

  # this event can come only from us...
#	unless ($_[SESSION]->ID() == $_[SENDER]->ID()) {
#		$_log->warn(
#			$self->getStorageSignature() .
#			"Got event 'storeDone' from POE session: " .
#			$_[SENDER]->ID() . " which is not my session (" .
#			$_[SESSION]->ID() . "); " .
#			"Ignoring."
#		);
#		return 0;
#	}

  my $start_time = 0;

  # destroy saved data object...
#	if (exists($self->{__data}->{$sid})) {
  # get start time...
  $start_time = $self->{__data}->{$sid}->[1];

  # remove store timeout alarm
  my $aid = $self->{__data}->{$sid}->[2];
  if (defined $aid) {

    # $_log->trace($self->getStoreSig($sid) ."canceling timeout alarm $aid.");
    $kernel->alarm_remove($aid);
  }

  # storage didn't report number of stored items?
  unless (defined $num) {
    $num = $self->{__data}->{$sid}->[0]->numKeys();
  }

  # destroy whole structure, we don't need it anymore...
  delete($self->{__data}->{$sid});

#	}

  my $duration = abs(time()) - $start_time;

  # time() sometimes returns weird time...
  if ($duration > $self->{storeTimeout}) {
    $_log->warn("[$sid] weird store OK duration: $duration; fixing.");
    $duration = $self->{storeTimeout};
  }
  $_log->info($self->getStoreSig($sid) . "Storage request done in " . sprintf("%-.3f", $duration),
    " second(s) [$str].");

  # update stats
  $self->_updateStats($duration, 1, $num);

  return 1;
}

=head2 storeError ($store_id, $message) [POE]

Notifies store that storing parsed data $store_id failed.

=cut

sub storeError {
  my ($self, $kernel, $sid, $err) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  # this event can come only from us...
#	unless ($_[SESSION]->ID() == $_[SENDER]->ID()) {
#		$_log->warn(
#			$self->getStorageSignature() .
#			" Got event 'storeError' from POE session: " .
#			$_[SENDER]->ID() . " which is not my session (" .
#			$_[SESSION]->ID() . "); " .
#			"Ignoring."
#		);
#		return 0;
#	}

  # don't waste precious time...
  return 0 unless (defined $sid && exists($self->{__data}->{$sid}));

  my $start_time = 0;

  # destroy saved data object...
#	if (exists($self->{__data}->{$sid})) {
  # get start time...
  $start_time = $self->{__data}->{$sid}->[1];

  # remove store timeout alarm
  my $aid = $self->{__data}->{$sid}->[2];
  if (defined $aid) {

    # $_log->trace($self->getStoreSig($sid) . "canceling timeout alarm $aid.");
    $kernel->alarm_remove($aid);
  }

#	}

  my $duration = abs(time()) - $start_time;
  if ($duration > $self->{storeTimeout}) {
    $_log->warn("[$sid] weird store ERR duration: $duration; fixing.");
    $duration = $self->{storeTimeout};
  }
  $_log->error($self->getStoreSig($sid)
      . "Storage request failed after "
      . sprintf("%-.3f", $duration)
      . " second(s): "
      . $err);

  # update stats
  $self->_updateStats($duration, 0);

  # defer this data object and remove reference to it...
  if (defined $self->{__data}->{$sid}->[0]) {
    $kernel->yield("deferData", $self->{__data}->{$sid}->[0]);
  }

  # destroy structure...
  delete($self->{__data}->{$sid});

  return 1;
}

=head2 shutdown () [POE]

Stops storage execution and frees all it's resources.

Returns 1 on success, otherwise 0.

=cut

sub shutdown {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  return 1 if ($self->{__stopping});
  $self->{__stopping} = 1;

  $_log->info($self->getStorageSignature() . " Shutting down.");

  # call subclass shutdown handler...
  $self->_shutdown();

  # defer all pending writes...
  map {
    $kernel->call("deferData", $self->{__data}->{$_});
    delete($self->{__data}->{$_});
  } keys %{$self->{__data}};

  # destroy defer wheels
  map {

    # try to flush the wheel
    eval {

      # allow max 20 flush attempts per wheel...
      my $i = 0;
      while ($i < 20 && $self->{__defer}->{$_}->{wheel}->get_driver_out_octets() > 0) {
        $i++;
        $self->{__defer}->{$_}->{wheel}->flush();
      }
    };

    # destroy the wheel
    delete($self->{__defer}->{$_});
  } keys %{$self->{__defer}};

  # remove alarms...
  $kernel->alarm_remove_all();

  # remove all current session aliases
  map { $kernel->alias_remove($_); } $kernel->alias_list($_[SESSION]);

  # get rid of external ref count
  # $kernel->refcount_decrement( $session, 'my ref name' );

  # propagate shutdown message to children
  # $kernel->call($child_session, "shutdown")...

  # we're not started anymore...
  $self->{__storageIsStarted} = 0;

  return 1;
}

=head2 getDriver ()

Returns implementation driver as string.

=cut

sub getDriver {
  my ($self) = @_;
  return $self->_getBasePackage();
}

=head2 getName ()

Returns storage name.

=cut

sub getName {
  my ($self) = @_;
  unless (defined $self->{name} && length($self->{name}) > 0) {
    return $self->getDriver();
  }

  return $self->{name};
}

=head2 setName ($name)

Sets storage name to $name. Returns 1 on success, otherwise 0.

=cut

sub setName {
  my ($self, $name) = @_;
  if ($self->{__storageIsStarted}) {
    $self->{_error} = "Unable to change name to already started storage.";
    return 0;
  }
  unless (defined $name && length($name)) {
    $self->{_error} = "Invalid name.";
    return 0;
  }

  # sanitize name...
  $name =~ s/[^\w\-]//g;

  $self->{name} = $name;
  return 1;
}

=head2 getStorageSignature ()

Returns current statistics data source signature as string. 

=cut

sub getStorageSignature {
  my ($self, $no_suffix) = @_;
  $no_suffix = 0 unless (defined $no_suffix);

  return "[" . $self->getName() . "]" . (($no_suffix) ? '' : ': ');
}

=head2 getStoreSig ($sid)

Returns store request $sig signature as string. Handy for logging.

=cut

sub getStoreSig {
  my ($self, $sid) = @_;
  no warnings;
  return '[' . $self->getName() . ' :: ' . $sid . ']: ';
}

=head2 getStatistics () [POE]

Returns object containing storage object statistics.

=cut

sub getStatistics {
  my ($self) = @_;
  my $data = {};

  # copy counter data...
  %{$data} = %{$self->{__stats}};

  # compute averages...
  $data->{timeStoreTotalAvg}
    = ($data->{numStoreTotal} != 0) ? ($data->{timeStoreTotal} / $data->{numStoreTotal}) : 0;
  $data->{timeStoreOkAvg}  = ($data->{numStoreOk} != 0)  ? ($data->{timeStoreOk} / $data->{numStoreOk})   : 0;
  $data->{timeStoreErrAvg} = ($data->{numStoreErr} != 0) ? ($data->{timeStoreErr} / $data->{numStoreErr}) : 0;
  $data->{successRatio}
    = ($data->{numStoreTotal} != 0)
    ? sprintf("%-.2f", ($data->{numStoreOk} / $data->{numStoreTotal}) * 100)
    : 0.00;

  $data->{storesPerSecond} = ($data->{timeStoreOk} != 0) ? ($data->{numStoreOk} / $data->{timeStoreOk}) : 0;
  $data->{keysPerSecond} = ($data->{timeStoreOk} != 0) ? ($data->{numStoredKeys} / $data->{timeStoreOk}) : 0;

  return $data;
}

=head2 resetStatististics () [POE]

Resets internal statistics counters.

=cut

sub resetStatistics {
  my ($self) = @_;
  $_log->debug($self->getStorageSignature(), " Reseting storage statistics counters.");
  $self->{__stats} = {
    numStoreTotal  => 0,
    numStoreOk     => 0,
    numStoreErr    => 0,
    numStoredKeys  => 0,
    timeStoreTotal => 0,
    timeStoreOk    => 0,
    timeStoreErr   => 0,
  };
}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 EXTENDING CLASS

You need to implement the following methods in your source
implementatations:

=head2 _run()

This method is called just after source startup in event B<run()> allowing you
to do some per-implementation specific stuff before fetching of data starts.

This method must return 1 if everything went fine, otherwise 0. In case of error
source session will stop immediately.

=cut

sub _run {
  return 1;
}

=head2 _store ($data)

=cut

sub _store {
  my ($self, $id, $data) = @_;
  $self->{_error} = "Class " . ref($self) . " does not implement _store() method.";
  return 0;
}

=head2 shutdown ()

As part of source shutdown process top level "shutdown" POE event handler calls
method B<_shutdown()> allowing you to cleanup your source resources and sub-poe sessions.

Return value of method is not checked at all.

=cut

sub _shutdown {
  my ($self) = @_;
  return 1;
}

# object destructor...
sub DESTROY {
  my ($self) = @_;
  if (defined $_log) {
    $_log->debug("Destroying: $self");
  }
  else {
    print STDERR "DESTROYING: $self\n";
  }
}

sub sessionStart {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # run the stuff...
  $kernel->yield("run");
}

sub _updateStats {
  my ($self, $duration, $ok, $num) = @_;
  $ok  = 1 unless (defined $ok);
  $num = 0 unless (defined $num);

  $self->{__stats}->{numStoreTotal}++;
  $self->{__stats}->{timeStoreTotal} += $duration;

  if ($ok) {
    $self->{__stats}->{numStoreOk}++;
    $self->{__stats}->{timeStoreOk}   += $duration;
    $self->{__stats}->{numStoredKeys} += $num;
  }
  else {
    $self->{__stats}->{numStoreErr}++;
    $self->{__stats}->{timeStoreErr} += $duration;
  }

  return 1;
}

=head2 _getBasePackage ([$pkg|$obj])

This is basename(3) perl for perl modules/object. Returns basename of plugin object... 

=cut

sub _getBasePackage {
  my ($self, $obj) = @_;
  $obj = $self unless (defined $obj);
  my @tmp = split(/::/, ref($obj));
  return pop(@tmp);
}

sub deferData {
  my ($self, $kernel, $data) = @_[OBJECT, KERNEL, ARG0];
  return 0 unless (defined $data);
  unless ($self->{deferEnabled}) {
    $_log->debug($data->getSignature(), " Deferrals are disabled, discarding object.");
    return 0;
  }

  # is defer count enabled?
  if ($self->{deferCount} > 0) {
    if ($data->getDeferCount() >= $self->{deferCount}) {
      $_log->warn($self->getStorageSignature()
          . " Data object "
          . $data->getId()
          . " was already deferred "
          . $data->getDeferCount()
          . " times; discarding object.");
      return 1;
    }

    # increment deferral count
    $data->incDeferCount();
  }

  # compute filename...
  my $id   = $data->getId();
  my $file = File::Spec->catfile($self->{deferDir},
    $self->getName() . '-' . $data->getFetchStartTime() . "-" . $id . ".deferred");

  # try to open file...
  $_log->debug($self->getStoreSig($id) . "Opening defer file $file for writing.");
  my $fd = IO::File->new($file, 'w');
  unless (defined $fd) {
    $_log->error($self->getStoreSig($id) . "Unable to open defer file $file for writing: $!");
    return 0;
  }

  # chmod the file
  unless (chmod(oct($self->{deferFileMode}), $file)) {
    $_log->warn($self->getStoreSig($id)
        . " Unable to change permissions to '$self->{deferFileMode}' on file $file: $!");
  }

  # create POE rw wheel...
  my $wheel = POE::Wheel::ReadWrite->new(
    Handle       => $fd,
    Filter       => POE::Filter::Stream->new(),
    FlushedEvent => "_deferFileFlushed",
    ErrorEvent   => "_deferFileError"
  );
  my $wid = $wheel->ID();
  $_log->debug($self->getStoreSig($id) . "Created RW wheel: $wid");

  # enqueue data writing...
  $wheel->put($data->toString());

  # save this wheel
  $self->{__defer}->{$wid} = {file => $file, id => $id, wheel => $wheel, mode => 1,};

  # assign alarm, that will remove wheel
  $kernel->alarm_set('_deferWheelRemove', (CORE::time() + 5), $wid);

  # now wait until all data is flushed...
  return 1;
}

sub _deferWheelRemove {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  return 0 unless (exists($self->{__defer}->{$wid}));

  # print "REMOVING WHEEL $wid\n";
  my $operation = ($self->{__defer}->{$wid}->{mode} == 1) ? 'write' : 'read';

  # emulate EOF (this is necessary only for POE::Loop::EVx event loop)
  $kernel->yield('_deferFileError', $operation, 0, "Success", $wid);
}

sub deferCheck {
  my ($self, $kernel) = @_[OBJECT, KERNEL, ARG0];

  # sometimes this method is simply disabled...
  return 1 if (!$self->{deferEnabled} || $self->{deferOnly});

  $_log->info($self->getStorageSignature() . " Checking for deferred files.");

  my $ts = time();

  # build glob prefix...
  my $glob_str = File::Spec->catfile($self->{deferDir}, '*.deferred');
  $_log->debug($self->getStorageSignature() . " Looking for deferred files using glob pattern: $glob_str");

  # run tha glob!
  my @files = bsd_glob($glob_str, GLOB_ERR);

  # check for injuries
  if (GLOB_ERROR) {
    $_log->error(
      $self->getStorageSignature() . " Error looking for deferred files using glob pattern $glob_str: $!");
    goto outta_check_defer;
  }

  my $defer_chunk_offset = 5;
  my $deferral_int_add   = 1;

  # check && enqueue found files
  if (@files) {

    my $defer_load_time_offset = 0;
    my $j                      = 0;
    my $num                    = 0;
    while (@files) {
      $j++;
      my $i = 0;
      while ($i < 100) {
        $i++;
        my $file = shift(@files);
        last unless (defined $file);
        $num++;
        $kernel->delay_add('deferLoadFile', $defer_load_time_offset, $file);
      }
      $_log->info($self->getStorageSignature()
          . " Scheduled loading of $i deferred files in "
          . $defer_load_time_offset
          . " seconds.");
      $defer_load_time_offset += 6;
    }

    $deferral_int_add = $j * $defer_chunk_offset;
    $_log->info($self->getStorageSignature() . " Enqueued loading of $num deferred file(s).");
  }

outta_check_defer:

  # run ourselves again
  my $duration = time() - $ts;
  $_log->info(
    $self->getStorageSignature() . " Defer check done in " . sprintf("%-.3f msec.", ($duration * 1000)));

  # re-enqueue ourselves...
  if (defined $self->{deferInterval} && $self->{deferInterval} > 0) {

    # defer int add shouldn' be greater than 10 minutes...
    $deferral_int_add = 600 if ($deferral_int_add > 600);
    my $time_offset = $self->{deferInterval} + $deferral_int_add;
    $_log->info(
      $self->getStorageSignature() . " Scheduling next deferred file checking in $time_offset seconds.");
    $kernel->delay("deferCheck", $time_offset);
  }
  else {
    $_log->warn($self->getStorageSignature()
        . " Periodic deferred file checking is disabled - limited to storage startup only.");
  }
}

sub deferLoadFile {
  my ($self, $kernel, $file) = @_[OBJECT, KERNEL, ARG0];

  # check file...
  unless (defined $file) {
    $_log->error($self->getStorageSignature() . " Got undefined defer file.");
    return 0;
  }
  unless (-f $file && -r $file) {
    $_log->error($self->getStorageSignature() . " Got non-existing or unreadable file: $file");
    return 0;
  }

  $_log->trace($self->getStorageSignature() . " Loading deferred file: $file");

  # open file...
  my $fd = IO::File->new($file, 'r');
  unless (defined $fd) {
    $_log->error($self->getStorageSignature() . " Unable to load deferred file $file: $!");
    return 0;
  }

  # create rw wheel...
  my $wheel = POE::Wheel::ReadWrite->new(
    Handle     => $fd,
    Filter     => POE::Filter::Stream->new(),
    InputEvent => "_deferFileInput",
    ErrorEvent => "_deferFileError"
  );
  my $wid = $wheel->ID();
  $_log->debug($self->getStorageSignature() . " Created RW wheel: $wid");

  # save this wheel
  $self->{__defer}->{$wid} = {
    file  => $file,
    wheel => $wheel,
    data  => '',        # data...
    ts    => time(),    # file load started...
    mode  => 0,
  };

  # assign alarm, that will remove wheel
  $kernel->alarm_set('_deferWheelRemove', (CORE::time() + 5), $wid);

  # now just wait for input data...
  return 1;
}

sub _deferFileInput {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  return 0 unless (exists($self->{__defer}->{$wid}));

  # append read data...
  $self->{__defer}->{$wid}->{data} .= $data;
}

sub _deferFileFlushed {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  return 0 unless (exists($self->{__defer}->{$wid}));

  my $id   = $self->{__defer}->{$wid}->{id};
  my $file = $self->{__defer}->{$wid}->{file};
  $_log->trace($self->getStoreSig($id) . "Defer file $file wheel $wid flushed, closing.");

  # destroy the wheel
  delete($self->{__defer}->{$wid});

  # this is it...
  return 1;
}

sub _deferFileError {
  my ($self, $kernel, $operation, $errnum, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. ARG3];
  return 0 unless (exists($self->{__defer}->{$wid}));

  my $file = $self->{__defer}->{$wid}->{file};

  # we were reading? if errno == 0
  # this means EOF!
  if ($errnum == 0) {
    if ($operation eq 'read') {
      $_log->trace($self->getStorageSignature() . " Finished reading deferred file " . $file);

      # de-serialize input...
      $self->_deferFileThaw($wid);

      # time to remove deferred file...
      unless (unlink($file)) {
        $_log->error($self->getStorageSignature() . " Unable to delete read deferred file $file: $!");
      }
    }
  }
  else {
    my $id = $self->{__defer}->{$wid}->{id};
    $_log->error($self->getStoreSig($id)
        . "Got errno $errnum while running operation $operation while deferring file $file: $errstr");
  }

  # destroy the wheel
  # print "REALLY DESTROYING WID: $wid\n";
  delete($self->{__defer}->{$wid});

  # this is it...
  return 1;
}

sub _deferFileThaw {
  my ($self, $wid) = @_;
  return 0 unless (exists($self->{__defer}->{$wid}));

  # no data?
  return 0 unless (defined $self->{__defer}->{$wid}->{data} && length($self->{__defer}->{$wid}->{data}) > 0);

  my $file = $self->{__defer}->{$wid}->{file};

  # try to evaluate raw data into object...
  if ($_log->is_trace()) {
    $_log->trace(
      $self->getStorageSignature() . " --- BEGIN DEFERRED DATA ---\n" . $self->{__defer}->{$wid}->{data});
    $_log->trace($self->getStorageSignature() . " --- END DEFERRED DATA ---");
  }

  #$_log->trace("Begin eval done.");
  my $obj = eval $self->{__defer}->{$wid}->{data};

  #$_log->trace("Eval done, got $obj");

  # check for injuries
  if ($@) {
    $_log->error($self->getStorageSignature() . " Unable to evaluate deferred file $file: $@");
  }
  elsif (!defined $obj) {
    $_log->error($self->getStorageSignature() . " Invalid data in deferred file $file");
  }
  elsif (!blessed($obj) || !$obj->isa(CLASS_DATA)) {
    $_log->error(
      $self->getStorageSignature() . " Invalid data in deferred file: Returned object is not " . CLASS_DATA);
  }
  else {

    # data object is ok!!!

    # enqueue storage...
    $_log->debug($self->getStorageSignature()
        . " Re-enqueued storage request for deferred data: "
        . $obj->getSignature());
    $poe_kernel->yield("store", $obj);
  }

  my $duration = time() - $self->{__defer}->{$wid}->{ts};
  $_log->debug($self->getStorageSignature()
      . " Defer file $file loaded and evaluated in "
      . sprintf("%-.3f", $duration)
      . " msec.");

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Plugin>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
