package ACME::StatQueue;


use strict;
use warnings;

use constant CAPACITY_DEFAULT => 100;

our $VERSION = 0.10;

=head1 NAME ACME::StatQueue

Simple statistics module.

=head1 SYNOPSIS

	my $capacity = 200;
	my $q = ACME::StatQueue->new($capacity);
	
	# set unlimited capacity
	$q->setCapacity(0);
	
	# add some data...
	$q->add(6);
	$q->add(8);
	$q->add(10);
	
	# let's do some stats
	print $q->getAvg();
	
=cut

=head1 OBJECT CONSTRUCTOR

Object constructor accepts only one optional argument: queue capacity
(default: 100).

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

  # data array
  $self->{_data} = [];

  # capacity
  $self->{_capacity} = CAPACITY_DEFAULT;

  # god bless this object...
  bless($self, $class);

  # reset object
  $self->reset();

  # capacity as constructor argument?
  my $cap = shift(@_);
  if (defined $cap) {
    $self->setCapacity($cap);
  }

  return $self;
}

=head1 METHODS

=item clone ()

Returns cloned copy (including stored data) of current object.

=cut

sub clone {
  my ($self) = @_;
  my $obj = __PACKAGE__->new($self->getCapacity());

  # copy data...
  @{$obj->{_data}} = @{$self->{_data}};

  return $obj;
}

=item getCapacity ()

Returns maximum number of stored values.

=cut

sub getCapacity {
  my ($self) = @_;
  return $self->{_capacity};
}

=item setCapacity ($new_capacity)

Sets maximum number of stored values. If $new_capacity == 0,
object will accept theoreticaly infinite number of stored values.

=cut

sub setCapacity {
  my ($self, $num) = @_;
  return 0 unless (defined $num && length($num));
  my $x = undef;
  {
    no warnings;
    $x = abs(int($num));
  }

  $self->{_capacity} = $x;
  return 1;
}

=item size ()

Returns number of currently stored values.

=cut

sub size {
  my ($self) = @_;
  return ($#{$self->{_data}} + 1);
}

=item clear ()

Removes all stored values from object.

=cut

sub clear {
  my ($self) = @_;
  $self->{_data} = [];
}

=item reset ()

Removes all stored values from object and sets default capacity.

=cut

sub reset {
  my ($self) = @_;
  $self->clear();
  $self->setCapacity(CAPACITY_DEFAULT);
}

=item add ($val, $val2, ...)

Adds provided numeric or float arguments to internal value buffer.
Records that were added first will be removed if object capacity is
reached or overflown.

=cut

sub add {
  my $self = shift;

  foreach my $num (@_) {
    $num = 0 unless (defined $num);

    # unlimited capacity
    if ($self->{_capacity} == 0) {
      push(@{$self->{_data}}, $num);
    }
    else {

      # limited capacity
      my $num_elems = $#{$self->{_data}} + 1;

      # is there enough space in "circular" buffer?
      if ($num_elems < $self->{_capacity}) {
        push(@{$self->{_data}}, $num);
      }
      else {

        # ... nope
        # remove first element...
        shift(@{$self->{_data}});

        # add this one...
        push(@{$self->{_data}}, $num);
      }
    }
  }

  return 1;
}

=item getAvg ()

Returns average value of stored values.

=cut

sub getAvg {
  my ($self) = @_;
  my $sum = 0;
  map { $sum += $_; } @{$self->{_data}};
  my $num = $#{$self->{_data}} + 1;
  return 0 if ($num < 1);
  return ($sum / $num);
}

=item getPercentile ($percentile)

Returns 1-99th percentile of stored values.

=cut

sub getPercentile {
  my ($self, $percentile) = @_;
  {
    no warnings;
    $percentile = abs(int($percentile));
  }
  return 0 unless ($percentile > 0 && $percentile < 100);

  my @ranzirna_vrsta = sort { $a <=> $b } @{$self->{_data}};

  my $p    = $percentile / 100;
  my $size = $#{ranzirna_vrsta} + 1;
  my $R    = ($p * $size) + 0.5;

  #my $str = "";
  #$str .= "RANG: ";
  #map {
  #	$str .= sprintf("%-2.2s ", $_);
  #} 1 .. $size;
  #$str .= "\n";
  #$str .= "VAL:  ";
  #map {
  #	$str .= sprintf("%-2.2s ", $_);
  #} @ranzirna_vrsta;
  #$str .= "\n";

  my $R0 = int($R);
  $R0-- if ($R0 == $R);
  $R0 = 1 if ($R0 < 0);

  my $R1 = int($R) + 1;
  $R1 = $R if ($R1 > $size);

  my $x0 = $ranzirna_vrsta[($R0 - 1)];
  $x0 = $ranzirna_vrsta[$R0] unless (defined $x0);
  $x0 = 0 unless (defined $x0);

  my $x1 = $ranzirna_vrsta[($R1 - 1)];
  $x1 = $ranzirna_vrsta[$R1] unless (defined $x1);
  $x1 = 0 unless (defined $x1);

  #print $str;
  #print "p = $p, size = $size; rang(R) = $R; R0 = $R0; R1 = $R1; x0 = $x0; x1 = $x1\n";

  # calculate the stuff...
  my $res = (($x1 - $x0) * ($R - $R0)) + $x0;
  return $res;
}

=item getMedian ()

Returns median value (50th percentile) of stored data.

=cut

sub getMedian {
  my ($self) = @_;
  return $self->getPercentile(50);
}

=item getMin ()

Returns smallest stored value.

=cut

sub getMin {
  my ($self) = @_;
  my $min = undef;
  map {
    if (!defined $min)
    {
      $min = $_;
    }
    elsif ($_ < $min) {
      $min = $_;
    }
  } @{$self->{_data}};

  return $min;
}

=item getMax ()

Returns biggest stored value.

=cut

sub getMax {
  my ($self) = @_;
  my $max = undef;
  map {
    if (!defined $max)
    {
      $max = $_;
    }
    elsif ($_ > $max) {
      $max = $_;
    }
  } @{$self->{_data}};

  return $max;
}

# Eliminates redundant values from sorted list of values input.
sub uniq {
  my $prev = undef;
  my @out;
  foreach my $val (@_) {
    next if $prev && ($prev eq $val);
    $prev = $val;
    push(@out, $val);
  }
  return @out;
}

=head1 AUTHOR

Brane F. Gracnar

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
