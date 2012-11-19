package ACME::Util::StringPermute;


use strict;
use warnings;

use ACME::Util;

my $util = ACME::Util->new();
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

my @_re = (qr/\{([^\}]+)\}/, qr/\[([^\]]+)\]/, qr/\$<([^>]+)>/,);

=head1 NAME ACME::Util::StringPermute

Simple glob(3)({foo,bar,baz}[2-4] style) string permutation class with additional candies for free. 

=head1 SYNOPSIS

	# create object...
	my $p = ACME::Util::StringPermute->new();
	
	# globbed string string
	my $str = 'aaa[4-6]{1,2,3,}{x,y}{W,Z}.example.com';

	my $res = $p->permute($str);
	unless (defined $res) {
		die "Unable to permute: ", $p->getError();
	}
	
	print "Permuted:\n\t", join("\n\t", @{$res}), "\n";

=cut

=head1 OBJECT CONSTRUCTOR

Object constructor doesn't accept any parameters.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  ##################################################
  #              PUBLIC PROPERTIES                 #
  ##################################################

  ##################################################
  #              PRIVATE PROPERTIES                #
  ##################################################
  $self->{_error} = '';
  bless($self, $class);
  return $self;
}

=head1 METHODS

=head2 getError ()

Returns last error.

=cut

sub getError {
  my ($self) = @_;
  return $self->{_error};
}

=head2 permute ($str)

Permutes provided string using glob(3) expansion and by querying external backends.

Returns array reference containing permutations of $str on success otherwise undef.

=cut

sub permute {
  my ($self, $str) = @_;
  $self->{_error} = '';
  unless (defined $str) {
    $self->{_error} = "Undefined multiply string.";
    return undef;
  }

  # don't waste time on zero-length strings...
  return [] unless (length($str) > 0);

  my @res = ();
  push(@res, $str);

  my $done = 0;
  while (!$done) {
    my $n_expanded = 0;

    #print "while ! done\n";

    my $i     = 0;
    my $max_n = $#res;
    while (defined(my $e = shift(@res))) {
      $i++;

      #print "while defined my [i = $i] \$e = '$e'\n";
      # is this item done already?

      # does any globbing method match this one?
      my $re_matched = 0;
      my $regex      = undef;
      my $re_index   = 0;
      foreach my $re (@_re) {
        $re_index++;
        if ($e =~ $re) {
          $re_matched = 1;
          $regex      = $re;
          last;
        }
      }

      # remark: I DON'T KNOW WHY THIS
      # ACTUALLY WORKS... BUT WORKS :)
      unless ($re_matched) {
        $done = 1;
        unshift(@res, $e);
        last;
      }

      # get expansion stuff..
      if (defined $regex && $e =~ $regex) {
        my @expansions = ();

        # {a,b,c}
        if ($re_index == 1) {
          @expansions = split(/,/, $1);
        }

        # [a-z]
        elsif ($re_index == 2) {
          my $exp_str = $1;
          my $err     = "Invalid glob range '$exp_str'";

          #print "Evo nas: $exp_str\n";
          my ($start, $stop) = split(/\s*\-\s*/, $exp_str);
          unless (defined $start && defined $stop && length($start) > 0 && length($stop) > 0) {
            $self->{_error} = $err;
            return undef;
          }

          # $start and $stop must be both numbers or both characters
          if ($start =~ m/^\d+$/) {
            if ($stop !~ m/^\d+$/) {
              $self->{_error} = "$err: start range is number, range end is not.";
              return undef;
            }
          }
          elsif ($start =~ m/^[a-z]+$/) {
            if ($stop !~ m/^[a-z]+$/) {
              $self->{_error} = "$err: start range is character, range end is not.";
              return undef;
            }
          }
          else {
            $self->{_error} = "$err: both range start and range end must be characters or numbers.";
            return undef;
          }

          # expand range
          for ($start .. $stop) {
            push(@expansions, $_);
          }
        }

        # $<something>
        elsif ($re_index == 3) {
          my $r = $self->_permuteExt($1);
          return undef unless (defined $r);
          @expansions = @{$r};
        }

        # apply expansions...
        map {
          my $x = $e;
          $x =~ s/$regex/$_/;
          push(@res, $x);
        } @expansions;
      }

    }

    # no expanded stuff? we're done
    $done = 1 unless ($n_expanded);
  }

  return [sort @res];
}


