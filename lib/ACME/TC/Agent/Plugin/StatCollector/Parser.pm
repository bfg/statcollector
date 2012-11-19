package ACME::TC::Agent::Plugin::StatCollector::Parser;


use strict;
use warnings;

use IO::Scalar;
use Log::Log4perl;
use Time::HiRes qw(time);
use Scalar::Util qw(blessed);

use ACME::TC::Agent::Plugin::StatCollector::RawData;
use ACME::TC::Agent::Plugin::StatCollector::ParsedData;

use base qw(ACME::Util::ObjFactory);

our $VERSION = 0.02;

my $Error = "";

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser

Abstract statistics parser

=head1 SYNOPSIS

 my $driver = "DUMMY";
 my %opt = (
 	paramName => "paramValue",
 );
 
 my $parser = ACME::TC::Agent::Plugin::StatCollector::Parser->factory(
 	$driver,
 	%opt
 );
 
 $parsed_data = $parser->parse($raw_data);

=head1 DESCRIPTION

Parser parses content of L<ACME::TC::Agent::Plugin::StatCollector::RawData>
object into L<ACME::TC::Agent::Plugin::StatCollector::ParsedData> object.

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
  $self->clearParams();
  $self->setParams(@_);

  # don't initialize if requested
  no warnings;
  my %o = @_;
  return $self if (exists($o{no_init}) && $o{no_init});
  delete($o{no_init});

  # try to initialize
  unless ($self->init()) {
    $Error = $self->{_error};
    $_log->error("Error initializing parser " . ref($self) . ": " . $Error);
    return undef;
  }

  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor returns initialized object on success, otherwise undef
and sets class error message.

Object constructor accepts the following key => value arguments:

=over

=item B<name> (string, <driver_name>):

Parser name.

=back

=head1 METHODS

=head2 clearParams ()

Resets parser configuration to default values.
Returns 1 on success, otherwise 0.

=cut

sub clearParams {
  my ($self) = @_;

  # "public" settings
  $self->{name} = $self->getDriver();

  # private settings
  $self->{_error} = "";                          # last error message
  $self->{name}   = $self->_getBasePackage();    # parser name

  # statistics
  $self->resetStatistics();

  return 1;
}

=head2 getError()

Returns last error accoured.

=cut

