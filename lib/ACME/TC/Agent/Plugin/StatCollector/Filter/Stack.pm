package ACME::TC::Agent::Plugin::StatCollector::Filter::Stack;


use strict;
use warnings;

use Log::Log4perl;
use Time::HiRes qw(time);
use Scalar::Util qw(blessed);

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

use constant CLASS_FILTER        => 'ACME::TC::Agent::Plugin::StatCollector::Filter';
use constant CLASS_STATCOLLECTOR => 'ACME::TC::Agent::Plugin::StatCollector';
use constant CLASS_PARSED_DATA   => 'ACME::TC::Agent::Plugin::StatCollector::ParsedData';

our $VERSION = 0.03;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::Stack

Filter parsed data using stack of filters.

=head1 SYNOPSIS

 my %opt = (
 	$filter_object,
 	"OtherFilterName",
 	{ driver => "Simple", suffix => "[8080]" },
 	{ driver => "PCRE", regexFile => "/path/to/file.pcre", },
 );
 
 my $stack = ACME::TC::Agent::Plugin::StatCollector::Filter::Stack->new(%opt);
 
 my $filtered_data = $stack->filter($data);

=head1 DESCRIPTION

TODO

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and
the following:

=over

=item B<stack> ([], array reference)

Array of hash references containing settings of containing parser objects.

Example:

 stack => [
 	# Already initialized filter object
 	$filter_obj,

 	# New, private filter object configuration
  	{ driver => "Simple", prefix => "keyPrefix.", suffix => "[8080]" },
 	
 	# already existing parser object namex "SomeParser"
 	# currently already assigned to StatCollector object
 	# owning current filter object
 	"SomeParser",
 ]

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################


sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # filter stack description...
  $self->{stack} = [

    # { driver => "Simple"},
    ],

    # filter objects...
    $self->{_chain} = [];

  return 1;
}

sub init {
  my ($self) = @_;

  my $err = "Unable to initialize filter stack: Invalid filter stack configuration element";

  my $i = 0;
  foreach my $e (@{$self->{stack}}) {
    $i++;

    # what kind of argument is this?
    # invalid stuff...
    if (!defined $e) {
      $self->{_error} = $err . " $i: undefined element.";
      return 0;
    }

    # filter object?
    elsif (blessed($e) && $e->isa(CLASS_FILTER)) {
      push(@{$self->{_chain}}, $e);
    }

    # filter configuration
    elsif (ref($e) eq 'HASH') {

      # weed out driver
      my $driver = undef;
      if (exists $e->{driver}) {
        $driver = $e->{driver};
        delete($e->{driver});
      }
      unless (defined $driver && length($driver)) {
        $self->{_error} = $err . " $i: undefined filter driver.";
        return 0;
      }

      # try to initialize object...
      my $obj = CLASS_FILTER->factory($driver, %{$e}, timingEnabled => 0);
      unless (defined $obj) {
        $self->{_error} = $err . " $i: Error loading filter driver $driver: " . CLASS_FILTER->factoryError();
        return 0;
      }

      # assign filter object to chain
      push(@{$self->{_chain}}, $obj);
    }

    # named filter ...
    elsif (ref($e) eq '' && length($e) > 0) {

      # fetch object reference...
      my $obj = $self->_getExternalFilter($e);
      return 0 unless (defined $obj);

      # assign filter object to chain
      push(@{$self->{_chain}}, $obj);
    }

    # invalid configuration element...
    else {
      $self->{_error} = $err . " $i: Invalid filter element: " . ref($e);
      return 0;
    }
  }

  unless ($i) {
    $self->{_error} = "There are no configured filters in stack.";
    return 0;
  }

  return 1;
}

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

  # filter $res with all filters in chain
  foreach (@{$self->{_chain}}) {
    $res = $_->filter($res);
    unless (defined $res) {
      $self->{_error}
        = "Chain filter " . $_->getName() . "[driver " . $_->getDriver() . "] failed: " . $_->getError();
      $res = undef;
      last;
    }
  }

  if ($self->{timingEnabled}) {
    my $te       = time();
    my $duration = $te - $ts;

    # update stats
    $self->_updateStats($duration, ((defined $res) ? 1 : 0));
    if ($_log->is_debug()) {
      $_log->debug(
        "[" . $data->getId() . "] Filtering took " . sprintf("%-.3f", ($duration * 1000)) . " msec.");
    }
  }

  # return filtered data object...
  return $res;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _getExternalFilter {
  my ($self, $name) = @_;

  # get stat collector reference
  my $ref = $self->getStatCollectorRef();
  unless (defined $ref && ${$ref}->isa(CLASS_STATCOLLECTOR)) {
    $self->{_error} = "Unable to get StatCollector object reference. This is BUG!!!";
    return undef;
  }

  # search trough filters...
  foreach (keys %{${$ref}->{_filter}}) {

    # is this what we're looking for?
    if ($_ eq $name) {
      return ${$ref}->{_filter}->{$_};
    }
  }

  $self->{_error} = "Non-existing filter reference '$name'";
  return undef;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Filter>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
