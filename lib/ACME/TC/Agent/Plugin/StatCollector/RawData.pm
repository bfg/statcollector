package ACME::TC::Agent::Plugin::StatCollector::RawData;


use strict;
use warnings;

use URI;
use bytes;
use Data::Dumper;
use POSIX qw(strftime);

our $VERSION = 0.04;
our $Error   = "";

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::RawData

Raw data container for single ACME::TC::Agent::Plugin::StatCollector::Source
fetch.

=head1 SYNOPSIS
 
 # create raw data harness object...
 my $data = ACME::TC::Agent::Plugin::StatCollector::RawData->new();

 # add content and other data...
 $data->setContent($raw_data);
 $data->setFetchStartTime($time_fetch_started);
 $data->setFetchDoneTime($time_fetch_done);
 $data->setUrl($fetch_url);
 $data->setId($fetch_id);
 $data->setDriver($fetch_driver);
 $data->setParser($parser_name);
 
 # post raw data object to stat collector - it will
 # take care about parsing and storing...
 unless ($_[KERNEL]->post($stat_collector_session, "sourceGotData", $data)) {
 	$_log->error("Error posting data to StatCollector POE session id $stat_collector_session: $!");
 }

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor doesn't take any arguments.

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
  $self->_init();
  $self->reset();
  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 METHODS

=head2 getError ()

Returns last error.

=cut

sub getError {
  my ($self) = @_;
  return (defined $self && ref($self) ne '') ? $self->{_error} : $Error;
}

=head2 clone ()

Returns independent copy of current object.

=cut

sub clone {
  my ($self) = @_;

  # create copy of ourselves...
  my $class = ref($self);
  return undef unless (defined $class && length($class) > 0);
  my $obj = undef;
  eval { $obj = $class->new(); };
  return undef unless (defined $obj);

  # copy data (this is sooo ugly...)
  foreach my $key (keys %{$self}) {
    my $ref = ref($self->{$key});

    # basic scalar
    if ($ref eq '') {
      $obj->{$key} = $self->{$key};
    }
    elsif ($ref eq 'ARRAY') {
      @{$obj->{$key}} = @{$self->{$key}};
    }
    elsif ($ref eq 'HASH') {
      %{$obj->{$key}} = %{$self->{$key}};
    }
  }

  #print "CLONE ($self) => ($obj)\n\n";

  return $obj;
}

=head2 reset ()

Resets internal data structures (empties object).

=cut

sub reset {
  my ($self) = @_;
  $self->{_error} = "";

  # reset content...
  $self->resetData();

  # reset metadata...
  $self->{_url}             = undef;
  $self->{_host}            = undef;
  $self->{_port}            = 0;
  $self->{_driver}          = undef;
  $self->{_id}              = undef;
  $self->{_parser}          = [];
  $self->{_filter}          = [];
  $self->{_storage}         = [];
  $self->{_fetchStarted}    = 0;
  $self->{_fetchEnded}      = 0;
  $self->{_signature}       = undef;
  $self->{_debugParsedData} = 0;

  return 1;
}

=head2 resetData ()

Resets only holding data, leaving metadata untouched.

=cut

sub resetData {
  my ($self) = @_;
  $self->{_content} = undef;
}

=head2 isValid ()

Returns 1 if this object has all required data, otherwise 0.

Example:

 unless ($data->isValid()) {
 	die "Got non-consistent data: " . $data->getError();
 }

=cut

sub isValid {
  my ($self, $strict) = @_;
  $strict = 0 unless (defined $strict);
  my $r = 1;

  unless (defined $self->{_content}) {
    $self->{_error} = "Undefined content.";
    $r = 0;
  }
  unless (defined $self->{_url}) {
    $self->{_error} = "Undefined URL.";
    $r = 0;
  }
  unless (defined $self->{_driver}) {
    $self->{_error} = "Undefined driver.";
    $r = 0;
  }
  unless (defined $self->{_id}) {
    $self->{_error} = "Undefined fetch id.";
    $r = 0;
  }
  unless (defined $self->{_parser}) {
    $self->{_error} = "Undefined parser name.";
    $r = 0;
  }

  # check duration
  unless ($self->getFetchDuration() > 0) {
    $self->{_error} = "Invalid fetch time parameters.";
    $r = 0;
  }

  # size?
  unless ($self->size()) {
    $self->{_error} = "No content data in object.";
    $r = 0;
  }

  if ($strict) {
    my $host = $self->getHost();
    unless (defined $host && length($host) > 0) {
      $self->{_error} = "Invalid data object: Undefined or zero-length hostname.";
      $r = 0;
    }
  }

  return $r;
}

