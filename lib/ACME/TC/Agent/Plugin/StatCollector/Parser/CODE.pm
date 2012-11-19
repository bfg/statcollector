package ACME::TC::Agent::Plugin::StatCollector::Parser::CODE;


use strict;
use warnings;

use Log::Log4perl;
use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

our $VERSION = 0.01;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::CODE

Filter raw statistics content using custom perl scripts.

Filter initialization

 my %opt = (
 	codeFile => "parser_sample.pl",
 	funcName => "Parser::Saimple::parse",
 );
 
 my $filter = ACME::TC::Agent::Plugin::StatCollector::Filter->factory(
 	"CODE",
 	%opt
 );

File B<parser_sample.pl>:

 #!/usr/bin/perl
 package Parser::Sample;
 
 use strict
 use warnings;
 
 # this function must return hash reference on success,
 # otherwise undef.
 #
 # argument: string reference to raw data
 sub parse {
 	my ($data) = @_;
 	return undef unless (defined $data && length($$data) > 0);
 	
 	# result hash
 	my $result = {};
 	
 	# actually do some parsing stuff
 	$result->{someKey} = md5_hex($$data);

    # return result
 	return $result;
 }
 1;

=head1 DESCRIPTION

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts the following named parameters:

=over

=item B<codeFile> (string, undef):

Perl script file containing parsing function. 

=item B<funcName> (string, undef):

Raw content filtering function name.

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{codeFile} = undef;
  $self->{funcName} = undef;

  # function reference
  $self->{_func} = undef;

  return 1;
}

sub init {
  my ($self) = @_;

  # try to load code files
  unless ($self->_codeLoad($self->{codeFile})) {
    $_log->error($self->getError());
    return 0;
  }

  # check function name
  if (defined $self->{funcName}) {
    my $ref = \&{$self->{funcName}};
    unless (defined $ref && ref($ref) eq 'CODE') {
      $_log->error("Unable to resolve parsing function '$self->{funcName}'.");
      return 0;
    }

    # try to run this stuff...
    eval { $ref->(\""); };
    if ($@) {
      $_log->error("Error running parsing function '$self->{funcName}': $@");
      return 0;
    }

    # assign function pointer...
    $self->{_func} = $ref;
  }
  else {
    $_log->error("Undefined parsing function.");
    return 0;
  }

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _parse {
  my ($self, $str) = @_;

  # run coderef; safely...
  my $res = undef;
  eval { $res = $self->{_func}->($str); };

  if ($@) {
    $self->{_error} = "Error parsing content using function '$self->{funcName}': $@";
  }
  elsif (!defined $res) {
    $self->{_error}
      = "Error parsing content using function '$self->{funcName}': function returned undef value.";
  }
  elsif (ref($res) ne 'HASH') {
    $self->{_error}
      = "Error parsing content using function '$self->{funcName}': function returned non hash reference ("
      . ref($res) . ").";
    return undef;
  }

  return $res;
}

sub _codeLoad {
  my ($self, $file) = @_;

  # don't try to load undefined files...
  return 1 unless (defined $file && length($file) > 0);

  # is file already loaded?
  return 1 if (exists($INC{$file}));

  unless (-f $file && -r $file) {
    $self->{_error} = "Invalid, nonexisting or unreadable code file: $file";
    return 0;
  }

  # try to load it...
  my $r = do $file;
  unless ($r) {
    if ($@) {
      $self->{_error} = "Cannot parse code file $file: $@";
    }
    elsif (!defined $r) {
      $self->{_error} = "Cannot load code file $file: $!";
    }
    elsif (!$r) {
      $self->{_error} = "Cannot evaluate code file $file: $!";
    }
    return 0;
  }

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Parser>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
