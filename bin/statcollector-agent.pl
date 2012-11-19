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

#########################################################################
#                            GLOBAL VARIABLES                           #
#########################################################################

my $listen_addr = '*';
my $listen_port = 16660;
my $user        = undef;
my $group       = undef;

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
my $agent_daemonize = 1;
my $log_config_file = undef;

####################################################

sub agent_config_load {
  my ($file) = @_;
  my $str = "";
  if (defined $file && -f $file && -r $file) {
    my $fd = IO::File->new($file, 'r');
    unless (defined $fd) {
      $Error = "Unable to open configuration file $file: $!";
      return undef;
    }
    while (<$fd>) {
      $str .= $_;
    }
  }
  else {

    # run tc-cfg.pl to fetch our configuration...
    my $cmd = File::Spec->catfile($FindBin::RealBin, "tc-cfg.pl");
    $cmd .= " -E get Agent 2>" . File::Spec->devnull();
    $str = qx($cmd);
    my $rv = $?;

    # check for injuries...
    my $err = "Error fetching agent configuration [command: $cmd]: ";
    unless ($u->evalExitCode($rv)) {
      $Error = $err . $u->getError();
      return undef;
    }
  }

  # try to convert string to structure
  my $data = eval $str;
  if ($@) {
    $Error = "Error fetching agent configuration: $@";
    return undef;
  }
  elsif (ref($data) ne 'HASH') {
    $Error = "Error fetching agent configuration: data is not hash reference.";
    return undef;
  }

  return $data;
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
  pid_write($$);

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
        params  => {
          addr     => $listen_addr,
          port     => $listen_port,
          contexts => [{uri => '/', handler => 'ContextList', params => {},}],
        },
      },
    ],
    plugins => [
      {driver => 'Vmstat', params => {},}, {driver => 'Procinfo', params => {},},
      {driver => 'Sysstat', params => {},},

#			{
#				driver => 'AAMonitor',
#				params => {},
#			},
      {driver => 'ConnectionTracking', params => {},}, {driver => 'SocketStats', params => {},},
      {driver => 'NetworkDeviceStats', params => {},},
    ],
  };

  return $c;
}

sub version_print {
  printf("%s %-.2f\n", $MYNAME, $VERSION);
  exit 0;
}

sub printhelp {
  print $term->bold("Usage: "), $term->lgreen($MYNAME), " [OPTIONS]\n\n";
  print "Flexible operating system statistics gathering agent.\n";
  print "\n";
  print $term->bold("OPTIONS:"), "\n";
  print "  -a    --listen-addr          Specifies listening address (Default: ", $u->var2str($listen_addr),
    ")\n";
  print "  -p    --listen-port          Specifies listening port (Default: ", $u->var2str($listen_port),
    ")\n";
  print "  -u    --user                 Specifies set-uid username (Default: ",   $u->var2str($user),  ")\n";
  print "  -g    --group                 Specifies set-gid groupname (Default: ", $u->var2str($group), ")\n";

  #print "        --config=FILE          Specifies configuration file\n";
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
  print "  -V    --version              Prints program version\n";
  print "        --extended-version     Detailed program version\n";
  print "  -h    --help                 This help message\n";
  print "\n";
  print $term->bold("SIGNALS:"), "\n";
  print "  ", $term->lgreen("INT, TERM"), "                    Terminates $MYNAME\n";
  print "  ", $term->lgreen("USR1"),
    "                         Reopen log files if file-based logging is used.\n";
}

#########################################################################
#                                MAIN                                   #
#########################################################################

$log = $tu->loggerConfigure();
my $log_config = undef;

my $agent_config = conf_generate();

# parse command line...
Getopt::Long::Configure("bundling", "permute", "bundling_override", "no_pass_through");
my $g = GetOptions(
  'a|listen-addr=s' => \$listen_addr,
  'p|listen-port=i' => \$listen_port,
  'u|user=s'        => \$user,
  'g|group=s'       => \$group,
  'config=s'        => sub {
    my $file = $_[1];
    $agent_config = agent_config_load($file);
    unless (defined $agent_config) {
      $u->msgFatal($Error);
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
  'debug' => sub { $tu->loggerConfigureDebug(); },

  'V|version' => sub {
    version_print();
  },
  'help|h|?' => sub {
    printhelp();
    exit 0;
  },
);

unless ($g) {
  $u->msgFatal("Invalid command line options. Run $MYNAME --help for help.");
}

my %opt = (installSigHandlers => 1,);

my @add_plugins = ();

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

# apply listening addr/port
$agent_config->{connectors}->[0]->{params}->{addr} = $listen_addr;
$agent_config->{connectors}->[0]->{params}->{port} = $listen_port;

# add other plugins
push(@{$agent_config->{plugins}}, @add_plugins);

# apply agent configuration
unless ($agent->setParams(%{$agent_config})) {
  $u->msgFatal("Unable to apply agent configuration: ", $agent->getError());
  exit 1;
}

# try to setuid-gid...
if (defined $user) {

  # resolve uid
  my $uid = $u->getUid($user);
  unless ($uid >= 0) {
    $u->msgFatal($u->getError());
  }

  # resolve gid
  my $gid = (defined $group) ? $u->getGid($group) : $u->getUserGid($user);
  unless ($gid >= 0) {
    $u->msgFatal($u->getError());
  }

  # try to set gid
  $) = $gid;
  $u->msgFatal("Error setting gid to $uid: $!") if ($!);

  # try to set uid
  $> = $uid;
  $u->msgFatal("Error setting uid to $uid: $!") if ($!);
}

# warn about root execution...
if ($> == 0) {
  $u->msgWarn("I'm running as r00t!");
}

# warn about POE event loops...
if (exists($ENV{POE_EVENT_LOOP})) {
  $u->msgInfo("Using optimized POE event loop: " . $term->bold($ENV{POE_EVENT_LOOP}));
}
else {
  $u->msgWarn("Will use default POE event loop.");
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