=head1 GETTER METHODS

=head2 getContent ([$as_ref = 0])

Returns raw content on success, otherwise undef.
If invoked with true argument reference to content will be returned.

=cut

sub getContent {
  my ($self, $as_ref) = @_;
  $as_ref = 0 unless (defined $as_ref);
  unless (defined $self->{_content}) {
    $self->{_error} = "Undefined content.";
  }

  return ($as_ref) ? \$self->{_content} : $self->{_content};
}

=head2 getFetchStartTime ()

Retrieves fetch start time.

=cut

sub getFetchStartTime {
  my ($self) = @_;
  unless ($self->{_fetchStarted}) {
    $self->{_error} = "Fetch start time is not set.";
  }
  return $self->{_fetchStarted};
}

=head2 getFetchDoneTime()

Returns time on which fetch was completed.

=cut

sub getFetchDoneTime {
  my ($self) = @_;
  unless ($self->{_fetchEnded}) {
    $self->{_error} = "Fetch start time is not set.";
  }
  return $self->{_fetchEnded};
}

=head2 getFetchDuration ()

Returns fetch duration time in seconds with microsecond precision.

=cut

sub getFetchDuration {
  my ($self) = @_;
  return $self->{_fetchEnded} - $self->{_fetchStarted};
}

=head2 getUrl ()

Returns fetch URL as string.

=cut

sub getUrl {
  my ($self) = @_;
  return $self->{_url};
}

=head2 getHost()

Returns fetch hostname on success, otherwise undef.

=cut

sub getHost {
  my ($self) = @_;
  return $self->{_host} if (defined $self->{_host});
  my $uri = URI->new($self->getUrl());
  if (defined $uri) {
    if ($uri->can("host")) {
      return $uri->host();
    }
  }
  return undef;
}

=head2 getPort ()

Returns fetch port if can be detected, otherwise undef.

=cut

sub getPort {
  my ($self) = @_;
  return $self->{_port} if (defined $self->{_port});
  my $uri = URI->new($self->getUrl());
  if (defined $uri) {
    if ($uri->can("port")) {
      return $uri->port();
    }
  }
  return 0;
}

=head2 getDriver ()

Returns fetch driver name.

=cut

sub getDriver {
  my ($self) = @_;
  return $self->{_driver};
}

=head2 getId ()

Returns unique fetch id.

=cut

sub getId {
  my ($self) = @_;
  return $self->{_id};
}

=head2 getParser ()

Returns list of parser names that should parse raw content.

=cut

sub getParser {
  my ($self) = @_;
  return @{$self->{_parser}};
}

=head2 getFilter ()

Returns name of filter that should filter parsed content.

=cut

sub getFilter {
  my ($self) = @_;
  return @{$self->{_filter}};
}

=head2 getDebugParsedData ()

Returns debug parsed data flag.

=cut

sub getDebugParsedData {
  my ($self) = @_;
  return $self->{_debugParsedData};
}

=head2 getStorage ()

Returns list of storage object candidates in which this object requests to be written.

=cut

sub getStorage {
  my ($self) = @_;
  return @{$self->{_storage}};
}

=head2 length()

Synonym for L<size()> method. 

=cut

sub length {
  my ($self) = @_;
  return $self->size();
}

=head2 size ()

Returns length of stored content in bytes.

=cut

sub size {
  my ($self) = @_;
  return 0 unless (defined $self->{_content});
  return CORE::length($self->{_content});
}

=head2 getSignature ()

Returns this object signature string.

=cut

sub getSignature {
  my ($self) = @_;
  unless (defined $self->{_signature}) {

    # [ZC5K2EIQ7T :: HTTP :: http://www.najdi.si/status/search.jsp]
    no warnings;
    $self->{_signature} = "[" . $self->getId() . " :: " . $self->getDriver() . " :: " . $self->getUrl() . "]";
  }

  return $self->{_signature};
}

=head1 SETTER METHODS - YOU BETTER KNOW WHAT YOU'RE DOING WHILE USING THEM!

=head2 setContent ($data)

Sets raw content (string).

=cut

sub setContent {
  my ($self, $data) = @_;
  unless (defined $data) {
    $self->{_error} = "Undefined content.";
    return 0;
  }

  $self->{_content} = $data;
  return 1;
}

=head2 setFetchStartTime($time)

Sets fetch start time.

=cut

sub setFetchStartTime {
  my ($self, $t) = @_;

  # convert to number
  { no warnings; $t += 0; }
  unless (defined $t && $t > 0) {
    $self->{_error} = "Invalid time argument.";
    return 0;
  }

  $self->{_fetchStarted} = $t;
  return 1;
}

