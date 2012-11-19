package ACME::TC::Util;


use strict;
use warnings;

use Cwd;
use FindBin;
use Exporter;
use IO::File;
use File::Spec;
use Data::Dumper;
use Log::Log4perl;
use Sys::Hostname;
use File::Basename;
use Scalar::Util qw(blessed);

use ACME::Util;

use vars qw(
  @ISA @EXPORT @EXPORT_OK
  $MYNAME
  $config_driver $status_driver
  $config_driver_params $status_driver_params
  $log_config_file
  $agent_daemonize
  $agent_plugins
  $agent_connectors
);

@ISA    = qw(Exporter);
@EXPORT = qw(
  msgErr msgFatal msgInfo msgWarn
  getTerm var2str
  $config_driver $status_driver
  $config_driver_params $status_driver_params
);
@EXPORT_OK = qw(
);

#####################################################
#             tc configuration FILE             #
#####################################################


# WARNING: everything inside this file is
# INTERPRETED by perl(1) interpreter! Think twice
# before making changes in this file.

# DO NOT UNCOMMENT THE FOLLOWING TWO LINES!
use strict;
use warnings;

# Configuration service driver
#
# The complete list of implemented configuration
# drivers can be obtained by invoking command:
#
# tcctl.pl --list-config-drivers
#
# Type: string
# Default: "FS"
$config_driver = "FS";

# Status service object driver
#
# The complete list of implemented status
# drivers can be obtained by invoking command:
#
# tcctl.pl --list-status-drivers
#
# Type: string
# Default: "FS"
$status_driver = "FS";

# Configuration service object parameters
#
# This directive specifies settings of
# configuration driver.
#
# Type: anonymous hash reference
# Default: {}
$config_driver_params = {};

# Status service object parameters
#
# This directive specifies settings of
# status driver.
#
# Type: anonymous hash reference
# Default: {}
$status_driver_params = {};

# Log::Log4perl logging configuration file
#
# This option specifies configuration file
# for built-in logging based on Log::Log4perl.
# If you leave this setting empty, built-in
# logging will be initialized with default
# values (syslog based logging). This options
# is available for special cases, when there
# is a need to debug whole or just part of
# the framework. See perldoc Log::Log4perl
# for logging configuration file syntax.
#
# Type: string
# Default: ""
$log_config_file = "";

# Comment out the following line in order to
# make this configuration file valid.
#
# die "Default configuration file should be edited :)\n";

# Do not comment the following line
1;

# vim:syntax=perl
# EOF

use constant CACHE_TTL => 1800;

our $VERSION = 0.02;

=head1 NAME ACME::TC::Util

Usable utility functions for tc framework.

=head1 SYNOPSIS
 # create object
 my $u = ACME::TC::Util->new();
 
 # configure logger
 $log = $u->loggerConfigureDefault();
 $log = $u->loggerConfigureDebug();
 $log = $u->loggerConfigureTrace();
 $log = $u->loggerConfigure($file);
 $log = $u->loggerConfigure($config_string);

=cut

#########################################################################
#                            GLOBAL VARIABLES                           #
#########################################################################

# determine home directory
my $TC_ROOT = Cwd::realpath(File::Spec->catdir($FindBin::RealBin, ".."));
my $MY_HOME = "";
my @tmp     = getpwuid($>);
$MY_HOME = $tmp[7] if (@tmp);
my $username = $tmp[0] if (@tmp);
my $MYNAME = basename($0);

# cache
my $_cache = ACME::Cache->getInstance();
my $Error  = "";                           # last error that accoured inside tcctl.pl


# logging vars
my $log_config_default = "
	# root logger
	log4j.rootLogger=INFO,Syslog

	# APPENDER (Syslog, general)
	log4perl.appender.Syslog			= Log::Dispatch::Syslog
	log4perl.appender.Syslog.ident		= tc/$MYNAME
	log4perl.appender.Syslog.logopt		= cons,pid,nofatal,nowait
	log4perl.appender.Syslog.facility	= user
	log4perl.appender.Syslog.layout		= Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Syslog.layout.ConversionPattern = %p: %m
";

