package ACME::TC::Agent::Plugin::StatCollector::Filter::ExcludeExcept;


use strict;
use warnings;

use ACME::TC::Agent::Plugin::StatCollector::Filter::Exclude;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter::Exclude);

our $VERSION = 0.01;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::ExcludeExcept

Strip off unwanted keys from statistics data by specifying keys you B<WANT TO KEEP>.
This is B<content-only> filter.

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and the following ones:

=over

=item B<keep> (string, filename or arrayref, ""):

Filename containing one regex per line, comma or semicolon separated string or arrayref
containing regular expressions of desired keys.
After filtering data structure will contain B<ONLY> keys that B<DO MATCH ANY OF SPECIFIED> regexes.

=item B<nocase> (boolean, 1):

Perform case-insensitive regex matching.

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # remove parent's stuff..
  delete($self->{exclude});

  # our stuff
  $self->{keep}   = "";
  $self->{nocase} = 1;

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterContent {
  my ($self, $data) = @_;

  # iterate trough regexes...
  foreach my $key (keys %{$data}) {
    my $remove = 1;
    foreach (@{$self->{_regex}}) {
      if ($key =~ $_) {
        $remove = 0;
        last;
      }
    }

    # remove key if necessary...
    delete($data->{$key}) if ($remove);
  }

  return $data;
}

sub _getRegexSources {
  my ($self) = @_;
  my @res = ();

  if (ref($self->{keep}) eq 'ARRAY') {
    push(@res, @{$self->{keep}});
  }
  else {
    push(@res, $self->{keep});
  }

  return @res;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Filter>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