sub _permuteExt {
  my ($self, $str) = @_;
  my @tmp = split(/\s*:\s*/, $str, 2);
  unless (@tmp) {
    no warnings;
    $self->{_error} = "Invalid permute string: '$str'";
    return undef;
  }

  # check backend and string...
  my ($backend, $eval_str) = @tmp;

  # no multiply backend provided, use default one...
  if (defined $backend && !defined $eval_str) {
    $eval_str = $backend;
    $backend  = 'File';
  }

  # check backend, eval str
  unless (defined $backend && length($backend) > 0) {
    $self->{_error} = "Undefined or zero-length permute backend name.";
    return undef;
  }
  unless (defined $eval_str && length($eval_str)) {
    $self->{_error} = "Undefined or zero-length permute string.";
    return undef;
  }

  # fix backend name...
  $backend = ucfirst(lc($backend));

  # check backend
  my $method = '_permuteExt' . $backend;
  unless ($self->can($method)) {
    $self->{_error} = "Unsupported permute backend: $backend";
    return undef;
  }

  # return result...
  return $self->$method($eval_str);
}

sub _permuteExtFile {
  my ($self, $file) = @_;

  # open file
  my $fd = IO::File->new($file, 'r');
  unless (defined $fd) {
    $self->{_error} = "Unable to open file '$file': $!";
    return undef;
  }

  my $res = [];

  # read it...
  while (<$fd>) {
    $_ =~ s/^\s+//g;
    $_ =~ s/\s+$//g;

    # skip comments and empty lines.
    next unless (length($_) > 0);
    next if ($_ =~ m/^#/);

    # add stuff...
    push(@{$res}, $_);
  }

  return $res;
}

sub _permuteExtExec {
  my ($self, $cmd) = @_;
  unless (defined $cmd) {
    $self->{_error} = "Undefined command.";
    return undef;
  }

  # run command
  my @tmp = qx/$cmd/;

  # check exit code
  unless ($util->evalExitCode($?)) {
    $self->{_error} = "Command '$cmd' returned invalid exit code: " . $util->getError();
    return undef;
  }

  # remove newlines...
  map { chomp($_); } @tmp;

  # return result...
  return [@tmp];
}

=head1 EXTERNAL BACKENDS

This class supports querying external string permutation backends. External backends can
be queried by using special B<$<BACKEND_NAME:STRING>> variable in string to be permuted.

=head1 IMPLEMENTED EXTERNAL BACKENDS

=head2 FILE

This backend reads file provided in argument and returns all non-zero length lines
that do not start with '#' character.

Example usage:

 my $str = 'aaa-[0-9]-$<FILE:/path/to/file.txt>';
 my $res = $p->permute($str);
 
=head2 EXEC

This backend spawns program specified in argument, reads it's stdout and
returns all non-zero length lines.

Example usage: 

 my $str = 'aaa-[0-9]-$<EXEC:/usr/bin/program>';
 my $res = $p->permute($str);

=head1 EXTENDING

Implementing new backends is easy. Implementation needs method named B<_permuteExtBackend>($str)
which takes $<(.+)> catched string and returns array reference on success, otherwise undef and
sets internal error message.

Example implementation:

 package MyPermuteBackend
 
 use strict;
 use warnings;
 
 use base 'ACME::Util::StringPermute';
 
 sub _permuteExtSomething {
 	my ($self, $num) = @_; 	
 	if (rand() > 0.5) {
 		$self->{_error} = "rand() function decided that this call will fail.";
 		return undef;
 	}
 	
 	my $res = [];
 	for (1 .. $num)) {
 		push(@{$res}, $num);
 	}
 	
 	return $res;
 }

Example implementation usage:

 use MyPermuteBackend;
 
 my $p = MyPermuteBackend->new();
 
 my $str = 'something-[0-9]-$<Something:15>-blabla';
 my $permuted = $p->permute($str);
 
=cut

=head1 SEE ALSO

L<String::Glob::Permute>

=head1 AUTHOR

Brane F. Gracnar

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
