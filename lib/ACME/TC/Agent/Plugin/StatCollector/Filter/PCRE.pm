package ACME::TC::Agent::Plugin::StatCollector::Filter::PCRE;


use strict;
use warnings;

use ACME::Util::Map::PCRE;

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

our $VERSION = 0.01;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::PCRE

Perl compatible regex statististics filter. This is B<content-only> filter.

=head1 DESCRIPTION

Implementation of PCRE rewriting and filtering of statistics
keys. 

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and
the following:

=over

=item B<regexFile> (string, undef)

Path to file containing postfix pcre_table(5)
(See L<http://www.postfix.org/pcre_table.5.html>) rules for
rewriting statistics keys.

If PCRE map returns "DELETE" or "REMOVE", key will be removed
from original set. If PCRE map returns undef (no pcre rule in
regex file matched given key) key remains unchanged. 

Example:
 
 # statistics data
 $data = {
   cpuUsage => 10.2,
   stupidKey => 2.3,
   lama => 20,
 }
 
 # PCRE file
 /^s(.+)key/i		DELETE
 /^(c.+)/			someNiftyPrefix.${1}HAHAHA
 
 # result:
 $data = {
 	someNiftyPrefix.cpuUsageHAHAHA => 10.2,
 	lama => 20,
 }

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # pcre rules for statistic keys...
  $self->{regexFile} = undef;

  # pcre map object...
  $self->{_pcre} = undef;

  return 1;
}

sub init {
  my ($self) = @_;

  # create map
  my $map = ACME::Util::Map::PCRE->new();

  # parse regex files...
  unless ($map->parseFile($self->{regexFile})) {
    $self->{_error} = $map->getError();
    return 0;
  }

  # save map...
  $self->{_pcre} = $map;

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterContent {
  my ($self, $data) = @_;

  # iterate trough keys...
  map {

    # manipulate key
    my $k = $self->{_pcre}->lookup($_);

    # undef? key mapping wasn't found in map
    if (!defined $k) {

    }

    # should we remove this goddamn key from stats?
    elsif (uc($k) eq 'DELETE' || uc($k) eq 'REMOVE') {
      delete($data->{$_});
    }

    # replace it with new version :)
    else {
      my $v = $data->{$_};

      # remove old key
      delete($data->{$_});

      # install new one :)
      $data->{$k} = $v;
    }

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
