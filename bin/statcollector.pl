#!/usr/bin/perl


BEGIN {

  # disable annoying log4perl configuration initialization warning
  package Log::Log4perl::Logger;
  no warnings;
  use Log::Log4perl qw(:nowarn);
  sub init_warn {1}

  # optionally check for faster available POE loop
  package main;

  sub check_perl_module {
    my ($pkg) = @_;

    # set lib environment..
    $ENV{PERL5LIB} = join(":", @INC);
    system("perl -e 'use $pkg' >/dev/null 2>&1");
    return ($? == 0) ? 1 : 0;
  }

  # check if user wants faster event loop?
  sub faster_loop_search {
    my @faster_loops = qw(
      POE::Loop::EVx
      POE::Loop::IO_Poll
    );

    foreach my $loop (@faster_loops) {

      # is it available?
      next unless (check_perl_module($loop));

      $ENV{POE_EVENT_LOOP} = $loop;

      #$u->msgInfo("Will use event loop: $loop");
      last;
    }
  }

  use FindBin;
  use File::Spec;
  use Getopt::Long;
  use Cwd qw(realpath getcwd);

  # determine libdir and put it into @INC
  use lib qw(/usr/lib/statcollector);
  use lib realpath(File::Spec->catdir($FindBin::RealBin, "..", "lib", "statcollector"));
  use lib realpath(File::Spec->catdir($FindBin::RealBin, "..", "lib"));

  Getopt::Long::Configure("bundling", "permute", "bundling_override", "pass_through");
  my $do_it = 1;
  my $g = GetOptions('opt-loop!' => \$do_it,);

  # check for faster POE loops...
  delete($ENV{POE_EVENT_LOOP});
  if ($do_it) {
    faster_loop_search();
  }
}

package main;

use strict;
use warnings;

use FindBin;
use IO::File;
use File::Spec;
use Data::Dumper;
use File::Basename;
use POSIX qw(setsid);
use Cwd qw(realpath getcwd);
use Getopt::Long;

use ACME::Util;
use ACME::TC::Util;
use ACME::TC::Agent;

use constant STAT_CLASS_BASE => 'ACME::TC::Agent::Plugin::StatCollector';

#########################################################################
#                            GLOBAL VARIABLES                           #
#########################################################################

#########################################################################
#                               FUNCTIONS                               #
#########################################################################

my $MYNAME  = basename($0);
my $VERSION = 0.16;

my $u  = ACME::Util->new();
my $tu = ACME::TC::Util->new();

my $Error = "";       # last error that accoured inside this script..
my $agent = undef;    # TC agent object...

my $pid_file = File::Spec->catfile(File::Spec->tmpdir(), $MYNAME . '-' . $u->getUser() . '.pid');

my $term = $u->getTerm();

my $log             = undef;
my $agent_daemonize = 0;
my $log_config_file = undef;

my @mandatory_plugins = ();
my $c                 = config_default();

my $http_port = undef;
my $http_addr = undef;

####################################################

sub config_default_str {
  my $str = <<EOF
#
# $MYNAME configuration file
#

# \$Id\$
# \$Date\$
# \$Author\$
# \$Revision\$
# \$LastChangedRevision\$
# \$LastChangedBy\$
# \$LastChangedDate\$
# \$URL\$

parsers = "parser.d/*.conf"

filters = "filter.d/*.conf"

storage = "storage.d/*.conf"

source_groups = "source.d/*.conf"

http_port = $http_port
http_addr = $http_addr

# EOF
EOF
    ;
  return $str;
}

