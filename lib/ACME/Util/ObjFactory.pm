package ACME::Util::ObjFactory;

use strict;
use warnings;

use Scalar::Util qw(blessed);

my $Error    = '';
my $_drivers = {};

=head1 SYNOPSIS

 package MyPackage;

 use strict;
 use warnings;
 use base 'ACME::Util::ObjFactory';

 sub new {
   my $proto = shift;
   my $class = ref($proto) || $proto;
   my $self = {};
   bless($self, $class);
   return $self;
 }
 sub something {
   return "something";
 }
 
 package MyPackage::Cool;

 use strict;
 use warnings;
 use base 'MyPackage';
 
 sub something {
   my $self = shift;
   return $self->SUPER::something() . " else";
 }

 package main;

 use strict;
 use warnings;

 my %opt = (a => 1, b = 2);
 
 # try to initialize Mypackage::Cool object
 # and call it's constructor with %opt
 my $obj = MyPackage->factory('Cool', %opt);
 unless (defined $obj) {
   print MyPackage->factoryError(), "\n";
   exit 1;
 }
 print $obj->something(), "\n";
 
 print "IO:: subclasses: ", join(", ", $obj->getDirectSubClasses("IO")), "\n";
 print "IO:: subclasses: ", join(", ", MyPackage->getDirectSubClasses("IO")), "\n";

=head1 METHODS

=head2 factory ($driver, [constructor_params])

Initializes new object using caller's subclass driver $driver with optional constructor
arguments. This method tries to load specified driver's subclass if it's not already
loaded.

Returns initialized object on success, otherwise undef.

=cut

sub factory {
  my $self = shift;
  my $pkg = blessed($self) ? ref($self) : $self;
  $Error = '';

  # fetch parameters...
  my $driver = shift;

  my $err = undef;
  my $obj = undef;

  unless (defined $driver && length($driver) > 0) {
    $err = "Undefined driver.";
    goto outta_factory;
  }

  # compute plugin class name
  my $class = $pkg . '::' . $driver;

  # check if class is already loaded
  my $x = eval { $class->isa('UNIVERSAL'); };
  unless ($x) {

    #print "Loading class $class\n";
    # nope, it's not; try to load it...
    eval "require $class";
    if ($@) {
      $err = "Error loading class '$class': $@";
      goto outta_factory;
    }
    $class->import();
  }

  # try to initialize object...
  eval { $obj = $class->new(@_); };

  # check for injuries...
  if ($@) {
    $err = "Error initializing class '$class': $@";
  }
  elsif (!defined $obj || !blessed($obj)) {
    $err = "Class $class constructor returned undefined or unblessed value.";
    $obj = undef;
  }

outta_factory:

  # problem?
  if (defined $err) {
    $err =~ s/\s+$//g;
    $Error = $err;
  }

  return $obj;
}

=head2 factoryNoCase ($driver, [constructor_params])

Does everything as factory(), but $driver is not case sensitive.

=cut

sub factoryNoCase {
  my $self   = shift;
  my $driver = shift;

  unless (defined $driver && length($driver) > 0) {
    $Error = "Undefined driver.";
    return undef;
  }

  foreach my $drv ($self->getDirectSubClasses()) {
    if (lc($drv) eq lc($driver)) {
      $driver = $drv;
      last;
    }
  }

  return $self->factory($driver, @_);
}

=head2 factoryError ()

Returns last error accoured.

=cut

sub factoryError {
  return $Error;
}

=head2 getDirectSubclasses ([$package])

This method searches perl's include path for direct
subclasses of specified $package class. Caller package
is used if $package is omitted.

Returns list of found subpackages.

=cut

sub getDirectSubClasses {
  my ($self, $package) = @_;
  unless (defined $package) {
    $package = (blessed($self)) ? ref($self) : $self;
  }

  $package =~ s/::/\//g;

  # anything in cache?
  if (exists($_drivers->{$package})) {
    return @{$_drivers->{$package}};
  }

  my (@drivers, %seen_dir);
  local (*DIR, $@);

  foreach my $d (@INC) {
    chomp($d);
    my $dir = $d . "/" . $package;

    next unless (-d $dir);
    next if ($seen_dir{$d});

    $seen_dir{$d} = 1;

    next unless (opendir(DIR, $dir));
    foreach my $f (readdir(DIR)) {
      next unless ($f =~ s/\.pm$//);
      next if ($f eq 'NullP');
      next if ($f eq 'EXAMPLE');
      next if ($f =~ m/^_/);

      # this driver seems ok, push it into list of drivers
      push(@drivers, $f) unless ($seen_dir{$f});
      $seen_dir{$f} = $d;
    }
    closedir(DIR);
  }

  @drivers = sort(@drivers);

  # put in cache...
  $_drivers->{$package} = [@drivers];

  return @drivers;
}

=head2 getDefaultsAsStr ([$header = 1])

Returns string representation of object configuration.

=cut

sub getDefaultsAsStr {
  my ($self, $header) = @_;
  $header = 1 unless (defined $header);

  my $u = ACME::Util->new();

  my $str = '';
  if ($header) {
    $str .= "#\n";
    $str .= "# configuration fragment\n";
    $str .= "#\n";
    $str .= "\n";

    $str .= <<EOF
# \$Id\$
# \$Date\$
# \$Author\$
# \$Revision\$
# \$LastChangedRevision\$
# \$LastChangedBy\$
# \$LastChangedDate\$
# \$URL\$

EOF
      ;
  }
  $str .= "{\n";
  if ($header) {
    $str .= "\t'enabled' => '1',\n";
    $str .= "\t'driver' => '" . $self->getDriver() . "',\n";
  }
  $str .= "\n";
  foreach my $key (sort keys %{$self}) {
    next unless (defined $key);
    next if ($key =~ m/^_/);
    next if ($key eq 'no_init');
    $str .= "\t'$key' => ";
    my $val = $self->{$key};
    my $ref = ref($val);
    if ($ref eq 'ARRAY' || $ref eq 'HASH') {
      $str .= $u->dumpVar($val);
    }
    else {
      $str .= (defined $val) ? "'" . $val . "'" : 'undef';
    }
    $str .= ",\n";
  }
  $str .= "}\n";

  if ($header) {
    $str .= "\n";
    $str .= "# EOF\n";
  }

  return $str;
}

=head1 AUTHOR

Brane F. Gracnar

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
