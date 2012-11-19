package ACME::TC::Agent::Plugin::Vmstat;


use strict;
use warnings;

use POE;
use Log::Log4perl;
use POE::Wheel::Run;

use ACME::StatQueue;
use ACME::TC::Agent::Plugin;
use POE::Component::Server::HTTPEngine;

use base qw(ACME::TC::Agent::Plugin);

use constant QUEUE_CAPACITY => 60;
use constant MAX_RUNS       => 10;
use constant RUN_TIMEOUT    => 6;
use constant CTX_DEFAULT    => "/info/vmstat";

our $VERSION = 0.15;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::Vmstat

tc vmstat plugin. This plugin invokes vmstat(8) on startup and reads it's output.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my %opt = (
	);
	my $poe_session_id = $agent->pluginInit("Vmstat", %opt);

B<Initialization via tc configuration>:

	{
		driver => 'Vmstat',
		params => {
		},
	},

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=item B<vmstat> (string, <automatically determined from $PATH>)

Full path to vmstat(8) binary. Vmstat binary will be searched in $PATH if this option is omitted.

=item B<vmstat_args> (string, "1"):

Vmstat(8) binary command line options. Don't set this option unless you really know what you're doing.

=item B<context_path> (string, "/info/vmstat")

tc agent connector URI context path. If undef, connector URI will not be mounted.

=over

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
  $self->{vmstat} = $self->_which("vmstat");

  # vmstat args
  $self->{vmstat_args} = "1";

  # context path
  $self->{context_path} = CTX_DEFAULT;

  # private settings
  $self->{_run_last_time} = 0;        # last time we've started vmstat
  $self->{_run_count}     = 0;        # vmstat run count ... :)
  $self->{_stopping}      = 0;        # we're not stopping...
  $self->{_wheel}         = undef;    # POE::Wheel::Run wheel object...

  # register our events...
  $self->registerEvent(qw(_vmstatRun _evClose _evError _evStderr _evStdout _sigh_CHLD dataGet dataReset));

  $self->_dataReset();

  return 1;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $self->{_error} = "";

  # try to mount context_path on all agent connectors
  if (defined $self->{context_path}) {
    $_log->debug("Mounting connector context: $self->{context_path}'");
    my $r = $self->agentCall(
      'connectorMountContext',
      {
        uri     => $self->{context_path},
        handler => __PACKAGE__ . "::WebHandler",
        args    => {session => $self->getSessionId()},
      }
    );

    unless ($r) {
      $_log->error("Error mounting context on agent's connectors: " . $self->agentError());
    }
  }

  # let's get to the point...
  $kernel->yield("_vmstatRun");
  return 1;
}

=item dataGet ()

This B<POE> method will return hash reference containing gathered data.

Example:

	my $data = $_[KERNEL]->call("session_name", "dataGet");

=cut

sub dataGet : State {
  my ($self, $kernel, $sender) = @_[OBJECT, KERNEL, SENDER];

  # copy internal structure
  my $data = {};
  map { $data->{$_} = $self->{_data}->{$_}->clone(); } keys %{$self->{_data}};

  return $data;
}

=item dataReset ()

This B<POE> method resets internal data structure, erasing all gathered data.

=cut

sub dataReset : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # reset data
  $self->_dataReset();
  return 1;
}

sub _shutdown {
  my $self = shift;

  # set stopping flag...
  $self->{_stopping} = 1;

  # umount our handler from connector...
  if (defined $self->{context_path}) {
    $_log->debug("Unmounting connector context: $self->{context_path}'");
    my $agent = $self->getAgent();
    if (defined $agent) {
      unless ($agent->connectorUmountContext($self->{context_path})) {
        $_log->error("Error mounting context on agent's connectors: " . $agent->getError());
      }
    }
    else {
      $_log->error("Error retrieving agent object: " . $self->{_error});
    }
  }

  # stop vmstat process...
  if (exists($self->{_wheel}) && defined $self->{_wheel}) {

    # get pid
    my $pid = undef;
    eval { $pid = $self->{_wheel}->PID(); };

    # kill possibly running process...
    if (defined $pid) {
      $_log->debug("Stopping process pid $pid.");
      unless (kill(15, $pid)) {
        $_log->error("Unable to send SIGTERM to process $pid: $!");
      }
    }

    # destroy the wheel
    delete($self->{_wheel});
    $self->{_wheel} = undef;
  }

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _vmstatRun : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # if we should die...
  if ($self->{_stopping}) {
    delete($self->{_wheel});
    $self->{_wheel} = undef;
    return 1;
  }

  # check for bad invocations
  if ($self->{_run_count} > MAX_RUNS) {
    if (($self->{_run_last_time} + RUN_TIMEOUT) > time()) {

      # this is bad', i'm not doing this anymode
      $self->{_wheel} = undef;
      $_log->error("Program vmstat died to many times ($self->{_run_count}) in to short time (",
        RUN_TIMEOUT, " second(s)).");
      $kernel->yield('shutdown');
      return 0;
    }
  }

  $self->{_run_count}++;
  $self->{_run_last_time} = time();

  # reset the data structure...
  $self->_dataReset();

  # check for stuff...
  unless (defined $self->{vmstat}) {
    $self->{_error} = "Undefined vmstat binary.";
    return 0;
  }
  unless (-f $self->{vmstat} && -x $self->{vmstat}) {
    $self->{_error} = "Invalid vmstat binary: '$self->{vmstat}'";
    return 0;
  }

  my $prog = $self->{vmstat};
  my @args = split(/\s+/, $self->{vmstat_args});

  # untie standard streams if they're tied...
  untie *STDOUT if (tied *STDOUT);
  untie *STDERR if (tied *STDERR);

  # create run wheel...
  $_log->debug("Starting vmstat: '$prog " . join(" ", @args) . "'");
  $self->{_wheel} = POE::Wheel::Run->new(
    Program     => $prog,
    ProgramArgs => \@args,
    StdinEvent  => '_evStdin',     # Flushed all data to the child's STDIN.
    StdoutEvent => '_evStdout',    # Received data from the child's STDOUT.
    StderrEvent => '_evStderr',    # Received data from the child's STDERR.
    ErrorEvent  => '_evError',     # An I/O error occurred.
    CloseEvent  => '_evClose',     # Child closed all output handles.
  );

  unless (defined $self->{_wheel}) {
    $self->{_error} = "Unable to create POE wheel: $!";
    $_log->error($self->{error});
    return 0;
  }

  # get pid
  my $pid = $self->{_wheel}->PID();
  $_log->info("Vmstat process invoked as pid $pid.");

  # create sigchld handler
  $kernel->sig_child($pid, "_sigh_CHLD");

  # wow, we made it...
  return 1;
}