sub config_default_logging_str {
  my $username = $u->getUser();
  my $script   = $MYNAME;
  $script =~ s/\.pl$//g;
  my $str = <<EOF
#
# $MYNAME logging configuration
#

# \$Id\$
# \$Date\$
# \$Author\$
# \$Revision\$
# \$LastChangedRevision\$
# \$LastChangedBy\$
# \$LastChangedDate\$
# \$URL\$

# See:
#	http://search.cpan.org/perldoc?Log::Log4perl
#	http://search.cpan.org/perldoc?Log::Log4perl::FAQ

########################################################
#                   ROOT LOGGER                        #
########################################################

# everything is logged to simple log file.
log4j.rootLogger=INFO,normal

# Uncomment this to use syslog logging
# log4j.rootLogger=INFO,syslog

# Debug everything?
# Are you sure, that you don't want per-class debugging?
# log4j.rootLogger=DEBUG,DebugFile

# Trace everything - even heavier debugging
# Are you sure, that you don't want per-class debugging?
# log4j.rootLogger=DEBUG,DebugFile

########################################################
#                PER-CLASS LOGGERS                     #
########################################################

# Trace filters
# log4j.logger.ACME.TC.Agent.Plugin.StatCollector.Filter=ALL,DebugFile
#
# Trace parsers
# log4j.logger.ACME.TC.Agent.Plugin.StatCollector.Parser=ALL,DebugFile
#
# Trace HTTP source
# log4j.logger.ACME.TC.Agent.Plugin.StatCollector.Source.HTTP=ALL,DebugFile
#
# Trace storage
# log4j.logger.ACME.TC.Agent.Plugin.StatCollector.Storage=ALL,DebugFile

# additivities...
# log4j.additivity.ACME.TC.Agent.Plugin.StatCollector=1

########################################################
#                      APPENDERS                       #
########################################################

# APPENDER (syslog, general)
log4perl.appender.syslog                = Log::Dispatch::Syslog
log4perl.appender.syslog.ident          = ${MYNAME}
log4perl.appender.syslog.logopt         = cons,pid,nofatal,nowait
log4perl.appender.syslog.facility       = user
log4perl.appender.syslog.layout         = Log::Log4perl::Layout::PatternLayout
log4perl.appender.syslog.layout.ConversionPattern = [%c{2}] %-.5p: %m

# APPENDER (DebugFile, Debug)
log4perl.appender.DebugFile             = Log::Log4perl::Appender::File
log4perl.appender.DebugFile.filename    = /tmp/${username}-${script}-debug.log
log4perl.appender.DebugFile.layout      = Log::Log4perl::Layout::PatternLayout
log4perl.appender.DebugFile.layout.ConversionPattern = [%d{DATE}] %p: %F{1}, line %L %M{3}(): %m%n

# APPENDER (File, normal)
log4perl.appender.normal                = Log::Log4perl::Appender::File
log4perl.appender.normal.filename       = /tmp/${username}-${script}.log
# log4perl.appender.normal.Threshold      = INFO
log4perl.appender.normal.layout         = Log::Log4perl::Layout::PatternLayout
log4perl.appender.normal.layout.ConversionPattern = [%d{DATE}] [%c{2}] %-.5p: %m%n

# EOF
EOF
    ;

  return $str;
}

sub config_default {
  return {
    parsers       => undef,
    filters       => undef,
    storage       => undef,
    source_groups => undef,
    source        => undef,
    http_port     => $http_port,
    http_addr     => $http_addr,
  };
}

