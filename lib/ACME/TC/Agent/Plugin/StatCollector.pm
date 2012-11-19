package ACME::TC::Agent::Plugin::StatCollector;

# Statistics collector plugin
#
# Copyright (C) 2010 Brane F. Gracnar
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.


use strict;
use warnings;

use POE;
use Log::Log4perl;
use File::Basename;
use File::Glob qw(:glob);
use Scalar::Util qw(blessed);

use ACME::Util;
use ACME::Util::PoeSession;
use ACME::Util::StringPermute;
use ACME::TC::Agent::Plugin;
use ACME::TC::Agent::Plugin::StatCollector::Parser;
use ACME::TC::Agent::Plugin::StatCollector::Filter;
use ACME::TC::Agent::Plugin::StatCollector::Source;
use ACME::TC::Agent::Plugin::StatCollector::Storage;

use base qw(ACME::TC::Agent::Plugin);

our $VERSION = 0.02;

my $util = ACME::Util->new();

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

use constant PARSER_NAME_DEFAULT    => "default";
use constant STORAGE_DRIVER_DEFAULT => "ZabbixSender";
use constant SOURCE_DRIVER_DEFAULT  => "HTTP";

use constant CLASS_PARSER      => 'ACME::TC::Agent::Plugin::StatCollector::Parser';
use constant CLASS_FILTER      => 'ACME::TC::Agent::Plugin::StatCollector::Filter';
use constant CLASS_SOURCE      => 'ACME::TC::Agent::Plugin::StatCollector::Source';
use constant CLASS_STORAGE     => 'ACME::TC::Agent::Plugin::StatCollector::Storage';
use constant CLASS_DATA_RAW    => 'ACME::TC::Agent::Plugin::StatCollector::RawData';
use constant CLASS_DATA_PARSED => 'ACME::TC::Agent::Plugin::StatCollector::ParsedData';

use constant PARSER_DEFAULT_DRIVER => 'TextSimple';
use constant PARSER_DEFAULT_NAME   => 'DEFAULT';

use constant SOURCE_GROUP_DEFAULT_NAME => 'DEFAULT';

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::StatCollector

Very flexible statistics collector agent plugin.

=head1 ARCHITECTURE


 +--------------+    +--------------+    +--------------+
 |  SOURCE xxx  |    |  SOURCE xxx  |    |  SOURCE xxx  |
 +--------------+    +--------------+    +--------------+
        |                    |                  |
        +------+-------------+------------------+
                                                |
 +---------------------------+                  |
 |       STATCOLLECTOR       |<----<raw data>---+
 +---------------------------+
              |
          <raw data>
              |
              v
        +--------------+
        |   PARSERS    |
        +--------------+
               |
         <parsed data>
               |
               v
        +--------------+
        |   FILTERS    |
        +--------------+
               |              +--------------+
               +------------->| STORAGE aaa  |
               |              +--------------+
               |
               |              +--------------+
               +------------->| STORAGE bbb  |
                              +--------------+

=head1 DATA FLOW

 SOURCE => STATCOLLECTOR => PARSER => FILTER => STORAGE

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=over

=item B<contextPath> (string, "/info/stat_collector"):

Where to mount web interface

=item B<parsers> (hash reference, {}):

=item B<filters> (hash reference, {}):

=item B<source> (array reference, []):

=item B<sourceGroups> (array reference, []):

=item B<storage> (array reference, []):

=item B<stopAgentOnShutdown> (boolean, 0): Request entire agent shutdown on plugin shutdown. Use only if you know what you're doing!

=back

=head1 METHODS

Methods marked with B<[POE]> can be invoked as POE events.

=head2 clearParams ()

Clear object parameters to default values. Returns 1 on success, otherwise 0.

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{contextPath} = "/info/stat_collector";

  $self->{filters} = {};

  # source collector groups
  $self->{sourceGroups} = {};

  #"group_name" => {
  #	driver => "HTTP",
  #	checkInterval => 10.0,
  #},

  # parsers...
  $self->{parsers} = {};

  # statistic collectors
  $self->{source} = [];

  # statistic storages
  $self->{storage} = [];

  # stop tc agent on shutdown?
  $self->{stopAgentOnShutdown} = 0;

  # PRIVATE VARZ
  # running statistics sources
  $self->{_source} = {};

  # parser objects
  $self->{_parser} = {};

  # filter objects...
  $self->{_filter} = {};

  # running statistics storages
  $self->{_storage} = {};

  # exposed POE object events
  $self->registerEvent(
    qw(
      initSource
      addSource
      initStorage
      addStorage
      sourceGotData
      )
  );

  return 1;
}

=head2 getStorageSession ($name)

Returns POE session id of storage object named $name, otherwise 0.

=cut

