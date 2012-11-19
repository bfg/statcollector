package ACME::TC::Agent::Plugin::StatCollector::Parser::Static;


use strict;
use warnings;

use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

our $VERSION = 0.01;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::Static

Static statistics "parser".

=head1 DESCRIPTION

This parser is not actually a parser - it returns the same data regardles
given content.

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts the following named parameters:

=over

=item B<data> (hash reference, {}):

Key => value data you want to be returned by this parser. 

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{data} = {};
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _parse {
  my ($self, $str) = @_;
  my $data = {};
  %{$data} = %{$self->{data}};
  return $data;
}


=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Parser>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
