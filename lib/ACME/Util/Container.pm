package ACME::Util::Container;


use strict;
use warnings;

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  $self->{error} = "";
  $self->{_pos}  = -1;
  @{$self->{_objs}} = ();

  bless($self, $class);
  return $self;
}

sub getError {
  my ($self) = @_;
  return $self->{error};
}

sub count {
  my ($self) = @_;
  return ($#{$self->{_objs}} + 1);
}

sub getFirst {
  my ($self) = @_;
  return undef unless ($self->moveFirst());
  return $self->get();
}

sub getPrev {
  my ($self) = @_;
  return undef unless ($self->movePrev());
  return $self->get();
}

sub get {
  my ($self, $pos) = @_;
  $pos = $self->{_pos} unless (defined $pos);

  unless (defined ${$self->{_objs}}[$pos]) {
    $self->{error} = "Unable to fetch dependency: invalid position";
    return undef;
  }

  return ${$self->{_objs}}[$pos];
}

sub getAll {
  my ($self) = @_;
  return @{$self->{_objs}};
}

sub getNext {
  my ($self) = @_;
  return undef unless ($self->moveNext());
  return $self->get();
}

sub getLast {
  my ($self) = @_;
  return undef unless ($self->moveLast());
  return $self->get();
}

sub moveFirst {
  my ($self) = @_;
  if (defined ${$self->{_objs}}[0]) {
    $self->{_pos} = 0;
    return 1;
  }
  $self->{error} = "There is no first position. Empty dependency container?";
  return 0;
}

sub moveLast {
  my ($self) = @_;
  if (defined ${$self->{_objs}}[$#{$self->{_objs}}]) {
    $self->{_pos} = $#{$self->{_objs}};
    return 1;
  }
  $self->{error} = "There is no last position. Empty dependency container?";
  return 0;
}

sub moveNext {
  my ($self) = @_;
  if (defined ${$self->{_objs}}[$self->{_pos} + 1]) {
    $self->{_pos}++;
    return 1;
  }
  $self->{error} = "There is no next position.";
  return 0;
}

sub movePrev {
  my ($self) = @_;
  if (defined ${$self->{_objs}}[$self->{_pos} - 1]) {
    $self->{_pos}--;
    return 1;
  }
  $self->{error} = "There is no previous position.";
  return 0;
}

sub movePos {
  my ($self, $pos) = @_;
  if (defined ${$self->{_objs}}[$pos]) {
    $self->{_pos} = $pos;
    return 1;
  }
  $self->{error} = "There is no such position.";
  return 0;
}

sub getPos {
  my ($self) = @_;
  return $self->{_pos};
}

sub resetPos {
  my ($self) = @_;
  $self->{_pos} = -1;
  return 1;
}

sub isEmpty {
  my ($self) = @_;
  return ($self->numDependencies() == 0);
}

sub emptyContainer {
  my ($self) = @_;
  @{$self->{_objs}} = ();
  $self->{_pos} = -1;
  return 1;
}

sub clear {
  my ($self) = @_;
  return $self->emptyContainer();
}

sub add {
  my $self = shift;
  foreach my $obj (@_) {
    ${$self->{_objs}}[$#{$self->{_objs}} + 1] = $obj;
  }
  return 1;
}

sub shift {
  my ($self) = @_;
  if ($self->{_pos} < 0) {
    $self->{error} = "There are no objects in container.";
    return undef;
  }
  return shift(@{$self->{_objs}});
}

sub unshift {
  my ($self, $obj) = @_;
  unshift(@{$self->{_objs}}, $obj);
  return 1;
}

sub push {
  my ($self, $obj) = @_;
  return $self->add($obj);
}

sub pop {
  my ($self) = @_;
  if ($self->{_pos} < 0) {
    $self->{error} = "There are no objects in container.";
    return undef;
  }
  elsif ($self->{_pos} == $#{$self->{_objs}}) {
    $self->{_pos}--;
  }

  return pop(@{$self->{_objs}});
}

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