sub getStorageSession {
  my ($self, $name) = @_;
  unless (defined $name) {
    $self->{_error} = "Undefined storage name.";
    return 0;
  }

  foreach my $id (keys %{$self->{_storage}}) {
    if ($self->{_storage}->{$id}->getName() eq $name) {
      return $id;
    }
  }

  $self->{_error} = "No such storage: $name";
  return 0;
}

=head2 getStorageName ($id)

Returns storage object name identified by POE session id $id on success, otherwise undef.

=cut

sub getStorageName {
  my ($self, $id) = @_;
  unless (exists($self->{_storage}->{$id})) {
    $self->{_error} = "No such storage: $id";
    return undef;
  }

  return $self->{_storage}->{$id}->getName();
}

#################### BEGIN PARSERS ####################

=head2 parserExists ($name) [POE]

Returns if parser identified by $name exists in current statcollector instance.

=cut

sub parserExists {
  my ($self, $name);
  if (is_poe(\@_)) {
    ($self, $name) = @_[OBJECT, ARG0];
  }
  else {
    ($self, $name) = @_;
  }

  unless (defined $name) {
    $self->{_error} = "Invalid/undefined parser name.";
    return 0;
  }
  unless (exists($self->{_parser}->{$name})) {
    $self->{_error} = "No such parser: $name";
    return 0;
  }

  return 1;
}

=head2 parserAdd (%opt) [POE]

Tries to initialize parser. %opt must contain at least B<driver> key, all other
keys are parser implementation specific. See L<ACME::TC::Agent::Plugin::StatCollector::Parser>
for details.

Returns 1 on success, otherwise 0.

=cut