sub getError {
  my $self = shift;
  return $self->{_error};
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

  $self->{$name} = $value;
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

Returns parser name.

=cut

sub getName {
  my ($self) = @_;
  return $self->{name};
}

=head2 setName ($name)

Sets parser name. Returns 1 on success, otherwise 0.

=cut

sub setName {
  my ($self, $name) = @_;
  $self->{name} = $name;
}

=head2 getStatistics ()

Returns object containing source statistics

=cut

sub getStatistics {
  my ($self) = @_;
  my $data = {};
  %{$data} = %{$self->{_stats}};

  # calculate averages...
  $data->{timeParsesTotalAvg}
    = ($data->{numParsesTotal} != 0) ? ($data->{timeParsesTotal} / $data->{numParsesTotal}) : 0;
  $data->{timeParsesOkAvg} = ($data->{numParsesOk} != 0) ? ($data->{timeParsesOk} / $data->{numParsesOk}) : 0;
  $data->{timeParsesErrAvg}
    = ($data->{numParsesErr} != 0) ? ($data->{timeParsesErr} / $data->{numParsesErr}) : 0;
  $data->{successRatio}
    = ($data->{numParsesTotal} != 0)
    ? sprintf("%-.2f", ($data->{numParsesOk} / $data->{numParsesTotal}) * 100)
    : 0.00;

  return $data;
}

=head2 resetStatististics ()

Resets internal fetching statistics counters.

=cut

sub resetStatistics {
  my ($self) = @_;

  # $_log->info($self->getSourceSignature(),  " Reseting fetch statistics counters.");
  $self->{_stats} = {
    numParsesTotal  => 0,
    numParsesOk     => 0,
    numParsesErr    => 0,
    timeParsesTotal => 0,
    timeParsesOk    => 0,
    timeParsesErr   => 0,
  };
}

=head2 parse ($raw_obj)

Parses content of provided L<ACME::TC::Agent::Plugin::StatCollector::RawData>
object and returns L<ACME::TC::Agent::Plugin::StatCollector::ParsedData> object
on success, otherwise undef.

=cut

sub parse {
  my ($self, $raw) = @_;
  $self->{_error} = "";

  # check raw data object...
  unless (defined $raw && blessed($raw) && $raw->isa("ACME::TC::Agent::Plugin::StatCollector::RawData")) {
    $self->{_error} = "Invalid raw data object.";
    return undef;
  }

  # allocate parsed data object...
  my $parsed = ACME::TC::Agent::Plugin::StatCollector::ParsedData->newFromRaw($raw);
  unless (defined $parsed) {
    $self->{_error} = "Unable to create parsed data object: "
      . ACME::TC::Agent::Plugin::StatCollector::ParsedData->getError();
    return undef;
  }

  my $id = $raw->getId();

  # we have a object... let our parser implementation do
  # the job...
  my $ts       = time();
  my $d        = $self->_parse($raw->getContent(1));
  my $te       = time();
  my $duration = $te - $ts;
  $_log->debug(
    "[" . $self->getName() . "]" . " [$id] Parsing took " . sprintf("%-.3f", ($duration * 1000)) . " msec.");

  # update stats
  $self->_updateStats($duration, ((defined $d) ? 1 : 0));

  unless ($d) {
    $self->{_error} = "Error parsing content: " . $self->{_error};
    return undef;
  }

  # assign parsed data...
  unless ($parsed->setContent($d)) {
    $self->{_error} = "Error assigning parsed content: " . $parsed->getError();
    return undef;
  }

  # return parsed data object...
  return $parsed;
}

=head2 getDataFd ($data)

Returns filedescript for easy reading and parsing of raw data. Provided argument
must be string or string reference. Returns valid filedescriptor opened for
reading on success, otherwise undef.

=cut

sub getDataFd {
  my ($self, $data) = @_;

  unless (defined $data) {
    $self->{_error} = "Nothing to parse: got undefined string.";
    return undef;
  }
  my $ref_name = ref($data);
  my $ref      = undef;
  if ($ref_name eq '') {
    $ref = \$data;
  }
  elsif ($ref_name ne 'SCALAR') {
    $self->{_error} = "Don't know how to parse $ref_name reference.";
    return undef;
  }
  else {
    $ref = $data;
  }

  # open filehandle
  my $fd = IO::Scalar->new($ref, 'r');
  unless (defined $fd) {
    $self->{_error} = "Unable to create filehandle on string: $!";
    return undef;
  }

  return $fd;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 EXTENDING CLASS

=head2 init ()

This method is called from object constructor after all configuration parameters
are set. You can implement this method to initialize implementation-specific stuff
that needs to be done before parsing can be performed.

This method must return 1 in case of successful initialization, otherwise must return
0.

=cut

sub init {
  return 1;
}

=pod

You B<MUST> implement the following methods in your source
implementatations:

=head2 _parse($raw_data_ref)

=cut

sub _parse {
  my ($self) = @_;
  $self->{_error} = "Method _parse() is not implemented in class " . ref($self) . ".";
  return undef;
}

sub _getBasePackage {
  my ($self, $obj) = @_;
  $obj = $self unless (defined $obj);
  my @tmp = split(/::/, ref($obj));
  return pop(@tmp);
}

sub _updateStats {
  my ($self, $duration, $ok) = @_;
  $ok = 1 unless (defined $ok);

  $self->{_stats}->{numParsesTotal}++;
  $self->{_stats}->{timeParsesTotal} += $duration;

  if ($ok) {
    $self->{_stats}->{numParsesOk}++;
    $self->{_stats}->{timeParsesOk} += $duration;
  }
  else {
    $self->{_stats}->{numParsesErr}++;
    $self->{_stats}->{timeParsesErr} += $duration;
  }
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::RawData>
L<ACME::TC::Agent::Plugin::StatCollector::ParsedData>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
