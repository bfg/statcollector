package ACME::TC::Agent::Plugin::StatCollector::Parser::TextSimple;


use strict;
use warnings;

use IO::Scalar;
use Log::Log4perl;

use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

use constant MAX_LINES => 1000;

our $VERSION = 0.03;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::TextSimple

Simple text parser.

=head1 DESCRIPTION

This parser parses simple key-value pairs from arbitary multi-line text.

B<SOURCE:>
 # this is
 # a comment
 vmstat_us=1.00
 vmstat_sys=0.50
 vmstat_wa=0.50

B<RESULT:>
 $VAR = {
 	vmstat_us => 1.00,
 	vmstat_sys => 0.50,
 	vmstat_wa => 0.50,
 }

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts the following named parameters:

=over

=item B<maxLines> (integer, 1000):

Maximum allowed number of lines to parse. 

=item B<skipComments> (boolean, 1):

Skip lines starting with "#" or ";" characters.

=item B<warnOnDuplicates> (boolean, 0):

Warn about duplicate keys in input.

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # my own stuff
  $self->{maxLines}         = MAX_LINES;
  $self->{skipComments}     = 1;
  $self->{warnOnDuplicates} = 0;

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _parse {
  my ($self, $str) = @_;
  unless (defined $str) {
    $self->{_error} = "Nothing to parse: got undefined string.";
    return undef;
  }

  # parsed data
  my $data = {};

  # enough, create file descriptor...
  my $fd = IO::Scalar->new($str, 'r');
  unless (defined $fd) {
    $self->{_error} = "Unable to create filehandle on string: $!";
    return 0;
  }

  # read and parse filedescriptor...
  my $i      = 0;
  my $parsed = 0;
  while ($i < $self->{maxLines} && (my $l = <$fd>)) {
    $i++;

    # 150 lines and nothing parsed?
    # we have wrong raw data...
    if ($parsed == 0 && $i >= 150) {
      $self->{_error} = "Nothing parsed after 150 lines of raw data.";
      return undef;
    }

    # cleanup stuff...
    $l =~ s/^\s+//g;
    $l =~ s/\s+$//g;

    # skip empty lines
    next unless (length($l) > 0);

    # skip comments?
    next if ($self->{skipComments} && $l =~ m/^[#;]+/);

    # try to parse...
    my ($key, $val) = split(/\s*[=:]+\s*/, $l, 2);

    # check split result
    unless (defined $key && defined $val) {
      $_log->debug("Line $i: Unable to get anything from line: '$l'");
      next;
    }

    # fix key: cannot contain whitespaces.
    $key =~ s/\s+/\./g;

    # check for duplicated stuff...
    if ($self->{warnOnDuplicates} && exists($data->{$key})) {
      $_log->warn("Line $i: Duplicate key: '$key' value '$val' (previous: '$data->{$key}')");

      # next;
    }

    # assign key
    $data->{$key} = $val;
    $parsed++;
  }

  unless ($parsed >= 1) {
    $self->{_error} = "No keys were parsed from raw data.";
    return undef;
  }
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
