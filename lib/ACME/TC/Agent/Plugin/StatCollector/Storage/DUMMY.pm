package ACME::TC::Agent::Plugin::StatCollector::Storage::DUMMY;


use strict;
use warnings;

use POE;

use Log::Log4perl;

use ACME::TC::Agent::Plugin::StatCollector::Storage;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Storage);

our $VERSION = 0.01;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Storage::DUMMY

Non-operation example storage implementation for StatCollector.

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin::StatCollector::Storage>
and the following ones:

=over

=item B<maxDelay> (float, 10.5)

Maximum storage delay in seconds.

=back

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # public stuff

  $self->{maxDelay} = 10.5;    # maximum storage delay...

  # private stuff...

  $self->{_queue} = {};        # storage queue...

  # exposed POE object events
  $self->registerEvent(
    qw(
      _doStore
      )
  );

  # must return 1 on success
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

# enqueue storage...
sub _store {
  my ($self, $id, $data) = @_;

  # calculate storage delay :)
  my $delay = (rand() * $self->{maxDelay} * 1000);
  $_log->debug($self->getStoreSig($id) . "Storage will be delayed for $delay msec.");

  # enqueue storage...
  my $aid = $poe_kernel->alarm_set('_doStore', (time() + ($delay / 1000)), $id, $data);

  # save request in storage queue
  #
  # we'll save alarm id, so we can cancel
  # alarm later in _storeCancel() if necessary
  $self->{_queue}->{$id} = $aid;

  # storage request was successfully enqueued
  return 1;
}

sub _storeCancel {
  my ($self, $sid) = @_;
  unless (exists($self->{_queue}->{$sid})) {
    $self->{_error} = "Non-existing storage request id: $sid";
    return 0;
  }

  # get kernel alarm id...
  my $aid = $self->{_queue}->{$sid};

  $_log->debug($self->getStoreSig($sid) . "Canceling storage request $sid [alarm id: $aid]");
  $poe_kernel->alarm_remove($aid);
  return 1;
}

# shutdown!
sub _shutdown {
  my ($self) = @_;

  #
  # perform some additional cleanup...
  #
  return 1;
}

sub _doStore {
  my ($self, $kernel, $id, $data) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # do something with $data...

  # will be storage successful?
  if (rand() > 0.5) {

    # storing $data ended with success...
    $kernel->yield(STORE_OK, $id, "This is optional, implementation specific additional success message");
  }
  else {

    # there was error storing $data
    $kernel->yield(STORE_ERR, $id, "rand() function decided that this store request will fail!");
  }
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::ParsedData>
L<ACME::TC::Agent::Plugin::StatCollector::Storage>
L<ACME::TC::Agent::Plugin::StatCollector>
L<POE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
