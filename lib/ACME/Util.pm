package ACME::Util;


# check for ipv6 support...
BEGIN {
  use constant HAVE_IPV6 =>
    eval { require Socket; Socket->import(); require Socket6; Socket6->import(); return 1; };
}

use strict;
use warnings;

use Cwd;
use FindBin;
use Exporter;
use IO::File;
use File::Spec;
use Data::Dumper;
use Sys::Hostname;
use File::Basename;
use Log::Log4perl qw(:nowarn :easy);
use Scalar::Util qw(blessed);

use ACME::Cache;
use ACME::Util::Term;

use vars qw(@ISA @EXPORT @EXPORT_OK);

@ISA    = qw(Exporter);
@EXPORT = qw(
  msgErr msgFatal msgInfo msgWarn which
  var2str bool2str
  which haveIpv6
);
@EXPORT_OK = qw(
);

use constant CACHE_TTL => 1800;

our $VERSION = 0.04;

=head1 NAME ACME::Util

Usable utility functions.

=head1 SYNOPSIS

 use strict;
 use warnings;
 
 use ACME::Util qw(getFQDN);
 
 my $u = ACME::Util->new();
 
 my $term = ACME::Util->getTerm();
 $term = $u->getTerm();
  
 my $fqdn = getFQDN();
 $fqdn = $u->getFQDN();

=cut

#########################################################################
#                            GLOBAL VARIABLES                           #
#########################################################################

# cache
my $_cache = ACME::Cache->getInstance();
my $Error  = "";
my $term   = ACME::Util::Term->new();

# simply configure logger...
Log::Log4perl->easy_init($ERROR);

# get logger...
my $log = Log::Log4perl->get_logger(__PACKAGE__);

# ourselves (singleton object...)
my $_obj = undef;

sub new {

  # return previous instance if it exists...
  return $_obj if (defined $_obj);

  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};
  $self->{_error} = "";
  bless($self, $class);

  $_obj = $self;
  return $self;
}

#########################################################################
#                             FUNCTIONS                                 #
#########################################################################

=head1 AUTO-IMPORTS

This package automatically imports the following packages:
L<ACME::Cache> (simple caching module), L<ACME::Util::Term>.

=head1 OO INTERFACE

All described functions can be called in OO style. Example:

 my $u = ACME::Util->new();

 # do we have ipv6 support?
 print "IPv6: ", ($u->haveIpv6() ? "yes" : "no"), "\n";
 
 # print some messages...
 $u->msgInfo("This is info.");
 $u->msgWarn("This is warning");
 $u->msgErr("This is error message.");
 
 print "my fqdn is: ", $u->getFQDN(), "\n";

=head1 FUNCTIONS

=over

=cut

=item getError ()

Returns last error accoured.

=cut

sub getError {
  return $Error;
}

=head1 AUTOMATICALLY EXPORTED FUNCTIONS 

=item msgFatal ($message)

Prints fatal error message to stderr and internal logging object, then exits with status 1.

=cut

sub msgFatal {
  my $self = undef;
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));
  my ($package, $filename, $line) = caller;

  push(@_, $Error) unless (@_);
  my $str = join("", @_);
  $str =~ s/\s+$//g;

  print STDERR $term->lred("FATAL ERROR: "), $str, "\n";

  # send message to logging subsystem...
  my $log = undef;
  eval {
    $log = Log::Log4perl->get_logger(__PACKAGE__);
    $log->error($str);
    $log->error("Exiting with status: 1");
  };

  exit 1;
}

=item msgErr ($message)

Prints error message to stderr and internal logging object.

=cut

sub msgErr {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  print STDERR $term->lred("ERROR:   "), join("", @_), "\n";

  #$log_obj->error(join("", @_)) if (defined $log_obj);
}

=item msgWarn ($message)

Prints warning to stderr and internal logging object.

=cut

sub msgWarn {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  print $term->yellow("WARNING: "), join("", @_), "\n";

  #$log_obj->warn(join("", @_)) if (defined $log_obj);
}

=item msgInfo ($message)

Prints informational message to stdout and internal logging object.

=cut

sub msgInfo {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  print $term->bold("INFO:    "), join("", @_), "\n";

  #$log_obj->info(join("", @_)) if (defined $log_obj);
}

=item bool2str ($boolean)

Returns string representation of specified variable.

=cut

sub bool2str {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  return (($_[0] > 0) ? "yes" : "no");
}

=item var2str ($var, [$is_boolean = 0])

Returns variable value as quoted string. Useful for debugging.

=cut

