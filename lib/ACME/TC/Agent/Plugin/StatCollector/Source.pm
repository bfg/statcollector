package ACME::TC::Agent::Plugin::StatCollector::Source;


use strict;
use warnings;

use POE;

use Log::Log4perl;
use Time::HiRes qw(time);
use Scalar::Util qw(blessed);

use ACME::Util::ObjFactory;
use ACME::Util::PoeSession;
use ACME::TC::Agent::Plugin::StatCollector::RawData;

use constant CHECK_INTERVAL_DIFF       => 0.1;
use constant DEFAULT_PARSER_NAME       => 'DEFAULT';
use constant DEFAULT_FILTER_NAME       => '';
use constant DEFAULT_STORAGE_NAME      => '';
use constant DEFAULT_SOURCE_GROUP_NAME => 'DEFAULT';

use constant FETCH_OK  => "fetchDone";
use constant FETCH_ERR => "fetchError";

use vars qw(@ISA @EXPORT @EXPORT_OK);

@ISA = qw(
  Exporter
  ACME::Util::ObjFactory
  ACME::Util::PoeSession
);

@EXPORT    = qw(FETCH_OK FETCH_ERR);
@EXPORT_OK = qw();

our $VERSION = 0.11;

my $Error = "";

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Source

Abstract statistics source.

=head1 SYNOPSIS

B<WARNING:> This class is not intended for stand-alone use.

 # select driver and options
 my $driver = "DUMMY";
 my %opt = (
 	checkInterval => 20,
 	checkTimeout => 2,
 );
 
 # create source object
 my $obj = ACME::TC::Agent::Plugin::StatCollector::Source->factory(
 	$driver,
 	%opt,
 )
 unless (defined $obj) {
 	die "Error creating source: ", ACME::TC::Agent::Plugin::StatCollector::Source->getError();
 }
 
 # start source!
 my $id = $obj->spawn();
 unless ($id) {
 	die "Error starting source: " . $obj->getError();
 }
 
 # stop the source
 $poe_kernel->post($id, "shutdown");

=head1 DESCRIPTION

This is top-level implementation of abstract statistics source, which is checked for new data every
specified amount of time. Real implementation of statistics data retrieval is left to implementation
classes. See L<ACME::TC::Agent::Plugin::StatCollector::Source::DUMMY> for simple implementation
details.   

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

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
  $self->{_error} = "";

  bless($self, $class);
  $self->resetStatistics();

  $self->registerEvent(
    qw(
      run
      fetchStart
      fetchError
      fetchDone
      getStatistics
      resetStatistics
      pause
      resume
      shutdown
      )
  );

  $self->clearParams();
  $self->setParams(@_);

  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts the following named parameters:

=over

=item B<checkInterval> (float, 15.0):

Check this source for new statistics every specified number of seconds.

=item B<checkTimeout> (float, 5.0):

Source must deliver statistics data within specified number of seconds.

=item B<useParser> (string, "DEFAULT")

Name of initialized parser in StatCollector agent plugin that should parse raw plugin
response.

=item B<useFilter> (string, "")

Comma or semicolon separated string of filter names intialized in StatCollector agent plugin
that will filter parsed output.

=item B<useStorage> (string, "")

Comma or semicolon separated list of storage names initialized in StatCollector agent plugin
that will store parsed and filtered ouput of this source. If not specified (default)
Statcollector will try to store returned data to all available storages.

=item B<forceHostname> (string, undef)

Forced hostname for returned data.

=item B<forcePort> (integer, undef)

Forced port for returned data.

=item B<startupDelay> (float, 0)

Defer source startup for random value between 0 and specified value. Set this to value
less than checkInterval. If this property is set to 0, then source will be started
up immediately after object creation.

=item B<maxErrorsInRow> (integer, 100)

If set to non-zero positive value, source will pause itself for B<errorResumePause>
seconds if specified number of fetches will fail in a row sequentially. Source will
then resume itself and will try again.

=item B<errorResumePause> (integer, 300)

If property B<maxErrorsInRow> is set to non-zero value, then source will be paused
for specified amount of seconds in case that B<maxErrorsInRow> fetches failes sequentially.

