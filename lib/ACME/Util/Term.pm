package ACME::Util::Term;


use strict;
use warnings;

my %COLOURS = (
  WHITE   => "\033[1;37m",
  YELLOW  => "\033[1;33m",
  LPURPLE => "\033[1;35m",
  LRED    => "\033[1;31m",
  LCYAN   => "\033[1;36m",
  LGREEN  => "\033[1;32m",
  LBLUE   => "\033[1;34m",
  DGRAY   => "\033[1;30m",
  GRAY    => "\033[0;37m",
  BROWN   => "\033[0;33m",
  PURPLE  => "\033[0;35m",
  RED     => "\033[0;31m",
  CYAN    => "\033[0;36m",
  GREEN   => "\033[0;32m",
  BLUE    => "\033[0;34m",
  BLACK   => "\033[0;30m",
  BOLD    => "\033[40m\033[1;37m",
  RESET   => "\033[0m",
);

=head1 NAME
ACME::Util::Term - print colorized output to console (or not)

=head1 SYNOPSIS

 use strict;
 use warnings;
 
 use ACME::Util::Term;
 
 my $t = ACME::Util::Term->new();
 print $t->bold("This is bold."), "\n";
 print $t->yellow("This is yellow."), "\n";
 
 print "We are ", (($t->isConsole()) ? "" : "NOT"), " connected to tty terminal.\n";
 print "This is another way to be ", $t->color("yellow"), "yellow", $t->reset(), "\n";

=cut

=head1 OBJECT CONSTRUCTOR

Object constructor accepts single, optional argument: filehandle (default: B<*STDOUT>)
on which output will be written. This filehandle will be tested if it is a tty or not.

If specified filehandle is a tty, all methods will return colorized output, otherwise
all output will be unchanged.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  # are we going to output colours?
  $self->{_tty} = 0;

  bless($self, $class);

  if (defined $_[1]) {
    $self->{_tty} = 1;
  }
  else {
    my $fd = ($_[0]) ? $_[0] : *STDOUT;
    $self->{_tty} = $self->tty($fd);
  }

  return $self;
}

=head1 METHODS

=over

=cut

=item colour ($name)

Returns shell code for colour named $name if colour $name is found and output
is connected to terminal (tty), otherwise returns empty string.

=cut

sub colour {
  my ($self, $name) = @_;
  $name = uc($name);
  if (exists($COLOURS{$name}) && $self->isConsole()) {
    return $COLOURS{$name};
  }

  return "";
}

=item color ($name)

Synonym for L<colour()>.

=cut

sub color {
  my $self = shift;
  return $self->colour(@_);
}

=item isConsole ([$fd = <default_fd>])

Returns 1 if specified filehandle $fd is a tty terminal, otherwise 0. If filehandle
is omitted, internal output filehandle specified by object constructor is tested.
If internal filehandle is not defined, *STDOUT is tested.

=cut

sub isConsole {
  my $self = shift;
  return $self->tty(@_);
}

=item tty

Synonym for L<isConsole()>.

=cut

sub tty {
  my ($self, $fd) = @_;
  return $self->{_tty} unless (defined $fd);
  return (-t $fd) ? 1 : 0;
}

=item white ($str, ...)

Returns $str that will be printed to output as a white text if output is connected
to tty console, otherwise returns unmodified $str.

=cut

sub white {
  my $self = shift;
  return $self->colour("white") unless (@_);
  return $self->colour("white") . join("", @_) . $self->reset();
}

=item yellow ($str)

=cut

sub yellow {
  my $self = shift;
  return $self->colour("yellow") unless (@_);
  return $self->colour("yellow") . join("", @_) . $self->reset();
}

=item lpurple ($str)

=cut

sub lpurple {
  my $self = shift;
  return $self->colour("purple") unless (@_);
  return $self->colour("lpurple") . join("", @_) . $self->reset();
}

=item lgreen ($str)

=cut

sub lgreen {
  my $self = shift;
  return $self->colour("lgreen") unless (@_);
  return $self->colour("lgreen") . join("", @_) . $self->reset();
}

=item lcyan ($str)

=cut

sub lcyan {
  my $self = shift;
  return $self->colour("lcyan") unless (@_);
  return $self->colour("lcyan") . join("", @_) . $self->reset();
}

=item lblue ($str)

=cut

sub lblue {
  my $self = shift;
  return $self->colour("lblue") unless (@_);
  return $self->colour("lblue") . join("", @_) . $self->reset();
}

=item dgray ($str)

=cut

sub dgray {
  my $self = shift;
  return $self->colour("dgray") unless (@_);
  return $self->colour("dgray") . join("", @_) . $self->reset();
}

=item gray ($str)

=cut

sub gray {
  my $self = shift;
  return $self->colour("gray") unless (@_);
  return $self->colour("white") . join("", @_) . $self->reset();
}

=item brown ($str)

=cut

sub brown {
  my $self = shift;
  return $self->colour("brown") unless (@_);
  return $self->colour("brown") . join("", @_) . $self->reset();
}

=item purple ($str)

=cut

sub purple {
  my $self = shift;
  return $self->colour("purple") unless (@_);
  return $self->colour("purple") . join("", @_) . $self->reset();
}

=item lred ($str)

=cut

sub lred {
  my $self = shift;
  return $self->colour("lred") unless (@_);
  return $self->colour("lred") . join("", @_) . $self->reset();
}

=item red ($str)

=cut

sub red {
  my $self = shift;
  return $self->colour("red") unless (@_);
  return $self->colour("red") . join("", @_) . $self->reset();
}

=item cyan ($str)

=cut

sub cyan {
  my $self = shift;
  return $self->colour("cyan") unless (@_);
  return $self->colour("cyan") . join("", @_) . $self->reset();
}

=item green ($str)

=cut

sub green {
  my $self = shift;
  return $self->colour("green") unless (@_);
  return $self->colour("green") . join("", @_) . $self->reset();
}

=item blue ($str)

=cut

sub blue {
  my $self = shift;
  return $self->colour("blue") unless (@_);
  return $self->colour("blue") . join("", @_) . $self->reset();
}

=item black ($str)

=cut

sub black {
  my $self = shift;
  return $self->colour("black") unless (@_);
  return $self->colour("black") . join("", @_) . $self->reset();
}

=item bold ($str)

=cut

sub bold {
  my $self = shift;
  return $self->colour("bold") unless (@_);
  return $self->colour("bold") . join("", @_) . $self->reset();
}

=item reset ()

Returns shell colorized output reset sequence if output is a tty,
otherwise returns empty string.

=cut

sub reset {
  my $self = shift;
  return ($self->{_tty}) ? $COLOURS{RESET} : "";
}

=back

=head1 AUTHOR

Brane F. Gracnar

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
