package ACME::Util::Map::PCRE;


# set debugging constant if DEBUG environment variable is set
BEGIN {
  use constant DEBUG => ((defined $ENV{DEBUG}) ? 1 : 0);
  require File::Basename if (DEBUG);
}

use strict;
use warnings;

use IO::File;
use IO::Scalar;
use vars qw ($VERSION);

######################################################
#                GLOBAL VARIABLES                    #
######################################################

$VERSION = 0.4;

######################################################
#               OBJECT CONSTRUCTOR                   #
######################################################

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  ##################################################
  #               PUBLIC VARS                      #
  ##################################################

  ##################################################
  #              PRIVATE VARS                      #
  ##################################################

  # compiled pcre table
  $self->{_table}     = undef;
  $self->{_table_str} = "";

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);

  return $self;
}

####################################################
#               PUBLIC METHODS                     #
####################################################

sub error {
  my ($self) = @_;
  return $self->getError();
}

sub getError {
  my ($self) = @_;
  return $self->{error};
}

sub setParams {
  my ($self) = shift;

  while (defined(my $name = shift) && defined(my $value = shift)) {
    $self->{$name} = $value if (substr($name, 0, 1) ne '_');
  }

  return 1;
}

sub clearParams {
  my ($self) = @_;
  $self->{_table}     = undef;
  $self->{_table_str} = "";
  return 1;
}

sub dumpStructure {
  my ($self) = @_;
  return $self->{_table_str};
}

sub parseFile {
  my ($self, $file) = @_;

  if (!defined $file) {
    $self->{error} = "PCRE file is not defined.";
    print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__, ": Error: ",
      $self->{error}, "\n"
      if (DEBUG);
    return 0;
  }

  print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFile(), line ", __LINE__,
    ": parsing file '$file'\n"
    if (DEBUG);

  my $fd = undef;

  if (!defined($fd = IO::File->new($file, 'r'))) {
    $self->{error} = "Unable to parse file '" . $file . "': " . $!;
    print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFile(), line ", __LINE__,
      ": Unable to parse file '$file': $!\n"
      if (DEBUG);
    return 0;
  }
  else {
    my $result = $self->parseFh($fd);
    print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFile(), line ", __LINE__,
      ": Closing file.\n"
      if (DEBUG);
    $fd = undef;
    return $result;
  }
}

sub parseString {
  my ($self, $str_ref) = @_;

  if (!defined $str_ref) {
    $self->{error} = "String reference is not defined.";
    print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseString(), line ", __LINE__,
      ": Error: ", $self->{error}, "\n"
      if (DEBUG);
    return 0;
  }
  elsif (ref($str_ref) ne 'SCALAR') {
    print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseString(), line ", __LINE__,
      ": Error: ", $self->{error}, "\n"
      if (DEBUG);
    $self->{error} = "String reference provided is not reference to SCALAR.";
    return 0;
  }

  # create new filehandle and parse it
  print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseString(), line ", __LINE__,
    ": Creating filehandle from string reference.\n"
    if (DEBUG);
  my $fh = IO::Scalar->new($str_ref);

  unless (defined $fh) {
    $self->{error} = "Unable to construct filehandle from scalar reference: $!";
    print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseString(), line ", __LINE__,
      ": Error: ", $self->{error}, "\n"
      if (DEBUG);
    return 0;
  }
  print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseString(), line ", __LINE__,
    ": Parsing filehandle.\n"
    if (DEBUG);

  my $result = $self->parseFh($fh);
  $fh = undef;
  return $result;
}