=head2 setFetchDoneTime ($time)

Sets time on which fetch was completed.

=cut

sub setFetchDoneTime {
  my ($self, $t) = @_;

  # convert to number
  { no warnings; $t += 0; }
  unless (defined $t && $t > 0) {
    $self->{_error} = "Invalid time argument.";
    return 0;
  }

  $self->{_fetchEnded} = $t;
  return 1;
}

=head2 setUrl ($url)

Sets fetch URL which must be string.

=cut

sub setUrl {
  my ($self, $url) = @_;
  $self->{_url} = $url;
  return 1;
}

=head2 setHost ($hostname)

Sets fetch hostname.

=cut

sub setHost {
  my ($self, $host) = @_;

  # trim spaces
  $host =~ s/\s+//g;
  $self->{_host} = $host;
  return 1;
}

=head2 setPort ($port)

Sets fetch port number.

=cut

sub setPort {
  my ($self, $port) = @_;
  return 0 unless (defined $port);
  $self->{_port} = $port;
  return 1;
}

=head2 setDriver ($name)

Sets fetch driver name

=cut

sub setDriver {
  my ($self, $name) = @_;
  $self->{_driver} = $name;
  return 1;
}

=head2 setId ($id)

Sets unique fetch id.

=cut

sub setId {
  my ($self, $id) = @_;
  $self->{_id} = $id;
  return 1;
}

=head2 setParser ($name, $name2, ...)

Sets list of parser names that should parse raw content.

=cut

sub setParser {
  my $self = shift;
  @{$self->{_parser}} = @_;
  return 1;
}

=head2 setFilter ($name, ...)

Sets name(s) of filter(s) that should filter parsed content.

=cut

sub setFilter {
  my $self = shift;
  @{$self->{_filter}} = @_;
  return 1;
}

=head2 setDebugParsedData ([$val = 1])

Sets debug parsed data flag.

=cut

sub setDebugParsedData {
  my ($self, $val) = @_;
  $val = 1 unless (defined $val);
  $self->{_debugParsedData} = $val;
  return 1;
}

=head2 setStorage ($name, $name2, ...)

Sets comma separated list of Statcollector storage object names in which this
object requests to be written.

Returns 1 on success, otherwise 0. 

=cut

sub setStorage {
  my $self = shift;
  @{$self->{_storage}} = @_;
  return 1;
}

=head2 toString ()

Returns serialized/string representation of current object, suitable for
eval or sending over network.

Returns string representation on success, otherwise undef.

=cut

sub toString {
  my ($self) = @_;

  # check object "health" :)
  return undef unless ($self->isValid(1));

  my $ref                = ref($self);
  my $url                = $self->getUrl();
  my $host               = $self->getHost();
  my $date               = strftime("%Y/%m/%d %H:%M:%S", localtime(time()));
  my $fetch_started      = $self->getFetchStartTime();
  my $fetch_started_date = strftime("%Y/%m/%d %H:%M:%S", localtime($fetch_started));
  my $fetch_ended        = $self->getFetchDoneTime();
  my $fetch_duration     = sprintf("%-.3f", ($self->getFetchDuration() * 1000));

  # header
  my $str = <<EOF
#
# Object:          $ref 
# Freeze date:     $date 
#
# URL:             $url
# Host:            $host
#
# Fetch duration:  $fetch_duration msec
# Fetch started:   $fetch_started [$fetch_started_date]
# Fetch ended:     $fetch_ended
#

EOF
    ;

  # data
  my $d = Data::Dumper->new([$self]);
  $d->Terse(1);
  $d->Indent(1);
  $str .= $d->Dump();

  # footer
  $str .= "\n# EOF";

  return $str;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _init {
  return 1;
}

sub _getMetaData {
  my ($self) = @_;
  my $data = {};
  foreach (keys %{$self}) {
    next unless ($_ =~ m/^_/);
    next if ($_ eq '_content');
    $data->{$_} = $self->{$_};
  }

  return $data;
}

sub _setMetaData {
  my ($self, $data) = @_;
  return 0 unless (defined $data && ref($data) eq 'HASH');

  foreach (keys %{$data}) {
    next unless ($_ =~ m/^_/);
    next if ($_ eq '_content');
    $self->{$_} = $data->{$_};
  }

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector>
L<ACME::TC::Agent::Plugin::StatCollector::Source>
L<ACME::TC::Agent::Plugin::StatCollector::Parser>
L<ACME::TC::Agent::Plugin::StatCollector::Storage>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
