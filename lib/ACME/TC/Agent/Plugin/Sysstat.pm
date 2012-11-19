package ACME::TC::Agent::Plugin::Sysstat;


use strict;
use warnings;

use POE;
use Log::Log4perl;
use POE::Wheel::Run;

use ACME::StatQueue;
use ACME::TC::Agent::Plugin;

use base qw(ACME::TC::Agent::Plugin);

use constant QUEUE_CAPACITY => 60;

use constant MAX_RUNS    => 10;
use constant RUN_TIMEOUT => 6;

use constant CTX_DEFAULT => "/info/sysstat";
use constant TYPE_MPSTAT => 'mpstat';
use constant TYPE_IOSTAT => 'iostat';

our $VERSION = 0.11;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::Sysstat

tc vmstat plugin. This plugin invokes mpstat(1) and iostat(1) on startup and reads their output.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my %opt = (
	);
	my $poe_session_id = $agent->pluginInit("Sysstat", %opt);

B<Initialization via tc configuration>:

	{
		driver => 'Sysstat',
		params => {
		},
	},

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=over

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 METHODS

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # "public" settings

  # path to vmstat program
  $self->{mpstat} = $self->_which("mpstat");
  $self->{iostat} = $self->_which("iostat");

  # context path
  $self->{contextPath} = CTX_DEFAULT;

  # private settings
  $self->{_wheel} = {};    # POE::Wheel::Run wheel object...

  # wheel-id => type dictionary
  $self->{_w2t} = {};

  # program versions...
  $self->{_verMpstat} = 0;
  $self->{_verIostat} = 0;

  # register our events...
  $self->registerEvent(
    qw(
      iostatRun
      mpstatRun
      dataGet
      dataReset
      _sighCHLD
      _evClose
      _evError
      _evStderr
      _evStdin
      _evStdout
      )
  );

  $self->_dataReset();

  return 1;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $self->{_error} = "";

  unless (defined $self->{mpstat} && -x $self->{mpstat}) {
    $_log->error("Invalid mpstat binary: '$self->{mpstat}'");
    return $kernel->yield('shutdown');
  }

  unless (defined $self->{iostat} && -x $self->{iostat}) {
    $_log->error("Invalid iostat binary: '$self->{iostat}'");
    return $kernel->yield('shutdown');
  }

  # try to mount context_path on all agent connectors
  if (defined $self->{contextPath}) {
    $_log->debug("Mounting connector context: $self->{contextPath}'");
    my $r = $self->agentCall(
      'connectorMountContext',
      {
        uri     => $self->{contextPath},
        handler => __PACKAGE__ . "::WebHandler",
        args    => {session => $self->getSessionId()},
      }
    );

    unless ($r) {
      $_log->error("Error mounting context on agent's connectors: " . $self->agentError());
      $kernel->yield('shutdown');
    }
  }

  # check sysstat versions...
  unless ($self->_sysstatReport()) {
    return $kernel->yield('shutdown');
  }

  # let's get to the point...
  $kernel->yield("mpstatRun");
  $kernel->yield("iostatRun");
  return 1;
}

=item dataGet ()

This B<POE> method will return hash reference containing gathered data.

Example:

	my $data = $_[KERNEL]->call("session_name", "dataGet");

=cut

sub dataGet {
  my ($self, $kernel, $sender) = @_[OBJECT, KERNEL, SENDER];

  # copy internal structure
  my $data = {};
  for my $sec (keys %{$self->{_data}}) {
    for my $k (keys %{$self->{_data}->{$sec}}) {
      foreach my $s (keys %{$self->{_data}->{$sec}->{$k}}) {
        my $key = $sec . '.' . $k . '.' . $s;
        $data->{$key} = $self->{_data}->{$sec}->{$k}->{$s}->clone();
      }
    }
  }

  return $data;
}

=item dataReset ()

This B<POE> method resets internal data structure, erasing all gathered data.

=cut

sub dataReset {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  return $self->_dataReset();
}

sub mpstatRun {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  return $self->_wheelCreate(TYPE_MPSTAT);
}

