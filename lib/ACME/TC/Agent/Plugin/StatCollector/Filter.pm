package ACME::TC::Agent::Plugin::StatCollector::Filter;


use strict;
use warnings;

use Log::Log4perl;
use Time::HiRes qw(time);
use Scalar::Util qw(blessed);

use ACME::TC::Agent::Plugin::StatCollector::ParsedData;

use base qw(ACME::Util::ObjFactory);

use constant CLASS_PARSED_DATA => 'ACME::TC::Agent::Plugin::StatCollector::ParsedData';

our $VERSION = 0.03;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

my $Error = '';

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter

Abstract statistics filter.

=head1 SYNOPSIS

 my $filter = ACME::TC::Agent::Plugin::StatCollector::Filter->factory(
 	$driver,
 	%opt
 );
 
 my $filtered_data = $filter->parse($parsed_data);

=head1 DESCRIPTION

Filter changes content of L<ACME::TC::Agent::Plugin::StatCollector::ParsedData>
object.

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

Filter name.

=item B<timingEnabled> (boolean, 1):

Enable timings (filtering duration tracking)

=back

=head1 METHODS

=head2 clearParams ()

Resets filter configuration to default values.

Returns 1 on success, otherwise 0.

=cut

sub clearParams {
  my ($self) = @_;

  # "public" settings
  $self->{name}          = $self->getDriver();
  $self->{timingEnabled} = 1;

  # private settings
  $self->{_error}          = "";                          # last error message
  $self->{__statCollector} = undef;                       # owning statcollector object reference
  $self->{name}            = $self->_getBasePackage();    # filter name

  # statistics
  $self->resetStatistics();

  return 1;
}

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

  # this is ugly...
  if ($name eq '__statCollector') {
    $self->{$name} = $value;
    return 1;
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

=head2 getName ()

Returns filter name.

=cut

sub getName {
  my ($self) = @_;
  return $self->{name};
}

=head2 setName ($name)

Sets parser name. Returns  1 on success, otherwise 0.

=cut

sub setName {
  my ($self, $name) = @_;
  $self->{name} = $name;
}

=head2 getDriver ()

Returns implementation driver as string.

=cut

sub getDriver {
  my ($self) = @_;
  return $self->_getBasePackage();
}

=head2 getStatistics ()

Returns object containing source statistics

=cut

sub getStatistics {
  my ($self) = @_;
  my $data = {};
  %{$data} = %{$self->{_stats}};

  # calculate averages...
  $data->{timeFilteringsTotalAvg}
    = ($data->{numFilteringsTotal} != 0) ? ($data->{timeFilteringsTotal} / $data->{numFilteringsTotal}) : 0;
  $data->{timeFilteringsOkAvg}
    = ($data->{numFilteringsOk} != 0) ? ($data->{timeFilteringsOk} / $data->{numFilteringsOk}) : 0;
  $data->{timeFilteringsErrAvg}
    = ($data->{numFilteringsErr} != 0) ? ($data->{timeFilteringsErr} / $data->{numFilteringsErr}) : 0;
  $data->{successRatio}
    = ($data->{numFilteringsTotal} != 0)
    ? sprintf("%-.2f", ($data->{numFilteringsOk} / $data->{numFilteringsTotal}) * 100)
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
    numFilteringsTotal  => 0,
    numFilteringsOk     => 0,
    numFilteringsErr    => 0,
    timeFilteringsTotal => 0,
    timeFilteringsOk    => 0,
    timeFilteringsErr   => 0,
  };
}

=head2 filter ($parsed_data_obj)

=cut

sub filter {
  my ($self, $data) = @_;
  $self->{_error} = "";

  my $ts = 0;
  $ts = time() if ($self->{timingEnabled});

  # check raw data object...
  unless (defined $data && blessed($data) && $data->isa(CLASS_PARSED_DATA)) {
    $self->{_error} = "Invalid parsed data object.";
    return undef;
  }

  # create new parsed data object...
  my $res = $data->clone();
  return undef unless (defined $res);

  # parse content!
  my $d = $self->_filterContent($res->getContent(1), $res);
  unless ($d) {
    $self->{_error} = "Error filtering content: " . $self->{_error};
    return undef;
  }

  # assign filtered data...
  unless ($res->setContent($d)) {
    $self->{_error} = "Error assigning filtered content: " . $res->getError();
    return undef;
  }

  # filter object!
  unless ($self->_filterObj($res)) {
    $self->{_error} = "Error filtering object: " . $self->getError();
    return undef;
  }

  my $id = $data->getId();

  if ($self->{timingEnabled}) {
    my $te       = time();
    my $duration = $te - $ts;

    # update stats
    $self->_updateStats($duration, ((defined $d) ? 1 : 0));

    $_log->debug("["
        . $self->getName() . "]"
        . " [$id] Filtering took "
        . sprintf("%-.3f", ($duration * 1000))
        . " msec.");
  }

  # return filtered data object...
  return $res;
}

sub setStatCollectorRef {
  my ($self, $ref) = @_;
  $self->{__statCollector} = $ref;
}

sub getStatCollectorRef {
  my ($self) = @_;
  return (exists($self->{__statCollector}) && defined $self->{__statCollector})
    ? $self->{__statCollector}
    : undef;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 EXTENDING CLASS

You B<MAY> optionally implement the following method(s):

=head2 init ()

This method is called from object constructor after all configuration parameters
are set. You can implement this method to initialize implementation-specific stuff
that needs to be done before filtering can be started.

This method must return 1 in case of successful initialization, otherwise must return
0.

=cut

sub init {
  return 1;
}

=pod

You B<MUST> implement at least or one (or both) of the following methods
in your filter implementatations:

=head2 _filterContent($hash_ref, $parsed_data_obj)

This method is called with key => value hash reference containing
parsed data. This method can alter key names, values or both.

This method must return back hash reference on success
or undef in case of error.

=cut

sub _filterContent {
  my ($self, $data, $obj) = @_;
  my $d = {};
  %{$d} = %{$data};
  return $d;
}

=head2 _filterObj ($data_obj)

This method is optional; This method is called with the complete parsed data
object. Using this method you can alter parsed data object metadata and
parsed data object content.

This method must return 1 on success, otherwise 0.

=cut

sub _filterObj {
  my ($self, $obj) = @_;
  return 1;
}

sub _updateStats {
  my ($self, $duration, $ok) = @_;
  $ok = 1 unless (defined $ok);

  $self->{_stats}->{numFilteringsTotal}++;
  $self->{_stats}->{timeFilteringsTotal} += $duration;

  if ($ok) {
    $self->{_stats}->{numFilteringsOk}++;
    $self->{_stats}->{timeFilteringsOk} += $duration;
  }
  else {
    $self->{_stats}->{numFilteringsErr}++;
    $self->{_stats}->{timeFilteringsErr} += $duration;
  }
}

sub _getBasePackage {
  my ($self, $obj) = @_;
  $obj = $self unless (defined $obj);
  my @tmp = split(/::/, ref($obj));
  return pop(@tmp);
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
