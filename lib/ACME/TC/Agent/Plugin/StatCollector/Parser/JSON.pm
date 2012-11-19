package ACME::TC::Agent::Plugin::StatCollector::Parser::JSON;


use strict;
use warnings;

use JSON;
use Log::Log4perl;
use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

our $VERSION = 0.10;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

# parser object
my $_parser = undef;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::JSON

Parses JSON response

Parser initialization

 my %opt = (
 );
 
 my $parsed = ACME::TC::Agent::Plugin::StatCollector::Parser->factory(
 	"JSON",
 );

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor doesn't accept any arguments.

=over

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _parse {
  my ($self, $str) = @_;

  # do we have parser?
  unless (defined $_parser) {
    $_parser = JSON->new();
    $_parser->utf8(1);
    $_parser->relaxed(1);
  }

  # try to parse
  local $@;
  my $data = eval { $_parser->decode($$str) };
  if ($@) {
    $self->{_error} = "Error parsing JSON: $@";
    return undef;
  }

  # flatten hash and return
  return $self->_flattenJson($data);
}

sub _flattenJson {
  my ($self, $data, $rec_level) = @_;
  $rec_level = 0 unless (defined $rec_level);
  return undef if ($rec_level >= 9);

  my $res = {};
  foreach my $key (keys %{$data}) {
    my $ref = ref($data->{$key});

    # print "REF [$key]: $ref\n";

    # normal keys...
    if (!defined $ref || $ref eq '') {
      $res->{$key} = $data->{$key};
    }

    # arrays
    elsif ($ref eq 'ARRAY') {
      $res->{$key} = join(', ', @{$data->{$key}});
    }

    # hashes...
    elsif ($ref eq 'HASH') {
      my $tmp = $self->_flattenJson($data->{$key}, ($rec_level + 1));
      next unless (defined $tmp);
      foreach my $k (keys %{$tmp}) {
        my $nk = $key . '.' . $k;
        $res->{$nk} = $tmp->{$k};
      }
    }

    # CODE?
    elsif ($ref =~ m/^JSON::/) {
      $res->{$key} = $data->{$key} ? 1 : 0;
    }
  }

  return $res;
}


=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Parser>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
