package ACME::TC::Agent::Plugin::StatCollector::Filter::FetchMeta;


use strict;
use warnings;

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

our $VERSION = 0.01;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::FetchMeta

This filter adds source fetch metadata to list parsed statistic keys.
This is B<content-only> filter.

=head1 DESCRIPTION

This filter adds the following keys to filtered object:

=over

=item B<fetchStartTime> (float): fetch start time since epoch with microsecond precision

=item B<fetchDoneTime> (float): fetch done time since epoch with microsecond precision

=item B<fetchDuration> (float): fetch duration in seconds with microsecond precision

=item B<fetchDurationMsec> (float): fetch duration in milliseconds with microsecond precision

=item B<url> (string): fetch url

=item B<driver> (string): fetch driver

=item B<id> (string): fetch id

=item B<size> (integer): parsed data structure size in bytes

=back

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and the following ones:

=over

=item B<reset> (boolean, 0):

Remove all content from parsed object before injecting metadata.

=back

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{reset} = 0;

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterObj {
  my ($self, $data) = @_;

  # remove all content from data if requested.
  if ($self->{reset}) {
    $data->resetData();
  }

  $data->setKey('fetchStartTime', $data->getFetchStartTime());
  $data->setKey('fetchDoneTime',  $data->getFetchDoneTime());
  $data->setKey('fetchDuration',  $data->getFetchDuration());
  $data->setKey('fetchDurationMsec', ($data->getFetchDuration() * 1000));
  $data->setKey('url',    $data->getUrl());
  $data->setKey('driver', $data->getDriver());
  $data->setKey('id',     $data->getId());
  $data->setKey('size',   $data->size());

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Filter>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
