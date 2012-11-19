package ACME::TC::Agent::Plugin::StatCollector::Filter::Numeric;


use strict;
use warnings;

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

our $VERSION = 0.03;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::Numeric

Applies float number precision to all stored values and optionally removes
keys holding non-numeric values. This is B<content-only> filter.

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and the following ones:

=over

=item B<removeStrings> (boolean, 1):

Remove all keys that don't hold numeric values.

=item B<fracPrecision> (integer, 2):

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{removeStrings} = 1;
  $self->{fracPrecision} = 2;

  return 1;
}

sub init {
  my ($self) = @_;
  no strict;
  no warnings;

  unless (defined $self->{fracPrecision} && $self->{fracPrecision} >= 0) {
    $self->{fracPrecision} = 2;
  }
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterContent {
  my ($self, $data) = @_;

  # create sprintf formatting string...
  my $fmt = '%-.' . $self->{fracPrecision} . 'f';

  no warnings;

  # iterate trough keys...
  foreach (keys %{$data}) {

    # get value and perform simple validation...
    my $v = $data->{$_};
    unless (defined $v && length($v) > 0) {
      delete($data->{$_});
      next;
    }

    # should we remove non-numeric values?
    if ($self->{removeStrings}) {
      if ($v =~ m/[^\-\+\.0-9]+/) {
        delete($data->{$_});
        next;
      }
    }

    # apply float precision and replace value
    $data->{$_} = sprintf($fmt, $v);
  }

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