sub var2str {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($value, $is_bool) = @_;
  $is_bool = 0 unless (defined $is_bool);
  if ($is_bool) {
    return (($value) ? "yes" : "no");
  }
  else {
    unless (defined $value) {
      return "undefined";
    }
    return '"' . $value . '"';
  }
}

=item which ($bin)

Searches for binary $bin in $PATH. Returns full path to binary if it's found in
$PATH and is executable, otherwise undef.

=cut

sub which {
  my $self = undef;
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($name) = @_;
  return undef unless (defined $name);

  foreach my $d (split(/[:;]+/, $ENV{PATH})) {
    my $bin = File::Spec->catfile($d, $name);
    return $bin if (-r $bin && -x $bin);
  }

  return undef;
}

=item haveIpv6 ()

Returns 1 if IPv6 support is available in perl interpreter, otherwise 0.

B<NOTE:>: This module tries to load perl IPv6 support modules L<Socket> and L<Socket6>
during initialization. 

=cut

sub haveIpv6 {
  return (HAVE_IPV6) ? 1 : 0;
}

=head1 INSTANCE METHODS

=item evalExitCode ($code [, $success_code = 0])

Validates return code B<$?> returned by system(), qx(), etc... and returns
if execution was successfull or not. Returns 1 if exit code $code means successfull
execution (if the real exit code was equal to $success_code), otherwise returns 0
and sets error message.

=cut

sub evalExitCode {
  my $self = undef;
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));
  my $code    = shift;
  my $success = shift;
  $success = 0 unless (defined $success);

  my $err = undef;
  my $r   = 0;

  if ($code == -1) {
    $err = "Unable to execute: $!\n";
  }
  elsif ($code & 127) {
    $err = sprintf("Program died with signal %d, %s coredump", ($code & 127),
      ($code & 128) ? "with" : "without");
  }
  else {
    my $e = $code >> 8;
    if ($e != $success) {
      $err = "Program exited with exit code $e";
    }
    else {
      $r = 1;
    }
  }

  # check for injuries...
  $Error = $err unless ($r);

  return $r;
}

=item stripColorCodes ($str, ...)

Strips shell colour codes from provided arguments and returns.

=cut

sub stripColorCodes {
  shift if ($_[0] eq __PACKAGE__ || (blessed($_[0]) && $_[0]->isa(__PACKAGE__)));
  my @r = ();
  map {
    my $str = $_;
    $str =~ s/(\033[^m]+m{1})//gm;
    push(@r, $str);
  } @_;

  return (wantarray ? @r : join("", @r));
}

=item getTerm ()

Returns initialized ACME::Util::Term object.

=cut

sub getTerm {
  return ACME::Util::Term->new();
}

=item getDomainName ()

Tries to discover domain name of local computer. Returns
discovered domain name on success, otherwise undef. 

=cut

sub getDomainName {
  my $key    = __PACKAGE__ . "|domainName";
  my $result = $_cache->get($key);
  return $result if (defined $result);

  my $domain = undef;

  # UNIX => /etc/resolv.conf
  if ($^O !~ m/^win/i && $^O !~ m/^vms/i) {
    my $res_file = "/etc/resolv.conf";
    my $fh = IO::File->new($res_file, 'r');

    if (defined $fh) {

      # read at most 20 lines of file
      my $i = 0;
      while ($i < 20 && defined(my $line = <$fh>)) {
        $i++;
        $line =~ s/^\s+//g;
        $line =~ s/\s+$//g;

        if ($line =~ m/^(?:search|domain)\s+(.+)/) {
          my @tmp = split(/\s+/, $1);

          # we found the bastard
          $domain = shift(@tmp);
          $domain = lc($domain) if (defined $domain);
          last;
        }
      }
    }

    # close file
    $fh = undef;

    # unsupported platform
  }
  else {
    $Error = "Unable to determine domain name: Not running on a supported platform.";
  }

  $result = lc($domain);

  # store to cache...
  $_cache->put($key, $result, CACHE_TTL);

  return $result;
}

=item getFQDN ()

Returns fully qualified domain name of running host on success,
otherwise undef.

=cut

sub getFQDN {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my $key    = __PACKAGE__ . "|fqdn";
  my $result = $_cache->get($key);

  unless (defined $result) {
    $result = hostname();
    $result .= "." . getDomainName() unless (isFQDN($result));
    $result = lc($result);
    $_cache->put("fqdn", $result, CACHE_TTL);
  }

  return $result;
}

=item hostname ()

Returns system hostname...

=cut

sub getHostname {
  return hostname();
}

=item isFQDN ($str)

Returns 1 if specified string is fully qualified domain name, otherwise returns 0.

=cut