sub parserAdd {
  my ($self, %opt);
  if (is_poe(\@_)) {
    ($self, %opt) = @_[OBJECT, ARG0 .. $#_];
  }
  else {
    ($self, %opt) = @_;
  }

  # is this parser disabled?
  return 1 if (exists($opt{enabled})   && !$opt{enabled});
  return 1 if (exists($opt{isEnabled}) && !$opt{isEnabled});
  delete($opt{enabled});

  # do we have a name?
  my $name = __PACKAGE__ . rand();
  if (exists($opt{name})) {
    $name = $opt{name};
    delete($opt{name});
  }

  if (exists($self->{_parser}->{$name})) {
    $_log->warn("Overriding already existing parser: $name");
  }

  # driver
  my $driver = $opt{driver};
  delete($opt{driver});
  unless (defined $driver && length($driver) > 0) {
    $_log->error("Error initializing parser $name: Undefined driver name.");
    return 0;
  }
  my $obj = CLASS_PARSER->factory($driver, %opt);
  unless (defined $obj) {
    $_log->error("Error initializing parser $name using driver $driver: " . CLASS_PARSER->factoryError());
    return 0;
  }

  # give parser a name
  $obj->setName($name);

  # assign it...
  $self->{_parser}->{$name} = $obj;

  $_log->debug("Successfully initialized parser $name using driver $driver.");
  return 1;
}

=head2 parserRemove ($name) [POE]

Removes parser identified by $name. Returns 1 on success, otherwise 0.

=cut

sub parserRemove {
  my ($self, $name);
  if (is_poe(\@_)) {
    ($self, $name) = @_[OBJECT, ARG0];
  }
  else {
    ($self, $name) = @_;
  }

  unless (exists($self->{_parser}->{$name})) {
    $self->{_error} = "Parser doesn't exist: $name";
    return 0;
  }

  delete($self->{_parser}->{$name});
  return 1;
}

=head2 parserRemoveAll ()

Removes all currently active parsers.

=cut

sub parserRemoveAll {
  my ($self) = @_;
  my $i = 0;
  map {
    $i++;
    delete($self->{_parser}->{$_});
  } keys %{$self->{_parser}};

  return $i;
}

=head2 parserList () [POE]

Returns list of assigned parser names.

=cut

sub parserList {
  my ($self) = @_;
  return keys %{$self->{_parser}};
}

=head2 parserGet ($name)

Returns parser object identified by $name. Returns object on success, otherwise undef.

=cut

sub parserGet {
  my ($self, $name) = @_;
  return undef unless ($self->parserExists($name));
  return $self->{_parser}->{$name};
}

####################  END PARSERS  ####################

#################### BEGIN FILTERS ####################

=head2 filterExists ($name) [POE]

Returns if filter identified by $name exists in current statcollector instance.

=cut

sub filterExists {
  my ($self, $name) = @_;

  unless (defined $name) {
    $self->{_error} = "Invalid/undefined filter name.";
    return 0;
  }
  unless (exists($self->{_filter}->{$name})) {
    $self->{_error} = "No such filter: $name";
    return 0;
  }

  return 1;
}

=head2 filterAdd (%opt) [POE]

Tries to initialize filter. %opt must contain at least B<driver> key, all other
keys are parser implementation specific. See L<ACME::TC::Agent::Plugin::StatCollector::Filter>
for details. Returns 1 on success, otherwise 0.

=cut

sub filterAdd {
  my ($self, %opt) = @_;

  # is this filter disabled?
  return 1 if (exists($opt{enabled})   && !$opt{enabled});
  return 1 if (exists($opt{isEnabled}) && !$opt{isEnabled});
  delete($opt{enabled});

  # do we have a name?
  my $name = __PACKAGE__ . rand();
  if (exists($opt{name})) {
    $name = $opt{name};
    delete($opt{name});
  }

  if (exists($self->{_parser}->{$name})) {
    $_log->warn("Overriding already existing parser: $name");
  }

  # driver
  my $driver = $opt{driver};
  delete($opt{driver});
  unless (defined $driver && length($driver) > 0) {
    $_log->error("Error initializing filter $name: Undefined driver name.");
    return 0;
  }
  my $obj = CLASS_FILTER->factory($driver, %opt, __statCollector => \$self);
  unless (defined $obj) {
    $_log->error("Error initializing filter $name using driver $driver: " . CLASS_FILTER->getError());
    return 0;
  }

  # give parser a name
  $obj->setName($name);

  # assign it...
  $self->{_filter}->{$name} = $obj;

  $_log->debug("Successfully initialized filter $name using driver $driver.");
  return 1;
}

=head2 filterRemove ($name)

Removes filter identified by $name. Returns 1 on success, otherwise 0.

=cut

sub filterRemove {
  my ($self, $name) = @_;
  return 0 unless ($self->filterExists($name));
  delete($self->{_filter}->{$name});
  return 1;
}

=head2 filterRemoveAll ()

Removes all currently active filters. Returns number of removed filters.

=cut

sub filterRemoveAll {
  my ($self) = @_;
  my $i = 0;
  map { $i += $self->filterRemove($_); } $self->filterList();

  return $i;
}

=head2 filterList ()

Returns list of assigned filter names.

=cut

sub filterList {
  my ($self) = @_;
  return keys %{$self->{_filter}};
}

=head2 filterGet ($name)

Returns filter object identified by $name. Returns object on success, otherwise undef.

=cut

sub filterGet {
  my ($self, $name) = @_;
  return undef unless ($self->filterExists($name));
  return $self->{_filter}->{$name};
}

####################  END FILTERS  ####################

#################### BEGIN SOURCES ####################
####################  END SOURCES  ####################

#################### BEGIN STORAGE ####################

sub storageExists {
  my ($self, $name) = @_;
  unless (defined $name) {
    $self->{_error} = "Undefined storage name.";
    return 0;
  }

  foreach (values %{$self->{_storage}}) {
    if ($_->getName() eq $name) {
      return 1;
    }
  }

  $self->{_error} = "There is no storage object: $name";
  return 0;
}

####################  END STORAGE  ####################

=head1 POE EVENTS

=cut

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->info("Plugin '" . $self->_getBasePackage() . "' startup.");

  # initialize parsers...
  unless ($self->_initParsers()) {
    $_log->error("Error initializing parsers.");
    return $kernel->yield("shutdown");
  }

  # initialize filters...
  unless ($self->_initFilters()) {
    $_log->error("Error initializing filters.");
    return $kernel->yield("shutdown");
  }

  # initialize storage drivers...
  unless ($self->_initStorage()) {
    $_log->error("Error initializing storage; maybe no storage drivers were defined?");
    return $kernel->yield("shutdown");
  }

  # initialize collector sources...
  unless ($self->_initSources()) {
    $_log->error("Error initializing sources.");
    return $kernel->yield("shutdown");
  }

  # implement simple web stat inteface...
  $_log->debug("Mounting plugin context to connectors: $self->{contextPath}");
  my $x = $self->agentCall(
    'connectorMountContext',
    {
      uri     => $self->{contextPath},
      handler => __PACKAGE__ . '::WebHandler',

      # dont_load_handler => 1,
      args => {poeSession => $self->getSessionId()},
    },
  );
  unless ($x) {
    $_log->error("Error mounting context: $self->{contextPath}");
    $kernel->yield('shutdown');
  }

  return 1;
}

=head2 sourceGotData ($data)

This method is called by source objects which have fetched statistics data. $data
must be initialized and valid L<ACME::TC::Agent::Plugin::StatCollector::RawData>
or L<ACME::TC::Agent::Plugin::StatCollector::ParsedData> object.

Provided $data object then parsed using parser chain, filtered trough filter chain
and written to all or selected initialized storage objects.  

=cut