my $log_config_debug = "
	# root logger
	log4j.rootLogger=DEBUG,Syslog

	# APPENDER (Syslog, debug)
	log4perl.appender.Syslog			= Log::Dispatch::Syslog
	log4perl.appender.Syslog.ident		= tc/$MYNAME
	log4perl.appender.Syslog.logopt		= cons,pid,nofatal,nowait
	log4perl.appender.Syslog.facility	= user
	log4perl.appender.Syslog.layout		= Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Syslog.layout.ConversionPattern = %p: %M{2}(line %L): %m
";

my $log_config_trace = "
	# root logger
	log4j.rootLogger=ALL,Syslog

	# APPENDER (Syslog, debug)
	log4perl.appender.Syslog			= Log::Dispatch::Syslog
	log4perl.appender.Syslog.ident		= tc/$MYNAME
	log4perl.appender.Syslog.logopt		= cons,pid,nofatal,nowait
	log4perl.appender.Syslog.facility	= user
	log4perl.appender.Syslog.layout		= Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Syslog.layout.ConversionPattern = [%d{DATE}] [%H_%P] %p: %F{1}, line %L %M{1}(): %m
";

my @config_dirs = (
  File::Spec->catdir($MY_HOME, ".tc",    "config"),
  File::Spec->catdir($MY_HOME, ".tc"),
  File::Spec->catdir($MY_HOME, "etc",    "tc"),
  File::Spec->catdir($MY_HOME, "config", "tc"),
  File::Spec->catdir($TC_ROOT, "etc"),
  File::Spec->catdir("/usr", "local", "etc", "tc"),
  File::Spec->catdir("/usr", "local", "etc"),
  File::Spec->catdir("/etc", "tc"),
  File::Spec->catdir("/etc"),
);

my $config_file_name = "tc.conf";
my $log              = undef;
my $term             = ACME::Util::Term->new();

# singleton object
my $_obj = undef;

sub new {

  # return singleon if available...
  return $_obj if (defined $_obj);

  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};
  $self->{_error} = "";
  bless($self, $class);

  # set singleton
  $_obj = $self;

  return $self;
}

#########################################################################
#                             FUNCTIONS                                 #
#########################################################################

=head1 FUNCTIONS

=cut

=item getError ()

Returns last error accoured.

=cut

sub getError {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  my $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  return (defined $self) ? $self->{_error} : $Error;
}

=head1 LOGGING FUNCTIONS

=item loggerConfigureDefault ()

Initializes log4perl logger with built-in default configuration and returns logger object.

=cut

sub loggerConfigureDefault {

  # who called us?
  my ($package, $filename, $line) = caller();
  return loggerConfigure(\$log_config_default, $package);
}

=item loggerConfigureDebug ()

Initializes log4perl logger with built-in debugging configuration and returns logger object.

=cut

sub loggerConfigureDebug {

  # who called us?
  my ($package, $filename, $line) = caller();
  return loggerConfigure(\$log_config_debug, $package);
}

=item loggerConfigureTrace ()

=cut

sub loggerConfigureTrace {

  # who called us?
  my ($package, $filename, $line) = caller();
  return loggerConfigure(\$log_config_trace, $package);
}

=item loggerConfigure ({$file|$string_ref|undef})

Configures log4perl logger. Argument can be:
- Path to Log4perl configuration file
- Reference to string containing log4perl configuration
- undef - will use default built-in configuration

Returns initialized logging object on success, otherwise undef.

=cut

sub loggerConfigure {
  my $self = undef;
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($src, $package) = @_;
  unless (defined $package) {
    my ($p, $filename, $line) = caller();
    $package = $p;
  }

  # no log configuration source? configure default logger or use default
  # logging configuration file...
  unless (defined $src) {
    if (defined $log_config_file && length($log_config_file)) {
      $src = $log_config_file;
    }
    else {
      $src = \$log_config_default;
    }
  }

  # try to initialize logger
  eval { Log::Log4perl->init($src); };
  if ($@) {
    $Error = "Unable to initialize logging subsystem: $@";
    $self->{_error} = $Error if (defined $self);
    return undef;
  }

  # initialize and return logging object
  $log = Log::Log4perl::get_logger(__PACKAGE__);
  return Log::Log4perl->get_logger($package);
}

=head1 tc basic configuration

=item loadTCConfig ([$file][, $configure = 1])

Tries to load specified tc configuration file; if configuration file name is omitted
or if loading of configuration file fails, function tries to load configuration
file from default locations.

Returns 1 on success, otherwise 0.

=cut