sub isFQDN {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($str) = @_;
  return 0 unless (defined $str && length($str) > 0);
  return ($str =~ m/[a-z\-0-9]+\.[a-z\-0-9]+\.[a-z]{2,4}$/i && $str !~ /^\./);
}

=item isIpv6Addr ($str)

Returns 1 if provided string looks like IPv6 address, otherwise 0.

=cut

sub isIpv6Addr {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($str) = @_;
  return 0 unless (defined $str);

  # at least 2 ':' chars in $str

  # IPv6 address can have only [a-f0-9:.] chars
  return 0 if ($str =~ m/[^a-f0-9:\.]+/);

  # there must be at least 2 ':' chars in $str
  my $i = 0;
  map { $i++ if ($_ eq ':'); } split(//, $str);

  return ($i >= 2) ? 1 : 0;
}

=item isIpv4Addr ($str)

Returns 1 if provided string looks like IPv4 address, otherwise 0.

=cut

sub isIpv4Addr {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($str) = @_;
  return 0 unless (defined $str);
  if ($str =~ m/^(?:\d{1,3})\.(?:\d{1,3})\.(?:\d{1,3})\.(?:\d{1,3})$/) {
    return 1;
  }
  return 0;
}

=item resolveHost ($hostname [, $no_ipv6 = 0])

Resolves hostname $hostname and returns all resolved ip addresses. Result list
also contains IPv6 addresses if IPv6 support is available.

=cut

sub resolveHost {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($name, $no_ipv6) = @_;
  $no_ipv6 = 0 unless (defined $no_ipv6);
  return () unless (defined $name);

  #print "IPV6: ", $_have_ipv6, "\n";

  # now to the stuff...
  my @res = ();
  if (HAVE_IPV6 && !$no_ipv6) {
    no strict;
    my @r = getaddrinfo($name, 1, AF_UNSPEC, SOCK_STREAM);
    return () unless (@r);
    while (@r) {
      my $family    = shift(@r);
      my $socktype  = shift(@r);
      my $proto     = shift(@r);
      my $saddr     = shift(@r);
      my $canonname = shift(@r);
      next unless (defined $saddr);

      my ($host, undef) = getnameinfo($saddr, NI_NUMERICHOST | NI_NUMERICSERV);
      push(@res, $host) if (defined $host);
    }
  }
  else {
    my @addrs = gethostbyname($name);
    @res = map { inet_ntoa($_); } @addrs[4 .. $#addrs];
  }

  # assign system error code...
  $! = 99 unless (@res);

  return @res;
}

=item getUser ([$uid])

Returns UNIX username as string for specified uid. If uid is omitted returns
username of user running script. Returns undef in case of bad/nonexisting uid.

=cut

sub getUser {
  shift if ($_[0] eq __PACKAGE__);
  my ($uid) = @_;
  $uid = $> unless (defined $uid);

  my @tmp = getpwuid($>);
  return $tmp[0] if (@tmp);
  $Error = "Bad user: $!";
  return undef;
}

=item getGroup ([$gid])

Return UNIX group name as string for specified gid. If gid is omitted returns
group name of user running script. Returns undef in case of bad/nonexisting gid.

=cut

sub getGroup {
  shift if ($_[0] eq __PACKAGE__);
  my ($gid) = @_;
  $gid = $) unless (defined $gid);

  my @tmp = getgrgid($gid);
  return $tmp[0] if (@tmp);
  $Error = "Bad group: $!";
  return undef;
}

sub getUid {

  #shift if ($_[0] eq __PACKAGE__);
  shift;
  my ($user) = @_;
  return $> unless (defined $user);
  my @tmp = getpwnam($user);
  unless (@tmp) {
    $Error = "Invalid user: $user";
    return -1;
  }
  return (@tmp) ? $tmp[2] : -1;
}

sub getGid {

  #shift if ($_[0] eq __PACKAGE__);
  shift;
  my ($group) = @_;
  $group = __PACKAGE__->getGroup() unless (defined $group);
  my @tmp = getgrnam($group);
  unless (@tmp) {
    $Error = "Invalid group: $group";
    return -1;
  }
  return $tmp[2];
}

sub getUserGid {

  #shift if ($_[0] eq __PACKAGE__);
  shift;
  my ($user) = @_;
  $user = $> unless (defined $user);
  my @tmp = getpwnam($user);
  unless (@tmp) {
    $Error = "Invalid user: $user";
    return -1;
  }
  return (@tmp) ? $tmp[3] : -1;
}

=item getHome ([$uid])

Returns home directory for specified user on success, otherwise undef. If $uid
is omitted, current euid is used.

=cut

sub getHome {
  my ($uid) = @_;
  my $dir = (getpwuid($>))[7];
  return $dir;
}

=item dumpVar ($var)

Returns string representation of specified variable(s) using Data::Dumper in
a form suitable for feeding to perl eval.

=cut

sub dumpVar {
  my $self = undef;
  $self = shift if (defined $_[0] && ($_[0] eq __PACKAGE__ || (blessed($_[0]) && $_[0]->isa(__PACKAGE__))));
  my $d = Data::Dumper->new([@_]);
  $d->Terse(1);
  $d->Indent(1);
  $d->Sortkeys(1);
  return $d->Dump();
}

=item dumpVarCompact ($var, ...)

Returns compact string representation of specified variable(s) using Data::Dumper in
a form suitable for feeding to perl eval.

=cut

sub dumpVarCompact {
  my $self = undef;
  $self = shift if (defined $_[0] && ($_[0] eq __PACKAGE__ || (blessed($_[0]) && $_[0]->isa(__PACKAGE__))));
  my $d = Data::Dumper->new([@_]);
  $d->Terse(1);
  $d->Indent(0);
  $d->Sortkeys(1);
  return $d->Dump();
}

=item getSubPackages ($package)

Returns list of available subpackages of package specified by $package

=cut

sub getSubPackages {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  my $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));
  my ($package) = @_;
  return () unless (defined $package && length($package) > 0);

  # do we have anything in cache?
  my $key = __PACKAGE__ . "|subpackages_" . $package;
  my $res = $_cache->get($key);
  if (defined $res) {
    return @{$res};
  }

  my (@drivers, %seen_dir);
  my $dirh = undef;
  local $@;

  # convert package to dir...
  $package =~ s/::/\//g;

  # check all directories in perl include path...
  foreach my $d (@INC) {
    chomp($d);
    my $dir = File::Spec->catdir($d, $package);

    next unless (-d $dir);
    next if (exists($seen_dir{$d}));

    $seen_dir{$d} = 1;

    # open directory...
    my $x = opendir($dirh, $dir);

    foreach my $f (readdir($dirh)) {
      next unless ($f =~ s/\.pm$//);
      next if ($f eq 'NullP');
      next if ($f eq 'EXAMPLE');
      next if ($f =~ m/^_/);

      # this driver seems ok, push it into list of drivers
      push(@drivers, $f) unless ($seen_dir{$f});
      $seen_dir{$f} = $d;
    }
    closedir($dirh);
  }

  # store to cache
  $_cache->put($key, [@drivers], CACHE_TTL);

  # "return sort @drivers" will not DWIM in scalar context.
  return (wantarray ? sort @drivers : @drivers);
}

