package ACME::TC::Agent::Plugin::StatCollector::Filter::CODE;


use strict;
use warnings;

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

our $VERSION = 0.01;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::CODE

Filter parsed statistics data using custom written perl scripts.

This filter implementation can filter content and parsed object metadata.

=head1 SYNOPSIS

Filter initialization

 my %opt = (
 	codeFileContent => "filterCodeContent.pl",
 	codeFileObject => "filterCodeObject.pl",
 	funcNameContent => "Filter::Content::Dummy::filter_content",
 	funcNameObject => "Filter::Object::Dummy::filter_object",
 );
 
 my $filter = ACME::TC::Agent::Plugin::StatCollector::Filter->factory(
 	"CODE",
 	%opt
 );

File B<filterCodeContent.pl>:

 #!/usr/bin/perl
 package Filter::Content::Dummy;
 
 use strict
 use warnings;
 
 # this function must return filtered hash reference on success,
 # otherwise undef.
 #
 # argument: hash reference containing parsed statistics
 # data keys.
 sub filter_content {
 	my ($data) = @_;
 	
 	# insert some random data key
 	$data->{randomKey} = rand();
 	
 	# if there is no key named 'someKey', fail
 	# the parsing
 	unless (exists($data->{someKey}) && defined $data->{someKey}) {
 		return undef;
 	}
 
 	return $data
 }
 1;

File B<filterCodeObject.pl>:

 #!/usr/bin/perl
 package Filter::Object::Dummy;
 
 use strict;
 use warnings;
 
 # this function must return 1 on success, otherwise 0.
 #
 # argument: initialized ParsedData object.
 sub filter_object {
 	my ($obj) = @_;
 	
 	# set hostname
 	$obj->setHost("some-host.example.org");
 	
 	# fail filtering
 	# return 0;
 	
 	# filtering was successful...
 	return 1;
 }
 1;

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and the following ones:

=over

=item B<codeFileContent> (string, undef):

Path to perl script file containing function for content filtering.
File can contain also code for filtering object.

=item B<funcNameContent> (string, undef):

Content filtering function name. This is required parameter.

=item B<codeFileObject> (string, undef):

Path to perl script file containing function for object filtering.
File can also contain code for content filtering.

=item B<funcNameObject> (string, undef):

Object filtering function name.

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{codeFileContent} = undef;
  $self->{funcNameContent} = undef;
  $self->{codeFileObject}  = undef;
  $self->{funcNameObject}  = undef;

  # private vars
  $self->{_funcContent} = undef;
  $self->{_funcObj}     = undef;

  return 1;
}

sub init {
  my ($self) = @_;

  # try to load code files
  unless ($self->_codeLoad($self->{codeFileContent})) {
    $_log->error($self->getError());
    return 0;
  }
  unless ($self->_codeLoad($self->{codeFileObject})) {
    $_log->error($self->getError());
    return 0;
  }

  # check function names
  if (defined $self->{funcNameContent}) {
    my $ref = \&{$self->{funcNameContent}};
    unless (defined $ref && ref($ref) eq 'CODE') {
      $self->{_error} = "Unable to resolve function '$self->{funcNameContent}'.";
      $_log->error($self->{_error});
      return 0;
    }

    # try to run this stuff...
    eval { $ref->({}); };
    if ($@) {
      $self->{_error} = "Error running function '$self->{funcNameContent}': $@";
      $_log->error($self->{_error});
      return 0;
    }

    # assign function pointer...
    $self->{_funcContent} = $ref;
  }
  if (defined $self->{funcNameObject}) {
    my $ref = \&{$self->{funcNameObject}};
    unless (defined $ref && ref($ref) eq 'CODE') {
      $self->{_error} = "Unable to resolve function '$self->{funcNameObject}'.";
      $_log->error($self->{_error});
      return 0;
    }

    # try to run this function
    eval {
      my $obj = ACME::TC::Agent::Plugin::StatCollector::ParsedData->new();
      $ref->($obj);
    };
    if ($@) {
      $self->{_error} = "Unable to resolve function '$self->{funcNameObject}': $@";
      $_log->error($self->{_error});
      return 0;
    }

    # assign function pointer...
    $self->{_funcObj} = $ref;
  }

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterContent {
  my ($self, $data) = @_;

  # don't bother if we don't have content
  # function...
  return $data unless (defined $self->{_funcContent});

  # run coderef; safely...
  my $res = undef;
  eval { $res = $self->{_funcContent}->($data); };

  if ($@) {
    $self->{_error} = "Error filtering content using function '$self->{funcNameContent}': $@";
  }
  elsif (!defined $res) {
    $self->{_error}
      = "Error filtering content using function '$self->{funcNameContent}': function returned undef value.";
  }

  return $res;
}

sub _filterObj {
  my ($self, $obj) = @_;

  # don't bother if we don't have object filtering
  # function...
  return 1 unless (defined $self->{_funcObj});

  # run coderef; safely...
  my $res = 0;
  eval { $res = $self->{_funcObj}->($obj); };

  if ($@) {
    $self->{_error} = "Error filtering object using function '$self->{funcNameObject}': $@";
  }
  elsif (!defined $res) {
    $self->{_error}
      = "Error filtering object using function '$self->{funcNameObject}': function returned errorneus value.";
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

L<ACME::TC::Agent::Plugin::StatCollector::Filter>
L<ACME::TC::Agent::Plugin::StatCollector::RawData>
L<ACME::TC::Agent::Plugin::StatCollector::ParsedData>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
