package ACME::TC::Agent::Plugin::StatCollector::Filter::UpperCase;


use strict;
use warnings;

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

our $VERSION = 0.01;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::UpperCase

Uppercase all stored statistics keys. This is B<content-only> filter.

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter>

=cut

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterContent {
  my ($self, $data) = @_;

  # iterate trough keys...
  map {
    my $k = uc($_);
    my $v = $data->{$_};

    # remove old key
    delete($data->{$_});

    # install new one :)
    $data->{$k} = $v;
  } keys %{$data};

  return $data;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Filter>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