=item initPackage ($class, key => value, ...)

Tries to initilize object $class feeding specified arguments to $class object constructor.
If specified $class is not loaded yet, this method loads it automatically. Returns
initialized object on success, otherwise returns undef and sets error message.

=cut

sub initPackage {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  my $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my $class = shift;

  my $err = "";
  my $obj = undef;

  # try to load driver
  $log->trace("Initializing object class $class");
  eval "require $class";
  if ($@) {
    $err = "Unable to load class '$class': $@";
    goto outta_init_subpkg;
  }

  # try to initialize object
  eval {
    $obj = $class->new(@_);
    $log->debug("Successfully created instance of class $class version " . $class->VERSION() . ".");
  };
  if ($@) {
    $err = "Exception accoured while initializing object $class: $@";
    goto outta_init_subpkg;
  }
  if (!defined $obj) {
    $err = "Error initializing object from class $class: Constructor returned undefined object.";
    goto outta_init_subpkg;
  }

outta_init_subpkg:
  unless (defined $obj) {
    $Error = $err;
    $log->error($Error);
  }

  return $obj;
}

=item mkdir_r ($dir)

Tries to recursively create directory $dir. Returns 1 on success, otherwise returns 0
and sets error message.

=cut

sub mkdir_r {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  my $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($dir) = @_;
  unless (defined $dir) {
    $Error = "Unspecified directory.";
    return 0;
  }

  my $path = "";

  foreach my $chunk (split(/\//, $dir)) {
    unless (defined $chunk && length($chunk)) {
      $path = "/";
    }
    else {
      if ($path =~ m/\/$/) {
        $path .= $chunk;
      }
      else {
        $path .= "/" . $chunk;
      }
    }

    if (-e $path) {
      unless (-d $path) {
        $Error = "Unable to create '$dir': '$path' is not directory.";
        return 0;
      }
      next;
    }
    $log->debug("Creating directory: $path");
    unless (mkdir($path)) {
      $Error = "Unable to create directory '$path': $!";
      return 0;
    }
  }

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