=item B<sourceGroup> (string, "DEFAULT")

Mark this source as part of specified group. This only affects output of
web status interface.

=item B<startupDelay> (integer, 10)

Delay source startup for random amount of seconds up to specified value of this
parameter. Value of 0 disables delayed source startup.

=item B<forceContent> (string, undef)

Force specified raw content if source successfully fetched data. Use this property
if you don't care about fetched data and you're interested only if fetch succeeded.
Example use case scenario would be source fetch time monitoring; fetch duration can
be extracted by using custom filters.

If you decide to force returned content, you probably want to pass string
"xxx: 1" and then use default parser to do the parsing job and then apply B<FetchMeta>
filter to add fetch variables.

See documentation for:
  ACME::TC::Agent::Plugin::StatCollector::Filter::FetchMeta
  ACME::TC::Agent::Plugin::StatCollector::Filter
  ACME::TC::Agent::Plugin::StatCollector::Filter::CODE
  ACME::TC::Agent::Plugin::StatCollector::RawData
  ACME::TC::Agent::Plugin::StatCollector::ParsedData

=item B<debugRawData> (boolean, 0)

Write raw fetched data to log without setting log4perl logging level to TRACE. Warning:
Generates LOTS of logging output.

=item B<debugParsedData> (boolean, 0)

Write parsed data to log without setting log4perl logging level to TRACE. Warning:
Generates LOTS of logging output.

=back

=head2 clearParams ()

Resets source configuration to default values.

B<WARNING:> Plugin configuration can be only reset prior to plugin startup (See method spawn()). 

Returns 1 on success, otherwise 0.

=cut

sub clearParams {
  my ($self) = @_;
  if ($self->{__sourceIsStarted}) {
    $self->{_error} = "Unable to set configuration key(s): Source is already started.";
    return 0;
  }

  # "public" settings
  $self->{checkInterval}    = 15;
  $self->{checkTimeout}     = 5;
  $self->{useParser}        = DEFAULT_PARSER_NAME;
  $self->{useFilter}        = DEFAULT_FILTER_NAME;
  $self->{useStorage}       = DEFAULT_STORAGE_NAME;
  $self->{maxErrorsInRow}   = 100;
  $self->{errorResumePause} = 300;
  $self->{sourceGroup}      = DEFAULT_SOURCE_GROUP_NAME;
  $self->{forceHostname}    = undef;
  $self->{forcePort}        = undef;
  $self->{startupDelay}     = 10;
  $self->{debugRawData}     = 0;
  $self->{debugParsedData}  = 0;
  $self->{forceContent}     = undef;

  # private settings
  $self->{_error}              = "";       # last error message
  $self->{_fetchId}            = undef;    # current fetch Id.
  $self->{__sourceIsStarted}   = 0;        # this source is currently not started
  $self->{__sourceIsRunning}   = 0;        # this source is currently not started
  $self->{_collectorSessionId} = undef;    # StatCollector POE session ID
  $self->{__seqErrs}           = 0;        # number of sequential errors

  # returned data chains...
  $self->{__parsers} = [];                 # parser chain
  $self->{__filters} = [];                 # filter chain
  $self->{__storage} = [];                 # storage chain

  # statistics
  $self->{_stats} = {};
  $self->{_stats}->{started} = 0;
  $self->resetStatistics();

  # must return 1 on success
  return 1;
}

=head1 METHODS

Methods marked with B<[POE]> can be invoked as POE events.

=head2 getError()

Returns last error accoured in this source.

=cut

sub getError {
  my $self = shift;

  unless (blessed($self) && $self->isa(__PACKAGE__)) {
    return $Error;
  }

  return $self->{_error};
}

=head2 setParams (key => val, key2 => val2)

Sets plugin configuration parameter(s).

B<WARNING:> Source configuration can be only set prior to plugin startup (See method spawn()). 

Returns number of configuration keys actually set.

=cut