sub iostatRun {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  return $self->_wheelCreate(TYPE_IOSTAT);
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _sysstatReport {
  my ($self) = @_;

  foreach my $type (TYPE_IOSTAT, TYPE_MPSTAT) {
    my $bin = $self->{$type};
    unless (defined $bin) {
      $_log->error("Undefined binary for " . $type);
      return 0;
    }

    # run command
    my $out = `$self->{$type} -V 2>&1`;
    unless (defined $out) {
      $_log->error("No version output for $type");
      return 0;
    }

    # parse version..
    my (undef, undef, $ver) = split(/\s+/, $out);
    unless (defined $ver && length($ver) > 0) {
      $_log->error("Unable to parse program $type version.");
      return 0;
    }

    $_log->info("Using $type version: $ver");

    # save version
    $ver =~ s/\.//g;
    $self->{'_ver' . ucfirst($type)} = $ver;
  }

  return 1;
}

sub _shutdown {
  my $self = shift;

  # set stopping flag...
  $self->{_stopping} = 1;

  # umount our handler from connector...
  if (defined $self->{contextPath}) {
    $_log->debug("Unmounting connector context: $self->{contextPath}'");
    my $agent = $self->getAgent();
    if (defined $agent) {
      unless ($agent->connectorUmountContext($self->{contextPath})) {
        $_log->error("Error mounting context on agent's connectors: " . $agent->getError());
      }
    }
    else {
      $_log->error("Error retrieving agent object: " . $self->{_error});
    }
  }

  # kill processes...
  foreach my $wid (keys %{$self->{_wheel}}) {
    my $s = $self->{_wheel}->{$wid};
    next unless (defined $s);

    my $pid = $s->PID();

    # stop running processes...
    if (defined $pid && kill(0, $pid)) {
      $_log->debug("Killing process pid $pid.");
      unless (kill(15, $pid)) {
        $_log->error("Unable to send SIGTERM to process $pid: $!");
      }
    }

    # destroy the wheel
    delete($self->{_wheel}->{$wid});
  }

  return 1;
}


sub _evStdin {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $self->{_wheel}->shutdown_stdin();
}

sub _evStdout {
  my ($self, $line, $wid) = @_[OBJECT, ARG0, ARG1];
  return 0 unless (exists($self->{_w2t}->{$wid}));

  # sanitize string...
  return 0 unless (defined $line);
  $line =~ s/^\s+//g;
  $line =~ s/\s+$//g;
  return 0 unless (length($line) > 0);

  $_log->trace("STDOUT from wheel $wid: $line");


  # choose parsing method...
  if ($self->{_w2t}->{$wid} eq TYPE_MPSTAT) {
    $self->_parseMpstat($line);
  }
  elsif ($self->{_w2t}->{$wid} eq TYPE_IOSTAT) {
    $self->_parseIoStat($line);
  }
}

sub _evStderr {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG1];
  return 0 unless (exists($self->{_wheel}->{$wid}));
  my $type = $self->{_w2t}->{$wid};
  return 0 unless (defined $type);
  $_log->warn("Program $type STDERR output: ", $_[ARG0]);
}

sub _evError {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # $_log->error("I/O Error accoured: ", $_[ARG0]);
}

sub _evClose {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  return 0 unless (exists($self->{_wheel}->{$wid}));

  # restart vmstat process if this plugin is
  # not stopping...
  unless ($self->{_stopping}) {
    my $type = $self->{_w2t}->{$wid};
    $_log->warn("Process $type [$self->{$type}] closed.");
    $kernel->delay($type . 'Run', 2);
  }

  # destroy the wheel
  delete($self->{_wheel}->{$wid});

  # destroy wid2type struct...
  delete($self->{_w2t}->{$wid});

  return 1;
}

sub _sighCHLD {
  my ($self, $kernel, $signame, $pid, $r) = @_[OBJECT, KERNEL, ARG0 .. ARG2];
  my $exit_st = $r >> 8;

  if ($exit_st != 0) {
    my $exit_sig = $r & 127;
    my $core     = $r & 128;
    $_log->warn(
      "Got SIG$signame. Reaping process pid $pid terminated by signal $exit_sig "
        . ($core ? "with" : "without"),
      " coredump."
    );
  }

  # this signal was handled...
  return $kernel->sig_handled();
}