sub config_load {
  my ($file) = @_;
  unless (defined $file && length($file) > 0) {
    $Error = "Undefined configuration file.";
    return undef;
  }
  my $fd = IO::File->new($file, 'r');
  unless (defined $fd) {
    $Error = "Unable to open file $file for reading: $!";
    return undef;
  }

  my @path_keys = qw(
    parsers filters storage
    source_groups source
  );
  my $dir = dirname($file);

  my $c   = config_default();
  my $i   = 0;
  my $err = "Error in configuration file $file, line ";
  while (defined(my $l = <$fd>)) {
    $i++;
    $l =~ s/^\s+//g;
    $l =~ s/\s+$//g;

    # skip empty lines
    next unless (length($l) > 0);

    # skip comments
    next if ($l =~ m/^#/);

    # parse line
    my ($key, $val) = split(/\s*=\s*/, $l);
    unless (defined $key && defined $val) {
      $Error = $err . $i . " undefined key or value.";
      return undef;
    }

    # sanitize key and value
    $key =~ s/^\s+//g;
    $key =~ s/\s+$//g;
    $val =~ s/^\s+//g;
    $val =~ s/\s+$//g;

    # strip quotes from value
    $val =~ s/^["']+//g;
    $val =~ s/["']+$//g;

    unless (length($key) > 0 && length($val) > 0) {
      $Error = $err . $i . " zero length key or value.";
      return undef;
    }

    # is this key ok?
    unless (exists($c->{$key})) {
      $Error = $err . $i . " unknown configuration parameter: $key";
      return undef;
    }

    # fix val if necessary...
    if (grep(/^$key$/, @path_keys)) {
      if ($val !~ /^(\/|.\/|..\/)/) {
        $val = File::Spec->catfile($dir, $val);
      }
    }

    # assign key
    $c->{$key} = $val;
  }

  return $c;
}

sub perldoc {
  my ($section, $item) = @_;
  my $pkg = STAT_CLASS_BASE . '::' . ucfirst($section);
  $pkg .= '::' . $item if (length($item));
  perldoc_base($pkg);
}

sub perldoc_base {
  my ($pkg) = @_;

  # set lib environment..
  $ENV{PERL5LIB} = join(":", @INC);
  exec("perldoc $pkg");
  exit 0;
}

sub package_drivers {
  my ($section) = @_;
  print join(', ', package_drivers_get($section)), "\n";
  exit 0;
}

sub package_drivers_get {
  my ($section) = @_;
  my $pkg = STAT_CLASS_BASE . '::' . ucfirst($section);
  eval "require $pkg";
  exit 1 if ($@);
  return $pkg->getDirectSubClasses();
}

sub daemonize {
  $log->debug("Becoming a daemon.");
  $log->debug("Forking into background.");
  my $pid = fork();
  unless (defined $pid) {
    $u->msgFatal("Unable to fork(): $!");
  }

  # parent
  if ($pid) {
    $u->msgInfo("Forked into background, becoming a daemon; Check logs for details.");
    exit 0;
  }

  # child

  # poe kernel has forked...
  eval { POE::Kernel->has_forked(); };

  $log->debug("Starting new session.");
  unless (setsid()) {
    $u->msgFatal("Unable to create new process session: $!");
  }

  # perform the second fork...
  $log->debug("Performing second fork.");
  $pid = fork();
  unless (defined $pid) {
    $u->msgFatal("Error performing second fork: $!");
  }

  # parent again?
  exit 0 if ($pid);

  # this is a second child...

  # reopen standard streams
#	$log->debug("Reopening standard I/O streams.");
#	close(*STDOUT);
#	close(*STDERR);
#	close(*STDIN);
#	open(STDIN, '<', File::Spec->devnull());
#	open(STDERR, '>', File::Spec->devnull());
#	open(STDOUT, '>', File::Spec->devnull());
#	# reallocate standard output streams...

  # inform poe kernel that we forked...
  eval { POE::Kernel->has_forked(); };

  # set proctitle
  #my $proctitle = $MYNAME . " (" . $u->getUser() . ")";
  #$log->debug("Setting proctitle to: $proctitle");
  #$0 = $proctitle;

  # write pid file
  # pid_write($$);

  # we are now really a daemon
  $log->info("Daemon initialization complete.");
  return 1;
}

sub pid_read {
  my $fd = IO::File->new($pid_file, 'r');
  unless (defined $fd) {
    $Error = "Error reading pid file: $!";
    return 0;
  }
  my $str = <$fd>;
  $str =~ s/^\s+//g;
  $str =~ s/\s+$//g;
  $fd = undef;
  my $pid = 0;
  { no warnings; $pid = int($str); }
  return $pid;
}

sub pid_write {
  my ($pid) = @_;
  my $fd = IO::File->new($pid_file, 'w');
  unless (defined $fd) {
    msg_error("Error opening pid file '$pid_file' for writing: $!");
    return 0;
  }
  print $fd $pid;
  $fd = undef;
  return 1;
}

sub pid_remove {
  return 0 unless (-f $pid_file && -w $pid_file);
  unless (unlink($pid_file)) {
    msg_warn("Error removing pid file '$pid_file': $!");
    return 0;
  }
  return 1;
}

#
# returns tc-agent compatible configuration hash reference.
#
sub conf_generate {
  my $c = {
    connectors => [
      {
        driver  => 'HTTP',
        enabled => 1,
        params =>
          {addr => '*', port => 16661, contexts => [{uri => '/', handler => 'ContextList', params => {},}],},
      },
    ],
    plugins => [
      {
        driver  => 'StatCollector',
        enabled => 1,
        params  => {
          stopAgentOnShutdown => 1,
          parsers             => {},
          filters             => {},
          sourceGroups        => {},
          source              => [],
          storage             => [],
        }
      },
    ],
  };

  return $c;
}

# tcize configuration
sub config_tcize {
  my ($cfg) = @_;
  my $c = conf_generate();

  # apply local stuff...
  $c->{plugins}->[0]->{params}->{sourceGroups} = {xxx => $cfg->{source_groups}};
  $c->{plugins}->[0]->{params}->{parsers}      = {xxx => $cfg->{parsers}};
  $c->{plugins}->[0]->{params}->{filters}      = {xxx => $cfg->{filters}};
  $c->{plugins}->[0]->{params}->{storage}      = [$cfg->{storage}];
  $c->{plugins}->[0]->{params}->{contextPath}  = "/";

  # connector
  if (exists($cfg->{http_port}) && defined $cfg->{http_port} && length($cfg->{http_addr}) > 0) {
    $c->{connectors}->[0]->{params}->{port} = $cfg->{http_port};
  }
  if (defined $http_port) {
    $c->{connectors}->[0]->{params}->{port} = $http_port;
  }

  if (exists($cfg->{http_addr}) && defined $cfg->{http_addr} && length($cfg->{http_addr}) > 0) {
    $c->{connectors}->[0]->{params}->{addr} = $cfg->{http_addr};
  }
  if (defined $http_addr) {
    $c->{connectors}->[0]->{params}->{addr} = $http_addr;
  }

  return $c;
}

sub config_dir_init {
  my ($dir) = @_;

  # create directory
  unless ($u->mkdir_r($dir)) {
    $u->msgFatal($u->getError());
  }

  # create subdirs
  for my $s ('filter.d', 'parser.d', 'source.d', 'storage.d') {
    my $sdir = File::Spec->catfile($dir, $s);
    unless ($u->mkdir_r($sdir)) {
      $u->msgFatal($u->getError());
    }
  }

  # create config files
  my $file = File::Spec->catfile($dir, 'stat_collector.conf');
  if (!-f $file) {
    $u->msgInfo("Creating $MYNAME configuration file: $file");
    system("$0 --default-config > $file");
    $u->msgFatal("Unable to create configuration file $file") if ($? != 0);
  }
  else {
    $u->msgWarn("$MYNAME configuration file $file already exists, skipping.");
  }

  # create logger configuration file
  $file = File::Spec->catfile($dir, 'log4perl.conf');
  if (!-f $file) {
    $u->msgInfo("Creating $MYNAME logging configuration file: $file");
    system("$0 --default-config-log > $file");
    $u->msgFatal("Unable to create configuration file $file") if ($? != 0);
  }
  else {
    $u->msgWarn("$MYNAME logging configuration file $file already exists, skipping.");
  }

  # create filter examples
  map {
    $file = File::Spec->catfile($dir, "filter.d", $_ . ".conf.example");
    system("$0 --filter-config $_ > $file");
  } package_drivers_get('filter');

  # create parser examples
  map {
    $file = File::Spec->catfile($dir, "parser.d", $_ . ".conf.example");
    system("$0 --parser-config $_ > $file");
  } package_drivers_get('parser');

  # create storage examples
  map {
    $file = File::Spec->catfile($dir, "storage.d", $_ . ".conf.example");
    system("$0 --storage-config $_ > $file");
  } package_drivers_get('storage');

  # create source[groups] examples
  map {
    $file = File::Spec->catfile($dir, "source.d", $_ . ".conf.example");
    system("$0 --source-config $_ > $file");
  } package_drivers_get('source');

  return 1;
}

sub config_fragment_check {
  my ($file) = @_;
  my $str = "require " . STAT_CLASS_BASE;
  eval $str;
  $u->msgFatal($@) if ($@);
  my $c = STAT_CLASS_BASE->new();
  unless ($c->confFragmentLoad($file)) {
    $u->msgFatal($c->getError());
  }
  $u->msgInfo("Config fragment ok: $file");
  exit 0;
}

sub config_fragment_write {
  my ($section, $name) = @_;

  # create object
  my $obj = obj_init($section, $name);
  unless (defined $obj) {
    $u->msgFatal($Error);
  }

  print $obj->getDefaultsAsStr();
  exit 0;
}

sub obj_init {
  my ($section, $name) = @_;
  $section = ucfirst($section);
  my $class = STAT_CLASS_BASE . '::' . $section;

  # load class
  eval "require $class";
  if ($@) { $u->msgFatal("Invalid section."); }

  # create object
  my $obj = $class->factoryNoCase($name, no_init => 1);
  unless (defined $obj) {
    $Error = "Invalid driver: $name";
  }

  return $obj;
}

sub version_print {
  my ($extended) = @_;
  $extended = 0 unless (defined $extended);
  printf("%s %-.2f\n", $MYNAME, $VERSION);
  exit 0 unless ($extended);

  print "\n";
  print $term->bold("PARSER"), ":\n";
  for my $drv (package_drivers_get('parser')) {
    my $obj = obj_init('parser', $drv);
    next unless (defined $obj);
    printf("  %-20.20s%-.2f\n", $drv, $obj->VERSION());
  }
  print "\n";

  print $term->bold("FILTER"), ":\n";
  for my $drv (package_drivers_get('filter')) {
    my $obj = obj_init('filter', $drv);
    next unless (defined $obj);
    printf("  %-20.20s%-.2f\n", $drv, $obj->VERSION());
  }
  print "\n";

  print $term->bold("SOURCE"), ":\n";
  for my $drv (package_drivers_get('source')) {
    my $obj = obj_init('source', $drv);
    next unless (defined $obj);
    printf("  %-20.20s%-.2f\n", $drv, $obj->VERSION());
  }
  print "\n";

  print $term->bold("STORAGE"), ":\n";
  for my $drv (package_drivers_get('storage')) {
    my $obj = obj_init('storage', $drv);
    next unless (defined $obj);
    printf("  %-20.20s%-.2f\n", $drv, $obj->VERSION());
  }

  exit 0;
}

sub printhelp {
  print $term->bold("Usage: "), $term->lgreen($MYNAME), " [OPTIONS]\n\n";
  print "Flexible statistics collector.\n";
  print "\n";
  print $term->bold("CONFIGURATION OPTIONS:"), "\n";
  print "        --default-config       Prints default configuration file\n";
  print "        --default-config-log   Prints default logging configuration\n";
  print "        --config-dir-init=DIR  Initialize configuration directory\n";
  print "  -C    --check-fragment=FILE  Check config fragment syntax\n";
  print "\n";
  print "  -c    --config=FILE          Specifies configuration file\n";
  print "\n";
  print $term->bold("DOCUMENTATION/INFO OPTIONS:"), "\n";
  print "         --source-list         Displays list of available storage drivers\n";
  print "         --source-doc[=NAME]   Displays source documentation\n";
  print "         --source-config=NAME  Prints configuration fragment for specified\n";
  print "                               source driver\n";
  print "\n";
  print "         --storage-list        Displays list of available storage drivers\n";
  print "         --storage-doc[=NAME]  Displays storage documentation\n";
  print "         --storage-config=NAME Prints configuration fragment for specified\n";
  print "                               storage driver\n";
  print "\n";
  print "         --storage-list        Displays list of available parser drivers\n";
  print "         --parser-doc[=NAME]   Displays parser documentation\n";
  print "         --parser-config=NAME  Prints configuration fragment for specified\n";
  print "                               parser driver\n";
  print "\n";
  print "         --storage-list        Displays list of available storage drivers\n";
  print "         --filter-doc[=NAME]   Displays filter documentation\n";
  print "         --filter-config=NAME  Prints configuration fragment for specified\n";
  print "                               filter driver\n";
  print "\n";
  print "         --raw-data            Displays RawData class documentation\n";
  print "         --parsed-data         Displays ParsedData class documentation\n";
  print "         --statcollector-doc   Displays StatCollector class documentation\n";
  print "\n";
  print $term->bold("LOGGING OPTIONS:"), "\n";
  print "  -L    --log-conf-file=FILE   Specifies log4perl logging configuration file (Default: ",
    $u->var2str($log_config_file), ")\n";
  print "                               NOTE: If configuration file directory contains file\n";
  print "                               ", $term->bold("log4perl.conf"),
    " it is automatically used as logger\n";
  print "                               configuration file.\n";
  print "\n";
  print $term->bold("OTHER OPTIONS:"), "\n";
  print "  -d    --daemon               Start as daemon (Default: ", $u->var2str($agent_daemonize,  1), ")\n";
  print "        --no-daemon            Don't daemonize (Default: ", $u->var2str(!$agent_daemonize, 1), ")\n";
  print "  -P    --pid-file             Sets daemon pid file (Default: ", $u->var2str($pid_file), ")\n";
  print "        --no-opt-loop          Don't try to find fastest available POE event loop.\n";
  print "\n";
  print "  -a    --addr                 Listen on address (Default: ",        $u->var2str($http_addr), ")\n";
  print "  -p    --port                 Listen on specified port (Default: ", $u->var2str($http_port), ")\n";
  print "\n";
  print "  -V    --version              Prints program version\n";
  print "        --extended-version     Detailed program version\n";
  print "  -h    --help                 This help message\n";
  print "\n";
  print $term->bold("SIGNALS:"), "\n";
  print "  ", $term->lgreen("INT, TERM"), "                    Terminates $MYNAME\n";
  print "  ", $term->lgreen("USR1"),      "                         Reopen log files. Hint: ",
    $term->bold("logrotate(8)"), " support.\n";
}

#########################################################################
#                                MAIN                                   #
#########################################################################

$log = $tu->loggerConfigure();
my @add_plugins = ();
my $log_config  = undef;
my $cfg_file    = undef;

# parse command line...
Getopt::Long::Configure("bundling", "permute", "bundling_override", "no_pass_through");
my $g = GetOptions(
  'default-config' => sub {
    print config_default_str();
    exit 0;
  },
  'default-config-log' => sub {
    print config_default_logging_str();
    exit 0;
  },
  'config-dir-init=s' => sub {
    config_dir_init($_[1]);
    exit 0;
  },
  'C|check-fragment=s' => sub { config_fragment_check($_[1]); },
  'c|config=s'         => sub {
    my $file = $_[1];
    $c = config_load($file);
    unless (defined $c) {
      $u->msgFatal($Error);
    }
    $cfg_file = $file;

    # hm, do we have log4perl.conf?
    my $lcfg = File::Spec->catfile(dirname($file), 'log4perl.conf');
    if (-f $lcfg && -r $lcfg && $tu->loggerConfigure($lcfg)) {
      $log_config = $lcfg;
    }
  },
  'd|daemonize!'        => \$agent_daemonize,
  'opt-loop!'           => sub { 1; },
  'L|log-config-file=s' => sub {
    unless ($tu->loggerConfigure($_[1])) {
      $u->msgFatal($tu->getError());
    }

    # is this really a file?
    $log_config = $_[1] if (-f $_[1] && -r $_[1]);
  },

  'source-list'     => sub { package_drivers('source'); },
  'source-doc:s'    => sub { perldoc('source', $_[1]); },
  'source-config=s' => sub { config_fragment_write('source', $_[1]); },

  'storage-list'     => sub { package_drivers('storage'); },
  'storage-doc:s'    => sub { perldoc('storage', $_[1]); },
  'storage-config=s' => sub { config_fragment_write('storage', $_[1]); },

  'parser-list'     => sub { package_drivers('parser'); },
  'parser-doc:s'    => sub { perldoc('parser', $_[1]); },
  'parser-config=s' => sub { config_fragment_write('parser', $_[1]); },

  'filter-list'     => sub { package_drivers('filter'); },
  'filter-doc:s'    => sub { perldoc('filter', $_[1]); },
  'filter-config=s' => sub { config_fragment_write("filter", $_[1]); },

  'raw-data'          => sub { perldoc_base(STAT_CLASS_BASE . '::RawData'); },
  'parsed-data'       => sub { perldoc_base(STAT_CLASS_BASE . '::ParsedData'); },
  'statcollector-doc' => sub { perldoc_base(STAT_CLASS_BASE); },

  'P|pid-file=s' => \$pid_file,

  'a|addr=s' => \$http_addr,
  'p|port=i' => \$http_port,

  'V|version' => sub {
    version_print();
  },
  'extended-version' => sub {
    version_print(1);
  },
  'help|h|?' => sub {
    printhelp();
    exit 0;
  },
);

unless ($g) {
  $u->msgFatal("Invalid command line options. Run $MYNAME --help for help.");
}

unless (defined $cfg_file) {
  $u->msgFatal("No configuration file was specified. Run $MYNAME --help for help.");
}

# root can't start this one
if ($> == 0) {
  $u->msgFatal("I'm unwilling to run as r00t!");
  exit 1;
}

my %opt = (installSigHandlers => 1,);

# create agent instance...
$agent = ACME::TC::Agent->new(%opt);
unless (defined $agent) {
  $u->msgFatal("Unable to create agent object: ", ACME::TC::Agent->getError());
}

# add log4perl plugin if we're configured using log4perl
# configuration file
if (defined $log_config) {

  #add watcher for this file...
  push(@add_plugins,
    {driver => "Log4perl", params => {file => $log_config, check_interval => 10, useUSR1 => 1,},});
}

# make tc configuration out of read configuration
my $agent_config = config_tcize($c);

# add other plugins
push(@{$agent_config->{plugins}}, @add_plugins);

# apply agent configuration
unless ($agent->setParams(%{$agent_config})) {
  $u->msgFatal("Unable to apply agent configuration: ", $agent->getError());
  exit 1;
}

# warn about POE event loops...
if (exists($ENV{POE_EVENT_LOOP})) {
  $u->msgInfo("Using optimized POE event loop: " . $term->bold($ENV{POE_EVENT_LOOP}));
}
else {
  $u->msgWarn("Will use default POE event loop; scaling above hundred concurrent sources is questionable.");
  $u->msgWarn(
    "Consider installing " . $term->bold("EV") . " perl module. See http://search.cpan.org/perldoc?EV");
}

# should we become a daemon?
if ($agent_daemonize) {
  my $pid = pid_read();

  # check if this pid is alive...
  if ($pid) {
    if (kill(0, $pid)) {
      $u->msgErr("$MYNAME seems to be already running as pid $pid.");
      $u->msgErr("Remove file $pid_file if this is an error.");
      exit 1;
    }
  }
  daemonize();
}

# run the goddamn agent
$log->info("Starting $MYNAME.");
$u->msgInfo("$MYNAME started as pid $$");
unless ($agent->run()) {
  pid_remove();
  $u->msgFatal($agent->getError());
}

pid_remove();
$u->msgInfo("$MYNAME stopped.");

exit 0;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