sub _evStdin : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $self->{_wheel}->shutdown_stdin();
}

sub _evStdout : State {
  my ($self, $str) = @_[OBJECT, ARG0];

  # sanitize string...
  $str =~ s/^\s+//g;
  $str =~ s/\s+$//g;

  # parse the goddamn line...
  return 1 unless ($str =~ m/^\d+/);
  my (
    $procs_r, $procs_b, $mem_swpd,  $mem_free,  $mem_buff, $mem_cache, $swap_si, $swap_so,
    $io_bi,   $io_bo,   $system_in, $system_cs, $cpu_us,   $cpu_sy,    $cpu_id,  $cpu_wa
  ) = split(/\s+/, $str);

  # add values...
  $self->{_data}->{procs_r}->add($procs_r);
  $self->{_data}->{procs_b}->add($procs_b);
  $self->{_data}->{mem_swpd}->add($mem_swpd);
  $self->{_data}->{mem_free}->add($mem_free);
  $self->{_data}->{mem_buff}->add($mem_buff);
  $self->{_data}->{mem_cache}->add($mem_cache);
  $self->{_data}->{swap_si}->add($swap_si);
  $self->{_data}->{swap_so}->add($swap_so);
  $self->{_data}->{io_bi}->add($io_bi);
  $self->{_data}->{io_bo}->add($io_bo);
  $self->{_data}->{system_in}->add($system_in);
  $self->{_data}->{system_cs}->add($system_cs);
  $self->{_data}->{cpu_us}->add($cpu_us);
  $self->{_data}->{cpu_sy}->add($cpu_sy);
  $self->{_data}->{cpu_id}->add($cpu_id);
  $self->{_data}->{cpu_wa}->add($cpu_wa);

  # this is it...
  return 1;
}

sub _evStderr : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->warn("Program STDERR output: ", $_[ARG0]);
}

sub _evError : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # $_log->error("I/O Error accoured: ", $_[ARG0]);
}

sub _evClose : State {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # destroy the wheel
  $self->{_wheel} = undef;

  # restart vmstat process if this plugin is
  # not stopping...
  unless ($self->{_stopping}) {
    $_log->warn("Vmstat program '$self->{vmstat}' closed.") if (defined $_log);
    $kernel->yield("_vmstatRun");
  }

  return 1;
}

sub _sigh_CHLD : State {
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
  my ($self) = @_;

  # $self->{_data_reads} = 0;
  $self->{_data} = {
    procs_r   => ACME::StatQueue->new(QUEUE_CAPACITY),
    procs_b   => ACME::StatQueue->new(QUEUE_CAPACITY),
    mem_swpd  => ACME::StatQueue->new(QUEUE_CAPACITY),
    mem_free  => ACME::StatQueue->new(QUEUE_CAPACITY),
    mem_buff  => ACME::StatQueue->new(QUEUE_CAPACITY),
    mem_cache => ACME::StatQueue->new(QUEUE_CAPACITY),
    swap_si   => ACME::StatQueue->new(QUEUE_CAPACITY),
    swap_so   => ACME::StatQueue->new(QUEUE_CAPACITY),
    io_bi     => ACME::StatQueue->new(QUEUE_CAPACITY),
    io_bo     => ACME::StatQueue->new(QUEUE_CAPACITY),
    system_in => ACME::StatQueue->new(QUEUE_CAPACITY),
    system_cs => ACME::StatQueue->new(QUEUE_CAPACITY),
    cpu_us    => ACME::StatQueue->new(QUEUE_CAPACITY),
    cpu_sy    => ACME::StatQueue->new(QUEUE_CAPACITY),
    cpu_id    => ACME::StatQueue->new(QUEUE_CAPACITY),
    cpu_wa    => ACME::StatQueue->new(QUEUE_CAPACITY),
  };

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::Vmstat::VmstatHandler>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Plugin>
L<POE::Component::Server::HTTPEngine>
L<POE::Component::Server::HTTPEngine::Handler>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