sub tcConfigLoad {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my ($file, $configure) = @_;
  $configure = 1 unless (defined $configure);
  my $r = 0;

  # is this really a plain file?
  if (defined $file && -f $file && -r $file) {
    return 1 if (tcConfigLoadFile($file));
  }

  # well, we can still try to load configuration
  # from default location
  foreach my $dir (@config_dirs) {
    next unless (defined $dir);
    my $f = File::Spec->catfile($dir, $config_file_name);
    next unless (-f $f && -r $f);
    $log->debug("Trying to load configuration file: $f");
    if (tcConfigLoadFile($f, $configure)) {
      $log->debug("Loaded configuration file: $f");
      $r = 1;
      last;
    }
  }

  return $r;
}

=item tcConfigDirs ()

Returns list of directories searched for tc configuration file
by method L<tcConfigLoad ()>. 

=cut

sub tcConfigDirs {
  return @config_dirs;
}

=item tcConfigFileName ()

Returns name of tc configuration file. 

=cut

sub tcConfigFileName {
  return $config_file_name;
}

=item tcConfigLoadFile ($file [, $configure = 1])

Tries to load tc configuration file specified by $file argument.
If $configure argument is true (default), method will configure default
settings for ServiceConfig and ServiceStatus classes using method B<setDefaultObjConfig()>.

Returns 1 on success, otherwise 0.

=cut

sub tcConfigLoadFile {
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));
  my ($file, $configure) = @_;
  $configure = 1 unless (defined $configure);

  if (!defined $file) {
    $Error = "Undefined filename.";
  }
  elsif (!-e $file) {
    $Error = "File '$file' does not exist.";
    return 0;
  }
  elsif (!-f $file) {
    $Error = "File '$file' is not a plain file.";
    return 0;
  }
  elsif (!-r $file) {
    $Error = "File '$file' is not readable.";
    return 0;
  }

  do $file;

  if ($@) {
    $Error = "Bad configuration file syntax in file '$file': $@";
    $Error =~ s/\s+$//g;
    return 0;
  }

  # configure service config and service status objects...
  if ($configure) {
    ACME::TC::ServiceConfig->setDefaultObjConfig(driver => $config_driver, %{$config_driver_params});
    ACME::TC::ServiceStatus->setDefaultObjConfig(driver => $status_driver, %{$status_driver_params});
  }

  return 1;
}

=item tcConfigDefaults

Returns default tc configuration file as string on success, otherwise undef.

=cut

sub tcConfigDefaults {
  my $fd = IO::File->new(__FILE__, 'r');
  return "" unless (defined $fd);
  my $i          = 1;
  my $str        = "";
  my $line_first = 51;
  my $line_last  = 137;
  while ($i <= $line_last && defined(my $line = <$fd>)) {
    $i++;
    next if ($i <= $line_first);
    $str .= $line;
  }

  return $str;
}

=item tcVersionStr ([$colorized = 0])

Returns string containing tc module versions...

=cut

sub tcVersionStr {
  shift if ($_[0] eq __PACKAGE__ || (blessed($_[0]) && $_[0]->isa(__PACKAGE__)));
  my ($colorized) = @_;
  $colorized = 0 unless (defined $colorized);

  my $str = "";

  $str .= $term->bold("RELEASE:") . "\n";
  $str .= sprintf("  %-40.40s %s\n", "tc", ACME::TC::Version->VERSION());
  $str .= "\n";

  my $y = $main::MYNAME;

  $str .= $term->bold("MAIN SCRIPT:") . "\n";
  $str .= sprintf("  %-40.40s %-.2f\n", $main::MYNAME, $main::VERSION);
  $str .= "\n";

  $str .= $term->bold("CONFIGURATION:") . "\n";
  $str .= sprintf("  %-40.40s %-.2f\n", "ServiceConfig", ACME::TC::ServiceConfig->VERSION());
  foreach my $svc (ACME::TC::ServiceConfig->getDrivers()) {
    my $obj = ACME::TC::ServiceConfig->factory($svc);
    next unless (defined $obj);
    $str .= sprintf("  %-40.40s %-.2f\n", $svc, $obj->VERSION());
  }
  $str .= "\n";

  $str .= $term->bold("STATUS:") . "\n";
  $str .= sprintf("  %-40.40s %-.2f\n", "ServiceStatus", ACME::TC::ServiceStatus->VERSION());
  foreach my $svc (ACME::TC::ServiceStatus->getDrivers()) {
    my $obj = ACME::TC::ServiceStatus->factory($svc);
    next unless (defined $obj);
    $str .= sprintf("  %-40.40s %-.2f\n", $svc, $obj->VERSION());
  }
  $str .= "\n";

  $str .= $term->bold("SERVICES:") . "\n";
  $str .= sprintf("  %-40.40s %-.2f\n", "Service", ACME::TC::Service->VERSION());
  foreach my $svc (ACME::TC::Service->getDrivers()) {
    my $obj = ACME::TC::Service->factory($svc);
    next unless (defined $obj);
    $str .= sprintf("  %-40.40s %-.2f\n", $svc, $obj->VERSION());
  }

  $str = stripColorCodes($str) unless ($colorized);
  return $str;
}

