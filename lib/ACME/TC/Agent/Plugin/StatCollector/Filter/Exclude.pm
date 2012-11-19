package ACME::TC::Agent::Plugin::StatCollector::Filter::Exclude;


use strict;
use warnings;

use Log::Log4perl;

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

our $VERSION = 0.01;

my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::Exclude

Strip off unwanted keys from statistics data by specifying keys you B<WANT TO REMOVE>
from set of keys.

This is B<content-only> filter.

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and the following ones:

=over

=item B<exclude> (string, filename or arrayref, ""):

Filename containing one regex per line, comma or semicolon separated string or arrayref
containing regular expressions of unwanted keys.
After filtering data structure will contain B<ONLY> keys that B<DON'T MATCH ANY> specified regex.

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

  $self->{exclude} = "";
  $self->{nocase}  = 1;

  # private stuff
  # array of match regexes...
  $self->{_regex} = [];

  return 1;
}

sub init {
  my ($self) = @_;

  my @regexes = $self->_getRegexSources();
  $_log->debug("Regex sources: ", join(", ", @regexes));

  # try to precompile regexes...
  foreach my $re_multi_str (@regexes) {
    my @re_list = ();

    # is this maybe file?
    if (-f $re_multi_str) {
      my $x = $self->_parseFile($re_multi_str);
      return 0 unless (defined $x);
      push(@re_list, @{$x});
    }
    else {

      # nope, that's not a file...
      @re_list = split(/\s*[;,]+\s*/, $re_multi_str);
    }

    # compile regexes
    foreach my $re_str (@re_list) {
      my $regex = undef;
      my $flags = ($self->{nocase}) ? "i" : "";
      $_log->debug("Trying to compile regex '$re_str' using flags '$flags'.");
      eval { $regex = qr/(?$flags:$re_str)/; };
      if ($@) {
        $self->{_error} = "Error pre-compiling regex '$re_str': $@";
        return 0;
      }

      # add regex to queue
      push(@{$self->{_regex}}, $regex);
    }
  }

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterContent {
  my ($self, $data) = @_;

  # iterate trough regexes...
  foreach my $key (keys %{$data}) {
    my $remove = 0;
    foreach (@{$self->{_regex}}) {
      if ($key =~ $_) {
        $remove = 1;
        last;
      }
    }

    # remove key if necessary...
    delete($data->{$key}) if ($remove);
  }

  return $data;
}

sub _parseFile {
  my ($self, $file) = @_;
  unless (defined $file) {
    $self->{_error} = "Undefined regex file.";
    return undef;
  }
  $_log->debug("Trying to parse regex file: '$file'");
  my $fd = IO::File->new($file, 'r');
  unless ($fd) {
    $self->{_error} = "Unable to open regex file '$file': $!";
    return undef;
  }

  # read file...
  my $res = [];
  while (defined(my $line = <$fd>)) {
    $line =~ s/^\s+//g;
    $line =~ s/\s+$//g;
    next if ($line =~ m/^#/);
    next unless (length($line) > 0);
    push(@{$res}, $line);
  }

  return $res;
}

sub _getRegexSources {
  my ($self) = @_;
  my @res = ();

  if (ref($self->{exclude}) eq 'ARRAY') {
    push(@res, @{$self->{exclude}});
  }
  else {
    push(@res, $self->{exclude});
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