sub sourceGotData {
  my ($self, $kernel, $data) = @_[OBJECT, KERNEL, ARG0];
  $_log->debug("Startup.");
  my $sender = $_[SENDER]->ID();

  # check if this one came from any of our sources...
  unless (exists($self->{_source}->{$sender})) {
    $_log->warn("Got data from non-source POE session: $sender; Ignoring!");
    return 0;
  }

  # valid object data?
  unless (defined $data && blessed($data) && $data->isa(CLASS_DATA_RAW)) {
    $_log->error("Got invalid raw data object from POE session " . $_[SENDER]->ID());
    return 0;
  }

  # ehm, complete data?
  unless ($data->isValid()) {
    my $sig = $data->getSignature();
    $sig = "" unless (defined $sig);
    $_log->error("[$sig]: Got incomplete raw data object: " . $data->getError());
    return 0;
  }

  #
  # PHASE I: parse raw data if necessary...
  #
  my $parsed_data = undef;
  if ($data->isa(CLASS_DATA_PARSED)) {
    $parsed_data = $data;
  }
  elsif ($data->isa(CLASS_DATA_RAW)) {
    $parsed_data = $self->_parseData($data);
  }
  else {
    $_log->error("Got invalid data object from POE session " . $_[SENDER]->ID() . ref($data));
    return 0;
  }
  return 0 unless (defined $parsed_data);

  #
  # PHASE II: filter parsed data
  #
  my $filtered_data = $self->_filterData($parsed_data);
  return 0 unless (defined $filtered_data);


  #
  # PHASE III: post filtered data to running storage implementations
  #
  return 0 unless ($self->_storeData($filtered_data));

  return 1;
}

sub initStorage {
  my ($self, $kernel, $driver, %params) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  # is enabled?
  return 1 if (exists($params{enabled})   && !$params{enabled});
  return 1 if (exists($params{isEnabled}) && !$params{isEnabled});

  # create object
  my $obj = CLASS_STORAGE->factory($driver, %params);

  unless (defined $obj) {
    $_log->error("Error initializing storage: " . CLASS_STORAGE->factoryError());
    return 0;
  }

  # schedule adding
  $kernel->yield("addStorage", $obj);
  return 1;
}

