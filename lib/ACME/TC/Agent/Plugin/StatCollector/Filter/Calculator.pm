package ACME::TC::Agent::Plugin::StatCollector::Filter::Calculator;


use strict;
use warnings;

use Log::Log4perl;

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

our $VERSION = 0.05;
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::Calculator

Calculate key values based on other key values. This is B<content-only> filter.

=head1 SYNOPSIS

Filter initialization

 my %opt = (
 	expressions => [
 		'someKey = ${someKey} * 2.1',
 		'someOtherKey = (${someKey} ** 2) / (4 * ${someKey})',
 	],
 );
 
 my $filter = ACME::TC::Agent::Plugin::StatCollector::Filter->factory(
 	"Calculator",
 	%opt
 );

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and the following ones:

=over

=item B<expressions> (array reference, []):

Array reference of expressions.

=item B<undefIsZero> (boolean, 1)

Treat missing dependent keys in keyset as keys with value of 0.

If this configuration property
is set to value of B<0> then B<ANY> expression that relies to non-existing key in keyset B<will NOT be evaluated and therefore
expression result key will NOT be inserted in keyset>, becouse dependent keys must have defined value. Setting this
configuration property to value of B<1> (default) treats missing dependent keys in keyset B<as they would have value of 0>.  

Example:
 my %opt = (
 	expressions => [
 		'someOtherKey = ${someKey} * 2)',
 	],
 );

Case: B<undefIsZero == 1>, key <someKey> exists and has value: Key B<someOtherKey> will be computed and will contain double value of B<someKey>.

Case: B<undefIsZero == 1>, key <someKey> doesn't exist: Key B<someOtherKey> will be computed, but undefined value of B<someKey> will be treated as 0, computation will therefore result in value of 0. 

Case: B<undefIsZero == 0>, key <someKey> exists and has value: Key B<someOtherKey> will be computed and will contain double value of B<someKey>.

Case: B<undefIsZero == 0>, key <someKey> doesn't exist: Key B<someOtherKey> B<WILL NOT BE COMPUTED>!!!

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # expression strings...
  $self->{expressions} = [];

  # don't eval keys that don't have dependant keys...
  $self->{undefIsZero} = 1;

  # expression function code references...
  $self->{_code} = [];

  return 1;
}

sub init {
  my ($self) = @_;

  my $i = 0;
  foreach my $str (@{$self->{expressions}}) {
    $i++;
    my $err = "Invalid expression number $i: ";

    $_log->debug("Trying to compile expression: $str");
    my ($key, $expr) = split(/\s*=\s*/, $str);
    unless (defined $key && $expr) {
      $self->{_error} = $err . $str;
      return 0;
    }

    # strip key and expression
    $key  =~ s/^\s+//g;
    $key  =~ s/\s+$//g;
    $expr =~ s/^\s+//g;
    $expr =~ s/\s+$//g;

    # we need something :)
    unless (length($key) > 0 && length($expr) > 0) {
      $self->{_error} = $err . $str;
      return 0;
    }

    # compute keys that this expression depends on.
    my @dependent_keys = ();
    my $x              = $expr;
    eval { $x =~ s/(?:\$|%){([^}]+)}/push(@dependent_keys, $1)/ge; };
    if ($@) {
      $self->{_error} = "Error computing key dependence for expression: $str";
      return 0;
    }

    $_log->debug("This expression results in key '$key' and is computed with expression '$expr'.");
    $_log->debug("Expression dependends on the following keys: ", join(", ", @dependent_keys));

    # try to get the code
    my $code = $self->_getCode($expr, @dependent_keys);
    unless (defined $code) {
      $self->{_error} = $err . $self->{_error};
      return 0;
    }

    # assign code ref
    push(@{$self->{_code}}, [$key, $code]);

    # $self->{_code}->{$key} = $code;
  }

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterContent {
  my ($self, $data) = @_;

  foreach (@{$self->{_code}}) {

    # fetch computation key and code reference
    my $key  = $_->[0];
    my $code = $_->[1];

    # get new value...
    my $val = $code->($self, $data);
    unless (defined $val) {
      $_log->warn("Error computing key $key: ", $self->{_error});
      next;
    }

    # assign new value
    $data->{$key} = $val;
  }

  return $data;
}

sub _getCode {
  my ($self, $expr, @dkeys) = @_;
  return undef unless (defined $expr);

  my $parsed_expr = $expr;

  $parsed_expr =~ s/(?:\$|%){([^}]+)}/_repl(\$self, \$data, "$1")/g;

  my $dkey_str = "qw(" . join(" ", @dkeys) . ")";

  my $code_str = <<EOC
sub {
	my (\$self, \$data) = \@_;
	
	my \@dkeys = $dkey_str;
	
	# do all dependant keys have value?
	unless ($self->{undefIsZero}) {
		foreach my \$key (\@dkeys) {
			my \$v = \$self->_getKeyValue(\$data, \$key);
			unless (defined \$v) {
				\$self->{_error} = "Will omit computing expression '\$expr'; dependent key \$key doesn't exist.";
				return undef;
			}
		}
	}

	# run expression code safely...
	my \$r = eval '$parsed_expr';
	
	if (\$@) {
		\$self->{_error} = "Error evaluating expression: \$@";
		return undef;
	}
	elsif (! defined \$r) {
		\$self->{_error} = "Error evaluating expression: expression returned undef value.";
		return undef;
	}
	
	return \$r;
}
EOC
    ;

  $_log->debug("Expression '$expr' compiled into '$parsed_expr'.");

  if ($_log->is_debug()) {
    $_log->debug("--- BEGIN PRODUCED CODE ---\n" . $code_str);
    $_log->debug("--- END PRODUCED CODE ---");
  }

  $_log->debug("Compiling code string into anonymous perl code reference.");
  my $code = eval $code_str;
  if ($@) {
    $self->{_error} = "Unable to compile perl code reference: $@";
    return undef;
  }

  return $code;
}

sub _repl {
  my ($self, $data, $key) = @_;

  # fetch value for key \$key
  my $v = $self->_getKeyValue($data, $key);

  # treat undefined value as 0
  $v = 0 unless (defined $v);
  return $v;
}

sub _getKeyValue {
  my ($self, $data, $key) = @_;
  return undef unless (defined $data && defined $key);
  return undef unless (ref($data) eq 'HASH');
  return undef unless (exists($data->{$key}) && defined $data->{$key});

  # return value
  return $data->{$key};
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Filter>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