sub _dataReset {
  my ($self, $type) = @_;

  if (defined $type) {
    if (exists($self->{_data}->{$type})) {
      $self->{_data}->{$type} = {};
    }
  }
  else {
    $self->{_data} = {cpu => {}, io => {},};
  }

  return 1;
}

sub _wheelCreate {
  my ($self, $type) = @_;
  $type = 'mpstat' unless (defined $type);
  return 0 unless (exists($self->{$type}));

  # check for stuff...
  unless (defined $self->{$type} && -f $self->{$type} && -x $self->{$type}) {
    no warnings;
    $_log->error("Invalid $type(1) binary: '" . $self->{$type} . "'");
    return $poe_kernel->yield('shutdown');
  }

  $self->_dataReset($type);

  my $prog = $self->{$type};
  if ($type eq 'mpstat') {
    $prog .= " -u -I SUM -P ALL  1";
  }
  elsif ($type eq 'iostat') {
    if ($self->{_verIostat} >= 900) {
      $prog .= " -d -k -x -p ALL 1";
    }
    elsif ($self->{_verIostat} > 800) {
      $prog .= " -d -k -x 1";
    }
  }

  # untie standard streams if they're tied...
  untie *STDOUT if (tied *STDOUT);
  untie *STDERR if (tied *STDERR);

  # create run wheel...
  $_log->debug("Starting program: '$prog '");
  my $wheel = undef;
  eval {
    $wheel = POE::Wheel::Run->new(
      Program     => $prog,
      StdinEvent  => '_evStdin',     # Flushed all data to the child's STDIN.
      StdoutEvent => '_evStdout',    # Received data from the child's STDOUT.
      StderrEvent => '_evStderr',    # Received data from the child's STDERR.
      ErrorEvent  => '_evError',     # An I/O error occurred.
      CloseEvent  => '_evClose',     # Child closed all output handles.
    );
  };

  # check for injuries...
  if ($@) {
    $_log->error("Error running '$prog': $@");
    $poe_kernel->yield('shutdown');
  }
  elsif (!defined $wheel) {
    $_log->error($self->{error});
    $poe_kernel->yield('shutdown');
  }

  # get wheel id...
  my $wid = $wheel->ID();

  # get pid
  my $pid = $wheel->PID();
  $_log->info("Program $type invoked as pid $pid.");

  # create sigchld handler
  $poe_kernel->sig_child($pid, "_sighCHLD");

  # save the wheel
  $self->{_wheel}->{$wid} = $wheel;

  $self->{_w2t}->{$wid} = $type;

  # wow, we made it...
  return 1;
}

sub _parseMpstat {
  my ($self, $str) = @_;
  return 0 unless (defined $str);
  return 1 if ($str =~ m/\)/);

  # remove date... (this is done this way becouse of different output in different versions of mpstat)
  #print "STR BEFORE: '$str'\n";
  $str =~ s/^\s*(?:[0-9:]+)\s+//g;
  $str =~ s/^(?:A|P)M\s+//g;

  #print "STR AFTER: '$str'\n";

  # split string...
  my @tmp = split(/\s+/, $str);
  return 0 unless (@tmp);

  # header line?
  my $cpu = shift(@tmp);
  return 0 if ($cpu eq 'CPU');

  # do we have struct for this cpu?
  my $cpus = $self->{_data}->{cpu};
  unless (exists($cpus->{$cpu})) {
    $cpus->{$cpu} = {
      usr    => ACME::StatQueue->new(QUEUE_CAPACITY),
      nice   => ACME::StatQueue->new(QUEUE_CAPACITY),
      sys    => ACME::StatQueue->new(QUEUE_CAPACITY),
      iowait => ACME::StatQueue->new(QUEUE_CAPACITY),
      irq    => ACME::StatQueue->new(QUEUE_CAPACITY),
      soft   => ACME::StatQueue->new(QUEUE_CAPACITY),
      steal  => ACME::StatQueue->new(QUEUE_CAPACITY),
      guest  => ACME::StatQueue->new(QUEUE_CAPACITY),
      idle   => ACME::StatQueue->new(QUEUE_CAPACITY),
      intr   => ACME::StatQueue->new(QUEUE_CAPACITY),
    };
  }

  my $c = $cpus->{$cpu};