sub addStorage {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  my $i = 0;
  foreach my $obj (@_[ARG0 .. $#_]) {
    unless (defined $obj && blessed($obj) && $obj->isa(CLASS_STORAGE)) {
      no warnings;
      $_log->error("Invalid storage object: " . ref($obj));
      next;
    }

    # is this source already started?
    my $id = 0;
    if ($obj->isStarted()) {
      $id = $obj->getSessionId();
    }
    else {

      # start it!
      $id = $obj->spawn();
      unless ($id) {
        $self->{_error} = "Unable to start storage: " . $obj->getError();
      }
    }

    # no id?
    unless ($id) {
      $_log->error($self->getError());
      next;
    }

    # is this object already assigned?
    if (exists($self->{_storage}->{$id})) {
      $_log->error("This storage is already assigned.");
      next;
    }

    # save && register this source object
    $self->{_storage}->{$id} = $obj;

    $i++;
  }

  $_log->info("Added $i storage object(s).");
}

=head2 initSource ($driver, %params) [POE only]

Tries to initialize L<ACME::TC::Agent::Plugin::StatCollector::Source> implementation
using driver B<$driver> with params specified in B<%params>.

=cut

sub initSource {
  my ($self, $kernel, $driver, %params) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  $_log->debug("Startup.");

  # is enabled?
  return 1 if (exists($params{enabled})   && !$params{enabled});
  return 1 if (exists($params{isEnabled}) && !$params{isEnabled});

  my $u = ACME::Util->new();
  $_log->debug("Initializing source with driver $driver [" . $u->dumpVarCompact(\%params) . "]");

  unless (defined $driver && length($driver) > 0) {
    $self->{_error} = "Unspecified driver.";
    $_log->error($self->{error});
    return 0;
  }

  # get source object...
  my $obj = CLASS_SOURCE->factory($driver, %params);
  unless (defined $obj) {
    $_log->error("Error creating source object: " . CLASS_SOURCE->factoryError());
    return 0;
  }

  # schedule adding
  $kernel->yield("addSource", $obj);

  return 1;
}

=head2 addSource ($obj, $obj2, ...) [POE only]

Adds and starts initialized L<ACME::TC::Agent::Plugin::StatCollector::Source> object(s)
to list of active sources.

=cut

sub addSource {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  my $i = 0;
  foreach my $obj (@_[ARG0 .. $#_]) {
    unless (defined $obj && blessed($obj) && $obj->isa(CLASS_SOURCE)) {
      no warnings;
      $_log->error("Invalid source object: " . $obj);
      next;
    }

    $obj->setCollectorRef(\$self);

    # is this source already started?
    my $id = 0;
    if ($obj->isStarted()) {
      $id = $obj->getSessionId();
    }
    else {

      # start it!
      $id = $obj->spawn();
      unless ($id) {
        $self->{_error} = "Unable to start source: " . $obj->getError();
      }
    }

    # no id?
    unless ($id) {
      $_log->error($self->getError());
      next;
    }

    # is this source already there?
    if (exists($self->{_source}->{$id})) {
      $_log->error("This source is already assigned.");
      next;
    }

    # assign our POE session id so
    # that this source will be able to communicate
    # with us.
    $obj->setCollectorPoeSession($self->getSessionId());

    # save && register this source object
    $self->{_source}->{$id} = $obj;

    $i++;
  }

  $_log->debug("Added $i source(s).");
}

##################################################
#               PRIVATE METHODS                  #
##################################################

# poe child session create/destroy hook
sub _child {
  my ($self, $kernel, $reason, $child) = @_[OBJECT, KERNEL, ARG0, ARG1];
  my $ref = ref($self);
  if ($reason eq 'lose') {
    my $id = $child->ID();

    # source?
    if (exists($self->{_source}->{$id})) {
      $_log->debug("Source $id stopped.");
      delete($self->{_source}->{$id});
    }

    # storage?
    elsif (exists($self->{_storage}->{$id})) {
      $_log->debug("Storage $id stopped.");
      delete($self->{_storage}->{$id});

      # no more storages defined? shutdown this plugin!
      unless (scalar keys %{$self->{_storage}} > 0) {

        #$_log->error("No more storage drivers; issuing plugin " . $self->getDriver() . " shutdown.");
        #$kernel->yield('shutdown');
      }
    }
  }
}

# shutdown hook
sub _shutdown {
  my ($self) = @_;

  my $i = 0;

  # shutdown all sources...
  $_log->info("Shutting down statistics sources.");
  foreach (keys %{$self->{_source}}) {
    $poe_kernel->call($_, "shutdown");
    $i++;
  }
  $_log->info("Stopped $i source(s).");

  # shut down all
  $_log->info("Shutting down statistics data writers.");
  $i = 0;
  foreach (keys %{$self->{_storage}}) {
    $poe_kernel->call($_, "shutdown");
    $i++;
  }
  $_log->info("Stopped $i statistics data writer(s).");

  # destroy filters
  $self->filterRemoveAll();

  # destroy parsers
  $self->parserRemoveAll();

  # should we stop entire agent?!
  if ($self->{stopAgentOnShutdown}) {
    $_log->warn($self->_getBasePackage(), " plugin shutdown will shutdown entire agent.");
    $poe_kernel->post($self->getAgentSessionId(), 'shutdown');
  }

  return 1;
}

# parses raw data object
#
# returns parseddata object on success, otherwise undef.
sub _parseData {
  my ($self, $data) = @_;
  return undef unless (defined $data);

  my $id  = $data->getId();
  my $sig = $data->getSignature();

  # get list of candidate parsers...
  my $parsed_data = undef;
  foreach my $parser ($data->getParser()) {
    next unless (defined $parser);

    # valid parser?
    unless (exists($self->{_parser}->{$parser})) {
      $_log->error("[$id] Raw data object requests to be parsed using non-existing parser named '$parser'");
      next;
    }

    # get parser object..
    my $parser_obj = $self->{_parser}->{$parser};

    # try to parse
    $parsed_data = $parser_obj->parse($data);

    # check for injuries...
    last if (defined $parsed_data);
    $_log->error("[$id] Unable to parse raw data using parser "
        . $parser_obj->getName()
        . " [driver "
        . $parser_obj->getDriver() . "]: "
        . $parser_obj->getError());
  }

  unless (defined $parsed_data) {
    $_log->error(
      "[$id] Unable to parse raw with any of requested parsers: " . join(", ", $data->getParser()));
  }

  return $parsed_data;
}

# filters data object (ParsedData) trough defined filter chain.
#
# returns filtered object on success, otherwise undef.
sub _filterData {
  my ($self, $obj) = @_;
  return undef unless (defined $obj);

  my $i             = 0;
  my $id            = $obj->getId();
  my $filtered_data = $obj->getContent();
  foreach my $f ($obj->getFilter()) {

    # valid filter?
    unless (exists($self->{_filter}->{$f})) {
      $_log->warn("[$id] Parsed data object requests to be filtered using non-existing"
          . " filter named '$f'; skipping.");
      next;
    }

    $_log->debug("[$id] Filtering using filter $f");
    $obj = $self->{_filter}->{$f}->filter($obj);
    unless (defined $obj) {
      $_log->error("[$id] Unable to filter parsed data using filter $f [driver "
          . $self->{_filter}->{$f}->getDriver() . "]: "
          . $self->{_filter}->{$f}->getError()
          . "; discarding.");
      return undef;
    }
  }

  return $obj;
}

# tries to post $data (ParsedData object) to all initialized storages.
#
# Returns number of storages to which $data was successfully submitted.
sub _storeData {
  my ($self, $data) = @_;
  unless (defined $data) {
    $self->{_error} = "Undefined data object.";
    return 0;
  }

  if ($data->getDebugParsedData()) {
    $_log->info($data->getSignature(),
      " --- BEGIN FILTERED DATA ---\n" . $util->dumpVar($data->getContent(1)));
    $_log->info($data->getSignature(), "--- END FILTERED DATA ---");
  }

  my @storage_sessions = ();

  # does object want to be stored to any specific storage?
  my @req_storages = $data->getStorage();
  if (@req_storages) {
    foreach my $sname (@req_storages) {
      my $storage_session = $self->getStorageSession($sname);
      unless ($storage_session) {
        $_log->error($data->getSignature() . " Object requests to be stored to invalid storage: $sname");
        next;
      }
      push(@storage_sessions, $storage_session);
    }
  }
  else {
    push(@storage_sessions, keys %{$self->{_storage}});
  }

  # enqueue store request to all storages
  my $i = 0;
  foreach my $storage_session (@storage_sessions) {
    my $x = $poe_kernel->post($storage_session, 'store', $data);
    unless ($x) {
      $_log->error($data->getSignature()
          . " Error posting data to storage "
          . $self->getStorageName($storage_session)
          . " in POE session $storage_session: "
          . $!);
      next;
    }
    $i++;
  }

  # check for injuries...
  if ($i < 1) {
    $_log->error($data->getSignature(), " Unable to store parsed data structure to any storage!");
  }
  else {
    $_log->debug($data->getSignature(), " Enqueued storage of data structure to $i storage(s).");
  }

  return $i;
}

# tries to load plaintext file from filesystem
# read it and evaluate it's content to perl hash reference.
#
# returns hash reference on success, otherwise undef
sub confFragmentLoad {
  my ($self, $file) = @_;
  unless (defined $file) {
    $self->{_error} = "Undefined file.";
    return undef;
  }
  my $fd = IO::File->new($file, 'r');
  unless (defined $fd) {
    $self->{_error} = "Unable to open file $file for reading: $!";
    return undef;
  }

  $_log->info("Loading configuration fragment file: $file");

  my $buf = '';
  my $i   = 0;
  while ($i < 10000 && defined(my $l = <$fd>)) {
    $i++;
    $l =~ s/^\s+//g;
    $l =~ s/\s+$//g;

    # skip comments...
    next if ($l =~ m/^#/);
    next unless (length($l) > 0);

    $buf .= $l . "\n";
  }

  # prefix { if necessary...
  if ($buf !~ m/^{/) {
    $buf = '{' . $buf;
  }

  # suffix } if necessary...
  if ($buf !~ m/}\s*$/gm) {
    $buf .= '}';
  }

  if ($_log->is_debug()) {
    $_log->debug("--- BEGIN CONFIG FRAGMENT ---\n", $buf);
    $_log->debug("--- END CONFIG FRAGMENT ---");
  }

  #  try to evaluate this string into real perl structure...
  my $s = eval $buf;
  if ($@) {
    $self->{_error} = "Syntax error while evaluating configuration fragment $file: $@";
    return undef;
  }
  elsif (!defined $s) {
    $self->{_error} = "Error evaluating configuration fragment $file: returned undef value.";
    return undef;
  }
  elsif (ref($s) ne 'HASH') {
    $self->{_error} = "Error evaluating configuration fragment: returned value is not hash reference.";
    return undef;
  }
  elsif (scalar keys %{$s} < 1) {
    $self->{_error} = "Error evaluating configuration fragment: returned hash reference without any keys.";
    return undef;
  }

  return $s;
}

# initiliazes all configured parsers
sub _initParsers {
  my ($self) = @_;

  # create default raw data parser...
  $_log->debug("Creating default raw data parser");
  my %opt = (driver => PARSER_DEFAULT_DRIVER, name => PARSER_DEFAULT_NAME);
  unless ($self->parserAdd(%opt)) {
    $self->{_error} = "Unable to create default raw data parser: " . $self->{_error};
    return 0;
  }

  # create custom parsers...
  my $i = 1;
  foreach my $name (keys %{$self->{parsers}}) {

    # what is this?
    my $ref = ref($self->{parsers}->{$name});

    # hash reference? this must be built-in configuration...
    if ($ref eq 'HASH') {
      unless ($self->parserAdd(%{$self->{parsers}->{$name}}, name => $name)) {
        $_log->error($self->{_error});
        return 0;
      }
      $i++;
    }
    else {

      # not a hash reference?
      my $glob_str = $self->{parsers}->{$name};
      next unless (defined $glob_str);

      # maybe it's a directory...
      if (-d $glob_str && -r $glob_str) {

        # this is a directory!!!
        $glob_str .= "/*";
      }

      # search for files!
      my @files = bsd_glob($glob_str, (GLOB_TILDE | GLOB_ERR));
      if (GLOB_ERROR) {
        $_log->error("Error globbing: $!");
        next;
      }

      foreach my $file (@files) {
        unless (-f $file && -r $file) {
          $_log->warn("Invalid parser configuration file $file: $!");
          next;
        }

        # load configuration file...
        my $c = $self->confFragmentLoad($file);
        unless (defined $c) {
          $_log->error($self->getError());
          next;
        }

        # got name?
        unless (exists($c->{name}) && defined $c->{name}) {
          $c->{name} = basename($file);

          # remove suffix
          $c->{name} =~ s/\.[a-z0-9]+$//g;
        }

        # try to initialize parser...
        unless ($self->parserAdd(%{$c})) {
          $_log->error($self->getError());
        }
        $i++;
      }
    }
  }

  $_log->info("Initialized $i parsers.");

  return 1;
}

# initiliazes all configured filters
sub _initFilters {
  my ($self) = @_;

  my $i = 0;
  foreach my $name (keys %{$self->{filters}}) {
    my %opt = ();

    # what is this?
    my $ref = ref($self->{filters}->{$name});

    # hash reference? this must be built-in configuration...
    if ($ref eq 'HASH') {
      unless ($self->filterAdd(%{$self->{filters}->{$name}}, name => $name)) {
        $_log->error($self->{_error});
        return 0;
      }
      $i++;
    }
    else {

      # not a hash reference?
      my $glob_str = $self->{filters}->{$name};
      next unless (defined $glob_str);

      # maybe it's a directory...
      if (-d $glob_str && -r $glob_str) {

        # this is a directory!!!
        $glob_str .= "/*";
      }

      # search for files!
      my @files = bsd_glob($glob_str, (GLOB_TILDE | GLOB_ERR));
      if (GLOB_ERROR) {
        $_log->error("Error globbing: $!");
        next;
      }

      foreach my $file (sort @files) {
        unless (-f $file && -r $file) {
          $_log->warn("Invalid filter configuration file $file: $!");
          next;
        }

        # load configuration file...
        my $c = $self->confFragmentLoad($file);
        unless (defined $c) {
          $_log->error($self->getError());
          next;
        }

        # got name?
        unless (exists($c->{name}) && defined $c->{name}) {
          $c->{name} = basename($file);

          # remove suffix
          $c->{name} =~ s/\.[a-z0-9]+$//g;
        }

        # try to initialize filter...
        unless ($self->filterAdd(%{$c})) {
          return 0;

          # $_log->error($self->getError());
        }
        $i++;
      }
    }

  }

  $_log->info("Initialized $i filters.");

  return 1;
}

# initializes all configured storage plugins
sub _initStorage {
  my ($self) = @_;
  unless (@{$self->{storage}}) {
    $_log->error("No storage configuration. There must be at least one storage defined.");
    return 0;
  }

  my $i = 0;
  foreach my $e (@{$self->{storage}}) {

    # what is this?
    my $ref = ref($e);

    # hash reference? this must be built-in configuration...
    if ($ref eq 'HASH') {

      #try to initialize storage driver...
      my $x
        = $poe_kernel->call($self->getSessionId(), "initStorage", $e->{driver}, %{$e}, name => $e->{name},);

      $i++ if ($x);
    }
    else {

      # not a hash reference?
      my $glob_str = $e;
      next unless (defined $glob_str);

      # maybe it's a directory...
      if (-d $glob_str && -r $glob_str) {

        # this is a directory!!!
        $glob_str .= "/*";
      }

      # search for files!
      my @files = bsd_glob($glob_str, (GLOB_TILDE | GLOB_ERR));
      if (GLOB_ERROR) {
        $_log->error("Error globbing: $!");
        next;
      }

      foreach my $file (@files) {
        unless (-f $file && -r $file) {
          $_log->warn("Invalid filter configuration file $file: $!");
          next;
        }

        # load configuration file...
        my $c = $self->confFragmentLoad($file);
        unless (defined $c) {
          $_log->error($self->getError());
          next;
        }

        # got name?
        unless (exists($c->{name}) && defined $c->{name}) {
          $c->{name} = basename($file);

          # remove suffix
          $c->{name} =~ s/\.[a-z0-9]+$//g;
        }

        my $x = $poe_kernel->call($self->getSessionId(), "initStorage", $c->{driver}, %{$c},);

        $i++ if ($x);
      }
    }
  }

  if ($i > 0) {
    $_log->info("Started $i storage drivers.");
  }
  else {
    $_log->error("No storage configured, shutting down the plugin.");
  }

  return $i;
}

# initializes source groups...
sub _initSg {
  my ($self) = @_;

  $_log->info("Initializing source groups.");

  # This is quite UGLY :))))

  my $i = 0;
  foreach my $name (keys %{$self->{sourceGroups}}) {
    next unless (defined $name && length($name) > 0);
    my $e   = $self->{sourceGroups}->{$name};
    my $ref = ref($self->{sourceGroups}->{$name});

    # hash reference? this must be built-in configuration...
    if ($ref eq 'HASH') {
      unless ($self->sourceGroupAdd(%{$self->{sourceGroups}->{$name}}, name => $name)) {
        $_log->error($self->{_error});
      }
      $i++;
    }
    else {

      # not a hash reference?
      my $glob_str = $self->{sourceGroups}->{$name};

      # maybe it's a directory...
      if (-d $glob_str && -r $glob_str) {

        # this is a directory!!!
        $glob_str .= "/*";
      }

      # search for files!
      my @files = bsd_glob($glob_str, (GLOB_TILDE | GLOB_ERR));
      if (GLOB_ERROR) {
        $_log->error("Error globbing: $!");
        next;
      }

      foreach my $file (@files) {
        unless (-f $file && -r $file) {
          $_log->warn("Invalid source group configuration file $file: $!");
          next;
        }

        # load configuration file...
        my $c = $self->confFragmentLoad($file);
        unless (defined $c) {
          $_log->error($self->getError());
          next;
        }

        # got name?
        unless (exists($c->{sourceGroup}) && defined $c->{sourceGroup}) {
          $c->{sourceGroup} = basename($file);

          # remove suffix
          $c->{sourceGroup} =~ s/\.[a-z0-9]+$//g;
        }

        # try to initialize filter...
        unless ($self->sourceGroupAdd(%{$c})) {
          $_log->error($self->getError());
        }
        $i++;
      }
    }
  }

  return 1;
}

sub sourceGroupAdd {
  my ($self, %e) = @_;

  #return 0 unless (defined %e && ref($e) ne 'HASH');

  # is this group/source disabled?
  return 1 if (exists($e{isEnabled}) && !$e{isEnabled});
  return 1 if (exists($e{enabled})   && !$e{enabled});

  # get source group name
  my $name = $e{sourceGroup};
  $name = SOURCE_GROUP_DEFAULT_NAME unless (defined $name);
  $e{sourceGroup} = $name;

  # inspect $e for multiplier...
  my $multiplier = undef;
  foreach my $k (keys %e) {
    if (ref($e{$k}) eq 'ARRAY') {
      $multiplier = $k;
      last;
    }
  }

  unless (defined $multiplier) {
    $_log->debug("Source group $name doesn't have multiplier; adding it as normal source.");

    my $driver = $e{driver};
    delete($e{driver});
    $driver = SOURCE_DRIVER_DEFAULT unless (defined $driver);

    # do the call!
    return $poe_kernel->call($self->getSessionId(), "initSource", $driver, %e,);
  }

  my $x = {};
  %{$x} = %e;
  my @m_vals = @{$x->{$multiplier}};
  delete($x->{multiplier});

  # create permute object...
  my $p = ACME::Util::StringPermute->new();

  foreach my $multiply_val (@m_vals) {
    my $vals = $p->permute($multiply_val);
    unless (defined $vals) {
      my $err = "Error permutating string '$multiply_val': " . $p->getError();
      $_log->error($err);
      return 0;
    }
    if ($_log->is_debug()) {
      $_log->debug("String $multiply_val permuted to: ", join(", ", @{$vals}));
    }

    map {
      my %opt = %{$x};

      my $driver = SOURCE_DRIVER_DEFAULT;
      $driver = $opt{driver} if (exists($opt{driver}));
      delete($opt{driver});

      $opt{$multiplier} = $_;
      $opt{sourceGroup} = $name;

      # do the call!
      my $x = $poe_kernel->call($self->getSessionId(), "initSource", $driver, %opt,);
    } @{$vals};
  }

  return 1;
}

sub _initSources {
  my ($self) = @_;

  # initialize sourcegroups
  $self->_initSg();

  my $i = 0;
  foreach my $s (@{$self->{source}}) {
    my $driver = SOURCE_DRIVER_DEFAULT;
    $driver = $s->{driver} if (exists($s->{driver}));
    delete($s->{driver});

    # is this source disabled?
    next if (exists($s->{isEnabled}) && !$s->{isEnabled});
    next if (exists($s->{enabled})   && !$s->{enabled});

    # try to initialize source driver...
    my $x = $poe_kernel->call($self->getSessionId(), "initSource", $driver, %{$s});

    # check for injuries
    unless ($x) {
      $_log->error($self->{_error});
      return $poe_kernel->yield("shutdown");
    }
    $i++;
  }
  $_log->info("Started $i statistics collection sources.");
  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Parser>
L<ACME::TC::Agent::Plugin::StatCollector::Filter>
L<ACME::TC::Agent::Plugin::StatCollector::Source>
L<ACME::TC::Agent::Plugin::StatCollector::Storage>
L<ACME::TC::Agent::Plugin::StatCollector::RawData>
L<ACME::TC::Agent::Plugin::StatCollector::ParsedData>
L<ACME::Util::StringPermute>
L<POE>
L<ACME::TC::Agent::Plugin>
L<ACME::TC::Agent>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
