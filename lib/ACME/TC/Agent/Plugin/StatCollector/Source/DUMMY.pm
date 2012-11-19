package ACME::TC::Agent::Plugin::StatCollector::Source::DUMMY;


use strict;
use warnings;

use POE;
use Log::Log4perl;

use ACME::TC::Agent::Plugin::StatCollector::Source;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Source);

our $VERSION = 0.01;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Source::DUMMY

Non-operational source example.

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts all named parameters supported by 
L<ACME::TC::Agent::Plugin::StatCollector::Source> and the
following ones:

=over

=item B<configProperty> (integer, 10):

Example source configuration property...

=over

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{configProperty} = 10;

  # exposed POE object events
  $self->registerEvent(
    qw(
      _someEvent
      )
  );

  # must return 1 on success
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _run {
  my ($self) = @_;

  # possibly check for configuration parameters...
  # if this method's return value is 0, source will fail to start.
  if ($self->{configProperty} < 1 || $self->{configProperty} > 20) {
    $self->{_error} = "Invalid config property configProperty: $self->{configProperty}";
    return 0;
  }

  # everything is ok, start fetching data...
  return 1;
}

sub _fetchStart {
  my ($self) = @_;

  # this will schedule POE event _someEvent, running $self->_someEvent() method
  # in $delay seconds...
  my $delay = (rand() * 20);
  $_log->info($self->getFetchSignature(),
    " Custom fetchdata stuff: response will be in " . sprintf("%-.3f", $delay) . " seconds.");

  # prepare fetch "data"
  my $data = "someParameter: " . int(rand() * 1000);

  # schedule it...
  $poe_kernel->delay_add("_someEvent", $delay, $data);

  # _someEvent will then decide if fetch was successful.
}

sub _fetchCancel {
  my ($self) = @_;
  $_log->warn($self->getFetchSignature(), " Canceling all " . ref($self) . " requests.");
  return 1;
}

sub _someEvent {
  my ($self, $kernel, $data) = @_[OBJECT, KERNEL, ARG0];

  # no we'll decide if fetch was successful...
  my $r = (rand() > 0.5) ? 1 : 0;

  # schedule correct event according to $r
  if ($r) {
    $kernel->yield(FETCH_OK, "$data");
  }
  else {
    $kernel->yield(FETCH_ERR, "Random function decided that this fetch will absolutely fail...");
  }
}


=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent::Plugin::StatCollector::Source>
L<ACME::TC::Agent::Plugin::StatCollector>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