sub parseFh {
  my ($self, $fd) = @_;

  # Perl source code
  my $str = "sub {\n";

  if (!defined $fd) {
    $self->{error} = "Filehandle not given as argument.";
    return 0;
  }

  # number of lines read from file
  my $lines = 0;

  # recursion depth
  my $recursion_depth = 0;

  # read line by line && parse
  print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__,
    ": reading filedescriptor.\n"
    if (DEBUG);
  while (my $line = $fd->getline) {
    $lines++;

    # remove whitespaces at the end
    $line =~ s/\s+$//;
    $line =~ s/^\s+//;

    # don't bother about blank lines and comments:)
    next if (!length $line || $line =~ m/^#/);

    # this loop parses postfix pcre_table(5) compatible files
    # See: pcre_table(5)
    # See: http://www.postfix.org/pcre_table.5.html

    # invalid pattern?
    if ($line ne 'endif'
      && ($line !~ m/^(\/|!\/|if \/|if !\/)/ || $line !~ m/.+\/(([imosx]{0,5})?(\s+)?(.+)?)?$/))
    {
      $self->{error} = "Invalid expression in line $lines: $line";
      return 0;
    }

    # should line match pattern?
    my $should_match = 1;

    # is this REGEX if statement
    my $is_if = 0;

    my $tabs = "";
    for (1 .. $recursion_depth) {
      $tabs .= "\t";
    }

    # /pattern/flags result
    if ($line =~ m/^\//) {
      $should_match = 1;
    }

    # !/pattern/flags result
    elsif ($line =~ m/^\!\//) {
      $line = substr($line, 1, (length($line) - 1));
      $should_match = 0;
    }

    # if /pattern/flags
    elsif ($line =~ m/^if \//) {
      $line         = substr($line, 3, (length($line) - 3));
      $should_match = 1;
      $is_if        = 1;
      $recursion_depth++;
      print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__,
        ": regex file line: $lines: catched if statement, start of IF block (recursion depth: $recursion_depth)\n"
        if (DEBUG);
    }

    # if !/pattern/flags
    elsif ($line =~ m/^if !\//) {
      $line         = substr($line, 4, (length($line) - 3));
      $should_match = 0;
      $is_if        = 1;
      $recursion_depth++;
      print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__,
        ": regex file line: $lines: catched if statement, start of IF NOT block (recursion depth: $recursion_depth)\n"
        if (DEBUG);
    }

    # endif
    elsif ($line =~ m/^endif$/) {
      print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__,
        ": regex file line: $lines: catched endif statement, end of IF/IF NOT block (recursion depth: $recursion_depth)\n"
        if (DEBUG);

      # sanity check
      if ($recursion_depth < 1) {
        $self->{error}
          = "Invalid regular expression file: Found endif label in line $lines without if label in read lines before.";
        return 0;
      }
      $recursion_depth--;
      $str .= $tabs . "}\n";
      next;
    }

    my ($reg_text, $reg_result, $flags);

    # extract regular expression pattern, regex result and regex flags from current line

    # PATTERN: /something/flags
    if ($line =~ m/\/(.+)\/([imosx]{1,5})\s*$/) {
      $reg_text   = $1;
      $flags      = (defined $2) ? $2 : '';
      $reg_result = "";
    }

    # PATTERN: /something/flags result
    elsif ($line =~ m/\/(.+)\/([imosx]{0,5})\s+(.+)?$/ || $line =~ m/\/(.+)\/([imosx]{0,5})\s*$/) {
      $reg_text   = $1;
      $reg_result = (defined $3) ? $3 : '';
      $flags      = (defined $2) ? $2 : '';
    }
    else {
      $self->{error} = "Invalid expression in line $lines: $line";
      return 0;
    }

# DEBUG
# print "\n\nREGEX: '$reg_text'\nRESULT: '$reg_result'\nFLAGS: '$flags'\n\n";
# print STDERR "DEBUG: ",  File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__, ": read '$line'\n" if (DEBUG);

    # try to compile regex
    my $regex = undef;
    eval { $regex = qr/(?$flags:$reg_text)/; };

    if ($@) {
      $self->{error} = "Invalid regular expression in line " . $lines . ": " . $@;
      print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__, ": ",
        $self->{error}, "\n"
        if (DEBUG);
      return 0;
    }

    # remove leading spaces in result
    $reg_result =~ s/^\s+//g;

    # write some perl code :)
    $str .= $tabs . "\t" . 'if ($_[0] ';
    $str .= ($should_match) ? '=~' : '!~';
    $str .= " m/$reg_text/$flags) {\n";
    unless ($is_if) {

      # normalize $reg_result
      # escape backslashes
      $reg_result =~ s/\\/\\\\/g;

      # escape @
      $reg_result =~ s/@/\\@/g;

      # escape %
      $reg_result =~ s/%/\\%/g;

      # escape " chars
      $reg_result =~ s/"/\\"/g;

      $str .= $tabs . "\t\treturn \"$reg_result\";\n";
      $str .= $tabs . "\t}\n";
    }

    print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__,
      ": regex file line: $lines: regex: '$reg_text'; flags: '$flags'; result: '$reg_result'; should match: $should_match; is if condition: $is_if; recursion depth: $recursion_depth\n"
      if (DEBUG);
  }

  # end of while loop
  print STDERR "DEBUG: ", File::Basename::basename(__FILE__), ", parseFh(), line ", __LINE__, ": EOF.\n"
    if (DEBUG);

  # hm, check recursion depth
  if ($recursion_depth != 0) {
    $self->{error} = "Invalid regular expression file: ";
    if ($recursion_depth > 0) {
      $self->{error} .= "There are " . $recursion_depth . " endif label(s) missing.";
    }
    else {
      $self->{error} .= "There are " . abs($recursion_depth) . " too many endif label(s).";
    }

    return 0;
  }

  # DEBUG
  # print Dumper($self->{$table_name});
  $str .= "\treturn undef;\n}\n";

  # print "PRODUCED STR:\n\n$str\n";
  # print "trying to evaluate code\n";
  # print "CODE:\n\n$str\n\n";
  my $code = eval $str;
  if ($@) {
    $self->{error} = "Unable to evaluate final code: $@";
    return 0;
  }

  # print "Code evaluated successfully, ref: ", ref($code), " $code\n";

  if (ref($code) eq 'CODE') {
    $self->{_table}     = $code;
    $self->{_table_str} = $str;
    return 1;
  }

  $self->{error} = "Filehandle parsed ok, but there was a problem generating perl code.";
  return 0;
}

# performs actual lookup against ALL pcre expressions
# and if any matches returns rewrited result :)
sub lookup {
  my $self = shift;

  # sanity check
  unless (defined $self->{_table}) {
    $self->{error} = "PCRE file/string/structure was not yet initialized.";
    return undef;
  }

  # perform lookup
  return &{$self->{_table}}($_[0]);
}

####################################################
#               PRIVATE METHODS                    #
####################################################

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