#01:22:10 AM  CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest   %idle
#01:22:11 AM  all    8.29    0.00    5.37    0.00    0.00    0.00    0.00    0.00   86.34
#01:22:11 AM    0   10.00    0.00    7.00    0.00    0.00    0.00    0.00    0.00   83.00
#01:22:11 AM    1    7.48    0.00    3.74    0.00    0.00    0.00    0.00    0.00   88.79

  # cpu utilization?
  if ($#tmp == 8) {
    my ($usr, $nice, $sys, $iowait, $irq, $soft, $steal, $guest, $idle) = @tmp;

    #$_log->debug("CPU $tmp[0] usr $tmp[1]");
    #print "CPU: $cpu: $usr\n";
    $c->{usr}->add($usr);
    $c->{nice}->add($nice);
    $c->{sys}->add($sys);
    $c->{iowait}->add($iowait);
    $c->{irq}->add($irq);
    $c->{soft}->add($soft);
    $c->{steal}->add($steal);
    $c->{guest}->add($guest);
    $c->{idle}->add($idle);
  }

#01:22:10 AM  CPU    intr/s
#01:22:11 AM  all   1630.00
#01:22:11 AM    0    782.00
#01:22:11 AM    1     20.00

  # cpu irq?
  elsif ($#tmp == 0) {
    $c->{intr}->add($tmp[0]);
  }

  return 1;
}

sub _parseIoStat {
  my ($self, $str) = @_;
  return 0 unless (defined $str);

  # skip header
  return 1 if ($str =~ m/^device:\s+/i);

  # skip non-relevant devices...
  return 1 if ($str =~ m/^(?:loop|ram|scd|sr)\d+\s+/);

# Device:         rrqm/s   wrqm/s     r/s     w/s    rkB/s    wkB/s avgrq-sz avgqu-sz   await  svctm  %util
# sda               0.00    16.00    0.00    6.00     0.00    80.00    26.67     0.12   19.67  12.50   7.50
# sda1              0.00     0.00    0.00    0.00     0.00     0.00     0.00     0.00    0.00   0.00   0.00
# sda2              0.00    16.00    0.00    4.00     0.00    80.00    40.00     0.09   21.75  11.00   4.40
# dm-0              0.00     0.00    0.00   22.00     0.00    80.00     7.27     0.82   37.36   3.45   7.60

  # split string...
  my @tmp = split(/\s+/, $str);
  return 0 if ($#tmp != 11);

  my ($dev, $rrqm, $wrqm, $r, $w, $rkb, $wkb, $avgrqsz, $avgqusz, $await, $svctm, $util) = @tmp;

  # do we have struct for this?
  my $io = $self->{_data}->{io};
  unless (exists($io->{$dev})) {
    $io->{$dev} = {
      rrqm    => ACME::StatQueue->new(QUEUE_CAPACITY),
      wrqm    => ACME::StatQueue->new(QUEUE_CAPACITY),
      r       => ACME::StatQueue->new(QUEUE_CAPACITY),
      w       => ACME::StatQueue->new(QUEUE_CAPACITY),
      rkb     => ACME::StatQueue->new(QUEUE_CAPACITY),
      wkb     => ACME::StatQueue->new(QUEUE_CAPACITY),
      avgrqsz => ACME::StatQueue->new(QUEUE_CAPACITY),
      avgqusz => ACME::StatQueue->new(QUEUE_CAPACITY),
      await   => ACME::StatQueue->new(QUEUE_CAPACITY),
      svctm   => ACME::StatQueue->new(QUEUE_CAPACITY),
      util    => ACME::StatQueue->new(QUEUE_CAPACITY),
    };
  }

  # apply values...
  my $s = $io->{$dev};
  $s->{rrqm}->add($rrqm);
  $s->{wrqm}->add($wrqm);
  $s->{r}->add($r);
  $s->{w}->add($w);
  $s->{rkb}->add($rkb);
  $s->{wkb}->add($wkb);
  $s->{avgrqsz}->add($avgrqsz);
  $s->{avgqusz}->add($avgqusz);
  $s->{await}->add($await);
  $s->{svctm}->add($svctm);
  $s->{util}->add($util);

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::Sysstat::WebHandler>
L<ACME::TC::Agent::Plugin>
L<ACME::TC::Agent>
L<POE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