sub _fixServiceOpt {
  my $self = undef;
  shift if (defined $_[0] && $_[0] eq __PACKAGE__);
  $self = shift if (blessed($_[0]) && $_[0]->isa(__PACKAGE__));

  my %default_opt = ();
}

=item serviceObjCreate ($driver, key => value, key => value)

Initializes and returns new ACME::TC::Service object initialized with driver $driver with some
additional options. Returns initialized object on success, otherwise undef and sets error message.

B<Valid keys:>

=item B<localConfigOnly> (boolean, 0): Enable local configuration only (no configuration service)

=item B<backupRestore> (boolean, 1): Enable/disable built-in backup-restore functionality...

=item B<assignDefaultConfig> (boolean, 1): Assign default L<ACME::TC::ServiceConfig> configuration object

=item B<assignDefaultStatus> (boolean, 1): Assign default L<ACME::TC::ServiceStatus> object

=item B<force> (boolean, 0): Set forced execution

=over

B<Example:>

 my $tu = ACME::TC::Util->new();
 
 my $driver = "MySQL";
 my $svc = $tu->serviceObjCreate(
 	$driver,
 	localConfigOnly => 1,
 	force => 1,
 );
 unless (defined $svc) {
 	msgFatal($tu->getError());
 }
 
 # get the status :)
 my $s = $svc->status();
 print "$driver status is: ", $s->toString(), "\n";

=cut

sub serviceObjCreate {
  my ($self, $driver, %opt) = @_;

  # fix options...
  my $c = $self->_fixObjCreateOpt(%opt);

  my $err = "";
  my $obj = ACME::TC::Service->factory($driver);

  if (defined $obj) {

    # assign service config object?
    if ($c->{assignDefaultConfig}) {
      my $x = ACME::TC::ServiceConfig->getDefaultObj();
      if (defined $x) {
        $obj->assignServiceConfigObj($x);
      }
      else {
        $err = "Unable to set default configuration object: " . ACME::TC::ServiceConfig->getError();
      }
    }

    # assign service status object?
    if ($c->{assignDefaultStatus}) {
      my $x = ACME::TC::ServiceStatus->getDefaultObj();
      if (defined $x) {
        $obj->assignServiceStatusObj($x);
      }
      else {
        $err = "Unable to set default status object: " . ACME::TC::ServiceStatus->getError();
        $obj = undef;
      }
    }

    # set local-only flag if set...
    $obj->localConfigOnly($c->{locaConfigOnly});

    # backup/restore options?
    if ($c->{backupRestore}) {
      $obj->backupRestoreEnable();
    }
    else {
      $obj->backupRestoreDisable();
    }

    # set force propery
    if ($c->{force}) {
      $obj->setForced();
    }
  }
  else {
    $err = "Error initializing service object: " . ACME::TC::Service->factoryError();
  }

  unless (defined $obj) {
    if (defined $self) {
      $self->{_error} = $err;
    }
    else {
      $Error = $err;
    }
  }

  return $obj;
}

sub _fixObjCreateOpt {
  my ($self, %opt) = @_;

  # default structure...
  my $r = {
    localConfigOnly     => 0,
    backupRestore       => 1,
    assignDefaultConfig => 1,
    assignDefaultStatus => 1,
    force               => 0
  };

  # fix it with provided values...
  map {
    if (exists($opt{$_}))
    {
      $r->{$_} = $opt{$_};
    }
  } keys %{$r};

  return $r;
}

=head1 SEE ALSO

L<ACME::Util>

=cut

=head1 AUTHOR

Brane F. Gracnar

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