sub setParams {
  my $self = shift;
  if ($self->{__sourceIsStarted}) {
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

sub getParam {
  my ($self, $name) = @_;
  return undef unless (defined $name && length($name) > 0 && $name !~ m/^_/);
  return $self->{$name};
}

=head2 getSourceGroup ()

Returns group name as string that this source belongs to.

=cut

sub getSourceGroup {
  my ($self) = @_;
  return $self->{sourceGroup};
}

=head2 isStarted ()

Returns 1 if source was started using spawn() method, otherwise 0.

=cut

sub isStarted {
  my $self = shift;
  return $self->{__sourceIsStarted};
}

=head2 isRunning () [POE]

Returns 1 if source is started and is not paused (is running).

=cut

sub isRunning {
  my $self = shift;
  return ($self->{__sourceIsStarted} && $self->{__sourceIsRunning}) ? 1 : 0;
}

sub setCollectorRef {
  my ($self, $ref) = @_;
  $self->{__collectorRef} = $ref;
}

sub getCollectorRef {
  my ($self, $ref) = @_;
  return $self->{__collectorRef};
}


=head2 run () [POE]

This method/POE event is invoked just after source startup.
B<WARNING:> Don't invoke this method/event UNLESS YOU REALLY KNOW WHAT YOU'RE DOING!

=cut

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # don't start it twice
  return 1 if ($self->{__sourceIsStarted});

  # $_log->info("Source '" . $self->_getBasePackage() . "' startup.");

  # force numbers...
  {
    no warnings;
    $self->{checkInterval} += 0;
    $self->{checkTimeout}  += 0;
  }

  $_log->info($self->getSourceSignature() . " "
      . "Starting source; check interval "
      . sprintf("%-.3f", $self->{checkInterval}) . " sec;"
      . " check timeout "
      . sprintf("%-.3f", $self->{checkTimeout})
      . " sec.");

  # check checkInterval and checkTimeout...
  unless ($self->{checkInterval} > 0) {
    $_log->error($self->getSourceSignature() . " Property checkInterval must be positive float.");
    return $kernel->yield("shutdown");
  }
  unless ($self->{checkTimeout} > 0) {
    $_log->error($self->getSourceSignature() . " Property checkTimeout must be positive float.");
    return $kernel->yield("shutdown");
  }

  # check interval must be greater than checktimeout
  # for at least one one second
  if (($self->{checkTimeout} + CHECK_INTERVAL_DIFF) > $self->{checkInterval}) {
    $_log->error($self->getSourceSignature()
        . " Property checkInterval must be at least "
        . sprintf("%-.3f", CHECK_INTERVAL_DIFF)
        . " second(s) greater than checkTimeout.");
    return $kernel->yield("shutdown");
  }

  # fix error resume pause if necessary...
  unless ($self->{errorResumePause} >= 60) {
    $_log->info(
      $self->getSourceSignature() . " Property errorResumePause is lower than 60 seconds. Overriding.");
    $self->{errorResumePause} = 60;
  }

  # check forced hostname...
  if (defined $self->{forceHostname}) {
    $self->{forceHostname} =~ s/^\s+//g;
    $self->{forceHostname} =~ s/\s+$//g;
    if (length($self->{forceHostname}) > 0) {
      $_log->warn(
        $self->getSourceSignature() . " Setting forced returned data hostname to: '$self->{forceHostname}'.");
    }
    else {
      $self->{forceHostname} = undef;
    }
  }

  # check parsers...
  unless ($self->_checkParsers()) {
    return $kernel->yield('shutdown');
  }

  # check filters...
  unless ($self->_checkFilters()) {
    return $kernel->yield('shutdown');
  }

  # check storages...
  unless ($self->_checkStorages()) {
    return $kernel->yield('shutdown');
  }

  # run implementation specific _run()
  unless ($self->_run()) {
    $_log->error($self->getSourceSignature()
        . " Error initializing implementation specific stuff: "
        . $self->getError());
    return $kernel->yield("shutdown");
  }

  # mark this source as started
  $self->{__sourceIsStarted} = 1;
  $self->{__sourceIsRunning} = 1;

  # stats...
  $self->{_stats}->{started} = time();

  # schedule fetch
  $kernel->yield("fetchStart");

  return 1;
}

=head2 getFetchId ()

Returns current statistics fetch identificator string.

=cut

sub getFetchId {
  my ($self) = @_;
  return $self->{_fetchId};
}

=head2 setFetchId ($str)

Sets specified string as current fetch identificator string.
B<WARNING:> Don't invoke this method UNLESS YOU REALLY KNOW WHAT YOU'RE DOING!

=cut

sub setFetchId {
  my ($self, $id) = @_;
  $self->{_fetchId} = $id;
  return 1;
}

=head2 generateFetchId ()

Generates and returns new fetch identificator string.

=cut

sub generateFetchId {
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

=head2 getDriver ()

Returns implementation driver as string.

=cut

sub getDriver {
  my ($self) = @_;
  return $self->_getBasePackage();
}

=head2 getSourceSignature ()

Returns current statistics data source signature as string. 

=cut

sub getSourceSignature {
  my ($self) = @_;
  no warnings;
  return "[" . $self->getDriver() . " :: " . $self->getFetchUrl() . "]";
}

=head2 getFetchSignature ()

Returns current statistics fetch signature as string. 

=cut

sub getFetchSignature {
  my ($self) = @_;
  no warnings;
  return "[" . $self->getFetchId() . " :: " . $self->getDriver() . " :: " . $self->getFetchUrl() . "]";
}

=head2 fetchStart () [POE only]

This event starts every data retrieval and invokes B<_fetchStart()> method from implementing class.

B<WARNING:> Don't invoke this method/event UNLESS YOU REALLY KNOW WHAT YOU'RE DOING! 

=cut

sub fetchStart {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  return 1 unless ($self->isStarted());

  # generate fetch id...
  my $fid = $self->generateFetchId();
  $self->setFetchId($fid);

  # clear any current timers...
  # $kernel->alarm_remove_all();

  $_log->debug($self->getFetchSignature(), " Starting new fetch.");

  # mark startup of fetching...
  my $ct = time();
  $self->{_timeFetchStarted} = $ct;

  # create alarm timer!
  $kernel->alarm(
    "fetchError",
    ($ct + $self->{checkTimeout}),
    "Fetch timeout exceeded [" . sprintf("%-.3f sec", $self->{checkTimeout}) . "]."
  );

  # stat counters...
  # $self->{_stats}->{fetchStarted}++;

  # invoke real fetch function...
  my $r = $self->_fetchStart();

  # fetch start method failed?
  unless ($r) {

    # remove error alarms
    $kernel->alarm("fetchError");

    # immediately schedule error event
    my $err = $self->getError();
    if (defined $err && length($err) > 0) {
      $err = "Unable to start statistics fetch: " . $err;
    }
    else {
      $err = "Source implementation " . ref($self) . " method _fetchStart() returned 0,";
      $err .= " but without error message. This is a BUG!!!";
    }
    $kernel->yield("fetchError", $err);
  }

  return $r;
}

=head2 fetchDone ($raw_data, [$forced_hostname = undef [, $forced_port = undef]]) [POE only]

This POE event must be called from implementing class in case of successfull statistics data retrieval.
Argument must be initialized L<ACME::TC::Agent::Plugin::StatCollector::DataContainer> object.
This method will then parse and store container data and enqueue new statistics data fetch.

=cut

sub fetchDone {
  my ($self, $kernel, $raw_data, $hostname, $port) = @_[OBJECT, KERNEL, ARG0, ARG1];
  return 1 unless ($self->isStarted());

  # clear timeout alarm timer; fetch
  # was abvious successfull...
  $kernel->alarm("fetchError");

  # clear sequential error counter...
  $self->{__seqErrs} = 0;

  # how long did this fetch take?
  my $ct       = time();
  my $duration = ($ct - $self->{_timeFetchStarted});

  my $delay = 0;
  if ($duration >= $self->{checkInterval}) {
    $delay = $self->{checkInterval} + int(rand(60));
    $_log->warn($self->getFetchSignature()
        . " Fetch duration was longer than checkInterval "
        . sprintf("(%-.3f >= %-.3f); ", $duration, $self->{checkInterval})
        . "scheduling next fetch in $delay second.");

    #$delay = 1;
  }
  else {
    $delay = $self->{checkInterval} - $duration;
  }

  # forced data flag.
  my $forced = '';

  # do something with fetched data...
  if (!defined $raw_data) {
    $_log->error($self->getFetchSignature()
        . " Class "
        . ref($self)
        . " called invoked fetchDone() with no raw data. THIS IS A BUG!");
    $kernel->yield('shutdown');
  }
  else {

    # forced content in effect?
    if (defined $self->{forceContent} && length($self->{forceContent}) > 0) {
      $_log->debug("Applying forced content.");
      $raw_data = $self->{forceContent};
      $forced   = 1;
    }

    if ($self->{debugRawData}) {
      $_log->info($self->getFetchSignature(), "--- BEGIN RECEIVED DATA ---" . "\n" . $raw_data);
      $_log->info($self->getFetchSignature(), "--- END RECEIVED DATA ---");
    }
    elsif ($_log->is_trace()) {
      $_log->trace($self->getFetchSignature(), "--- BEGIN RECEIVED DATA ---" . "\n" . $raw_data);
      $_log->trace($self->getFetchSignature(), "--- END RECEIVED DATA ---");
    }

    # Post this data to base plugin
    my $sid = $self->getCollectorPoeSession();
    if (!$sid) {
      $_log->error("Unable post source fetched data to StatCollector: " . $self->getError());
    }
    else {

      # create raw data harness object...
      my $data = ACME::TC::Agent::Plugin::StatCollector::RawData->new();

      # add content and other data...
      $data->setContent($raw_data);
      $data->setFetchStartTime($self->{_timeFetchStarted});
      $data->setFetchDoneTime($ct);
      $data->setUrl($self->getFetchUrl());
      $data->setId($self->getFetchId());
      $data->setDriver($self->getDriver());
      $data->setDebugParsedData($self->{debugParsedData});

      # add parser, filter and storage info
      $data->setParser($self->_getParsers());
      $data->setFilter($self->_getFilters());
      $data->setStorage($self->_getStorages());

      # data HOSTNAME
      # forced hostname?
      if (defined $self->{forceHostname}) {
        $data->setHost($self->{forceHostname});
      }

      # did source provide hostname?
      elsif (defined $hostname && length($hostname) > 0) {
        $data->setHost($hostname);
      }

      # ask ourselves for hostname
      else {
        $data->setHost($self->getHostname());
      }

      # data PORT NUMBER
      if (defined $self->{forcePort}) {
        $data->setPort($self->{forcePort});
      }
      elsif (defined $port) {
        $data->setPort($port);
      }
      else {
        $data->setPort($self->getPort());
      }

      # post raw data object to stat collector - it will
      # take care about parsing and storing...
      $_log->debug($self->getFetchSignature(), " Posting data to StatCollector POE session $sid.");
      unless ($kernel->post($sid, "sourceGotData", $data)) {
        $_log->error($self->getFetchSignature(),
          " Error posting data to StatCollector POE session id $sid: $!");
      }
    }
  }

  # reschedule next fetch...
  $kernel->delay_add("fetchStart", $delay);

  my $len = length($raw_data);
  $_log->info($self->getFetchSignature(),
        " Retrieved result ["
      . (($forced) ? 'forced ' : '')
      . "$len bytes] in "
      . sprintf("%-.3f", $duration)
      . " second(s); "
      . "next fetch will start in "
      . sprintf("%-.3f", $delay)
      . " second(s).");

  # update statistics...
  $self->_updateStats($duration, 1);

  # invalidate current fetch id.
  $self->setFetchId();

  return 1;
}

=head2 fetchError ($error) [POE only]

This event must be called from implementing class in case statistics data retrieval failed. Argument
must be an error message as string. This method runs implementation specific B<_fetchCancel()> method
as part of error processing.

B<NOTICE>: This event is automatically triggered in case if real implementation
doesn't invoke fetchDone() or fetchError() in B<checkTimeout> amount of seconds.

New statistics data fetch is enqueued after error processing is done.

=cut

sub fetchError {
  my ($self, $kernel, $error) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  return 1 unless ($self->isStarted());
  $_log->error($self->getFetchSignature(), " ERROR: $error");

  # remove all pending alarms...
  # $kernel->alarm_remove_all();
  $kernel->alarm('fetchError');

  # cancel current request (this must be done by implementation)
  unless ($self->_fetchCancel()) {
    $_log->error("Unable to cancel current request: " . $self->getError());

    # shutdown this source
    $kernel->yield("shutdown");

    return 1;
  }

  # reschedule fetch
  my $ct       = time();
  my $duration = ($ct - $self->{_timeFetchStarted});

  # stat counters
  $self->_updateStats($duration, 0);

  # too many errors in a row?
  $self->{__seqErrs}++;
  if ($self->{maxErrorsInRow} > 0) {
    if ($self->{__seqErrs} >= $self->{maxErrorsInRow}) {
      $_log->warn(
        $self->getSourceSignature(),
        " Too many failed fetches in a row ($self->{__seqErrs}); ",
        "pausing source for $self->{errorResumePause} seconds."
      );

      $kernel->yield("pause");
      $kernel->delay("resume", $self->{errorResumePause});

      # clear sequential error counter...
      $self->{__seqErrs} = 0;
      return 1;
    }
  }

  # fetch duration > checkInterval?
  my $delay = 0;
  if ($duration >= $self->{checkInterval}) {
    $delay = $self->{checkInterval} + int(rand(60));
    $_log->warn($self->getFetchSignature()
        . " Fetch duration was longer than checkInterval "
        . sprintf("(%-.3f >= %-.3f); ", $duration, $self->{checkInterval})
        . "scheduling next fetch in $delay second.");

    #$delay = 1;
  }
  else {
    $delay = $self->{checkInterval} - $duration;
  }

  # reschedule next fetch...
  $kernel->delay_add("fetchStart", $delay);

  $_log->error($self->getFetchSignature(),
        " Retrieved error response in "
      . sprintf("%-.3f", $duration)
      . " second(s); "
      . "next fetch will start in "
      . sprintf("%-.3f", $delay)
      . " second(s).");

  # invalidate current internal fetch id.
  $self->setFetchId();

  return 1;
}

=head2 pause () [POE only]

Pauses source. Source is not stopped, but paused, it can be resumed by invoking
L<resume()> POE event.

Returns 1 on success, otherwise 0.

=cut

sub pause {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  unless ($self->{__sourceIsRunning}) {
    $self->{_error} = "Source is already paused.";
    return 0;
  }

  $_log->debug($self->getSourceSignature(), " Pausing source.");

  # cancel current request (this must be done by implementation)
  unless ($self->_fetchCancel()) {
    $_log->error("Unable to cancel current request: " . $self->getError());

    # shutdown this source
    $kernel->yield("shutdown");

    return 1;
  }

  # remove alarms...
  # $kernel->alarm_remove_all();

  # mark as paused...
  $self->{__sourceIsRunning} = 0;

  # log action...
  $_log->info($self->getSourceSignature(), " Source paused.");

  return 1;
}

=head2 resume () [POE only]

Resumes previous paused source.

=cut

sub resume {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  if ($self->{__sourceIsRunning}) {
    $self->{_error} = "Source is already running.";
    return 0;
  }

  # remove all alarms...
  $kernel->alarm_remove_all();

  # reset statistics...
  $self->resetStatistics();

  # mark as running...
  $self->{__sourceIsRunning} = 1;

  # set startup time...
  $self->{_stats}->{started} = time();

  # schedule fetch
  $kernel->yield("fetchStart");

  # log action...
  $_log->info($self->getSourceSignature(), " Source resumed.");
  return 1;
}

=head2 getCollectorPoeSession ()

Returns POE session ID of StatCollector plugin on success as positive integer on success, otherwise
returns 0.

=cut

sub getCollectorPoeSession {
  my ($self) = @_;
  unless (defined $self->{_collectorSessionId}) {
    $self->{_error} = "StatCollector POE session id is not set.";
    return 0;
  }
  return $self->{_collectorSessionId};
}

=head2 setCollectorPoeSession ($id)

Sets StatCollector POE session ID. This id is needed for communication between source
and StatCollector plugin. This method can be invoked only once, each subsequent invocation
will fail.

Returns 1 on success, otherwise 0.

B<WARNING:> Don't invoke this method UNLESS YOU REALLY KNOW WHAT YOU'RE DOING!

=cut

sub setCollectorPoeSession {
  my ($self, $id) = @_;
  unless (defined $id && $id =~ m/^\d+$/ && $id > 0) {
    $self->{_error} = "Invalid POE session id.";
    return 0;
  }
  if (defined $self->{_collectorSessionId}) {
    $self->{_error} = "StatCollector POE session id is already set.";
    return 0;
  }

  # check if specified session already exists.
  my $s = $poe_kernel->alias_resolve($id);
  unless (defined $s) {
    $self->{_error} = "Invalid session id: $!";
    return 0;
  }

  $self->{_collectorSessionId} = $id;
  return 1;
}

=head2 spawn ()

Starts statistics source. Returns plugin's POE session id on success, otherwise 0.

=cut

=head2 shutdown () [POE]

Stops source execution and frees all it's resources.

Returns 1 on success, otherwise 0.

=cut

sub shutdown {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->info($self->getSourceSignature() . " Shutting down source.");

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
  $self->{__sourceIsStarted} = 0;
  $self->{__sourceIsRunning} = 0;

  return 1;
}

=head2 getStatistics () [POE]

Returns object containing source statistics

=cut

sub getStatistics {
  my ($self) = @_;
  my $data = {};

  # copy counter data...
  %{$data} = %{$self->{_stats}};

  # compute averages...
  $data->{timeFetchTotalAvg}
    = ($data->{numFetchTotal} != 0) ? ($data->{timeFetchTotal} / $data->{numFetchTotal}) : 0;
  $data->{timeFetchOkAvg}  = ($data->{numFetchOk} != 0)  ? ($data->{timeFetchOk} / $data->{numFetchOk})   : 0;
  $data->{timeFetchErrAvg} = ($data->{numFetchErr} != 0) ? ($data->{timeFetchErr} / $data->{numFetchErr}) : 0;
  $data->{successRatio}
    = ($data->{numFetchTotal} != 0)
    ? sprintf("%-.2f", ($data->{numFetchOk} / $data->{numFetchTotal}) * 100)
    : 0.00;

  return $data;
}

=head2 resetStatististics () [POE]

Resets internal fetching statistics counters.

=cut

sub resetStatistics {
  my ($self) = @_;

  # $_log->info($self->getSourceSignature(),  " Reseting fetch statistics counters.");
  $self->{_stats} = {
    numFetchTotal  => 0,
    numFetchOk     => 0,
    numFetchErr    => 0,
    timeFetchTotal => 0,
    timeFetchOk    => 0,
    timeFetchErr   => 0,
  };
}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 EXTENDING CLASS

You need to implement the following methods in your source
implementatations:


=head2 getFetchUrl ()

Returns implementation specific statistics data source URL address as string.

=cut

sub getFetchUrl {
  my ($self) = @_;
  $_log->error("Class ", ref($self), " doesn't implement method getFetchUrl().");
  $poe_kernel->yield("shutdown");
  return undef;
}

=head2 getHostname ()

Returns monitored hostname.

=cut

sub getHostname {
  my ($self) = @_;
  $_log->error("Class ", ref($self), " doesn't implement method getHostname().");
  $poe_kernel->yield("shutdown");
  return undef;
}

=head2 getPort ()

Returns monitored monitored service port number on success, otherwise 0.

=cut

sub getPort {
  my ($self) = @_;
  return 0;
}

=head2 _run()

This method is called just after source startup in event B<run()> allowing you
to do some per-implementation specific stuff before fetching of data starts.

This method must return 1 if everything went fine, otherwise 0. In case of error
source session will stop immediately.

=cut

sub _run {
  return 1;
}

=head2 _shutdown ()

As part of source shutdown process top level "shutdown" POE event handler calls
method B<_shutdown()> allowing you to cleanup your source resources and sub-poe sessions.

Return value of method is not checked at all.

=cut

sub _shutdown {
  my ($self) = @_;
  return 1;
}

=head2 _fetchStart()

This method must return 1 if fetch was successfully started, otherwise 0. You're also
asked to set internal object error.

=cut

sub _fetchStart {
  my ($self) = @_;
  $self->{_error} = "Method _fetchStart() is not implemented in class: " . ref($self);
  $_log->error($self->{_error});
  $poe_kernel->yield("shutdown");
  return 0;
}

=head2 _fetchCancel()

This method must return 1 if fetch was successfully canceled, otherwise 0. You're also
asked to set internal object error.

=cut

sub _fetchCancel {
  my ($self) = @_;
  $self->{_error} = "Method _fetchCancel() is not implemented in class: " . ref($self);
  $_log->error($self->{_error});
  $poe_kernel->yield("shutdown");
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
  $_log->debug("Starting object ", ref($self), " POE session: " . $_[SESSION]->ID());

  # should we delay source startup?
  if ($self->{startupDelay} > 0) {

    # compute delay in seconfs...
    my $wait = rand(int($self->{startupDelay}));
    $_log->debug("Will wait " . sprintf("%-.3f", $wait) . " seconds before starting source.");
    $kernel->delay("run", $wait);
  }
  else {

    # start it immediately.
    $kernel->yield("run");
  }

  return 1;
}

sub _updateStats {
  my ($self, $duration, $ok) = @_;
  $ok = 1 unless (defined $ok);

  $self->{_stats}->{numFetchTotal}++;
  $self->{_stats}->{timeFetchTotal} += $duration;

  if ($ok) {
    $self->{_stats}->{numFetchOk}++;
    $self->{_stats}->{timeFetchOk} += $duration;
  }
  else {
    $self->{_stats}->{numFetchErr}++;
    $self->{_stats}->{timeFetchErr} += $duration;
  }
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

sub _checkParsers {
  my ($self) = @_;
  my $col_ref = $self->getCollectorRef();
  return 0 unless ($col_ref);

  $self->{__parsers} = [];
  foreach my $parser (split(/\s*[,;]+\s*/, $self->{useParser})) {
    next unless (defined $parser);
    $parser =~ s/^\s+//g;
    $parser =~ s/^\s+$//g;
    next unless (length($parser) > 0);

    my $ok  = 0;
    my $err = '';
    eval { $ok = $$col_ref->parserExists($parser); $err = $$col_ref->getError(); };
    unless ($ok) {
      $_log->error(
        $self->getSourceSignature() . " Source requests to be parsed with non-existing parser: $parser");

    }
    push(@{$self->{__parsers}}, $parser);
  }

  return 1;
}

sub _checkFilters {
  my ($self) = @_;
  my $col_ref = $self->getCollectorRef();
  return 0 unless ($col_ref);

  $self->{__filters} = [];
  foreach my $filter (split(/\s*[,;]+\s*/, $self->{useFilter})) {
    next unless (defined $filter);
    $filter =~ s/^\s+//g;
    $filter =~ s/^\s+$//g;
    next unless (length($filter) > 0);

    my $ok  = 0;
    my $err = '';
    eval { $ok = $$col_ref->filterExists($filter); $err = $$col_ref->getError(); };
    unless ($ok) {
      $_log->error(
        $self->getSourceSignature() . " Source requests to be filtered with non-existing filter: $filter");

    }
    push(@{$self->{__filters}}, $filter);
  }

  return 1;
}

sub _checkStorages {
  my ($self) = @_;
  my $col_ref = $self->getCollectorRef();
  return 0 unless ($col_ref);

  $self->{__storage} = [];
  foreach my $storage (split(/\s*[,;]+\s*/, $self->{useStorage})) {
    next unless (defined $storage);
    $storage =~ s/^\s+//g;
    $storage =~ s/^\s+$//g;
    next unless (length($storage) > 0);

    my $ok  = 0;
    my $err = '';
    eval { $ok = $$col_ref->storageExists($storage); $err = $$col_ref->getError(); };
    unless ($ok) {
      $_log->error(
        $self->getSourceSignature() . " Source requests to be stored by non-existing storage: $storage");
      return 0;
    }
    push(@{$self->{__storage}}, $storage);
  }

  return 1;
}

sub _getParsers {
  my ($self) = @_;
  return @{$self->{__parsers}};
}

sub _getFilters {
  my ($self) = @_;
  return @{$self->{__filters}};
}

sub _getStorages {
  my ($self) = @_;
  return @{$self->{__storage}};
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
