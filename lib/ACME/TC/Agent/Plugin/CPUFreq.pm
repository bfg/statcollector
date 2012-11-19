package ACME::TC::Agent::Plugin::CPUFreq;


use strict;
use warnings;

use POE;
use Time::HiRes;
use Log::Log4perl;
use POE::Wheel::Run;

use ACME::TC::Agent::Plugin;
use POE::Component::Server::HTTPEngine;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin);

# operate mode...
use constant OP_AVG_VAL  => 1;
use constant OP_LAST_VAL => 2;
use constant OP_MAX_VAL  => 3;

our $VERSION = 0.04;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::CPUFreq

CPU frequency usage tracker plugin for tc agent. Requires working cpufreq-info(1) binary.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my %opt = (
		check_interval => 2,
	);
	my $poe_session_id = $agent->pluginInit("CPUFreq", %opt);

B<Initialization via tc configuration>:

	{
		driver => 'CPUFreq',
		params => {
			check_interval => 2,
		},
	},


=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=item B<program> (string, <auto-generated>):

Full path to cpufreq-info(1) binary if you want to use different one found in $PATH.

=item B<mode> (string, "1"):

Value calculation mode. Possible values:

B<OP_AVG_VAL|'avg'|1>: calculate average values.

B<OP_MAX_VAL|'max'|2>: report maximum detected values.

B<OP_LAST_VAL|'last'|3>: report last read values.

=item B<check_interval> (integer, 1):

CPU frequency polling interval. 

=item B<context_path> (string, "/info/cpufreq"):

Connector context path.

=over

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = $class->SUPER::new(@_);

  ##################################################
  #              PUBLIC PROPERTIES                 #
  ##################################################

  ##################################################
  #              PRIVATE PROPERTIES                #
  ##################################################

  # exposed POE object events
  $self->registerEvent(
    qw(
      dataGet
      dataReset
      _cpuFreqRun
      _evtStdout
      _evtStderr
      _evtError
      _evtClose
      _sigh_CHLD
      )
  );

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);

  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 METHODS

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # "public" settings

  # path to program binary...
  $self->{program} = $self->_which("cpufreq-info");

  $self->{mode} = OP_AVG_VAL;

  # interval
  $self->{check_interval} = 1;

  # context path
  $self->{context_path} = "/info/cpufreq";

  # private settings
  $self->{_run_last_time} = 0;
  $self->{_run_count}     = 0;

  return 1;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->info("Plugin '" . $self->_getBasePackage() . "' startup.");

  # install ourselves...
  my $agent = $self->getAgent();
  if (defined $agent) {
    $agent->connectorMountContext(
      uri     => $self->{context_path},
      handler => 'ACME::TC::Agent::Plugin::ConnectorWebHandler::DataInfo',
      args    => {session => $self->{_poe_session}, prefix => "cpufreq",},
    );
  }
  else {
    $_log->error("Error mounting context: " . $self->{_error});
  }

  # check compute mode...
  unless ($self->{mode} =~ m/^\d+$/) {
    if ($self->{mode} =~ m/avg/i) {
      $self->{mode} = OP_AVG_VAL;
    }
    elsif ($self->{mode} =~ m/max/i) {
      $self->{mode} = OP_MAX_VAL;
    }
    elsif ($self->{mode} =~ m/last/i) {
      $self->{mode} = OP_LAST_VAL;
    }
    else {
      $_log->warn("Invalid compute mode '$self->{mode}'; falling back to 'avg'.");
      $self->{mode} = OP_AVG_VAL;
    }
  }

  # let's get to the point...
  $kernel->yield("_cpuFreqRun");

  return 1;
}

=item dataGet () [POE]

Returns hash reference containing gathered data.

Example:

	my $data = $_[KERNEL]->call("session_name", "dataGet");

=cut

sub dataGet {
  my ($self, $kernel, $sender) = @_[OBJECT, KERNEL, SENDER];

  # copy internal structure
  my $data = {};
  map { $data->{$_} = $self->{_data}->{$_}; } keys %{$self->{_data}};

  # compute stats...
  map {
    if ($self->{_data_reads} > 0)
    {
      $data->{$_} /= $self->{_data_reads};
    }
    else {
      $data->{$_} = 0;
    }
  } keys %{$data};

  $data->{__queue_len} = $self->{_data_reads};

  return $data;
}

=item dataReset () [POE]

Resets internal data structure, erasing all gathered data. Always returns 1.

=cut

sub dataReset {
  my ($self, $kernel, $sender) = @_[OBJECT, KERNEL, SENDER];

  # reset data
  $self->_dataReset();
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _shutdown {
  my $self = shift;

  # set stopping flag...
  $self->{_stopping} = 1;

  # do we have have our own webserver?
  if (defined $self->{_httpd}) {
    $_log->info("Stopping our own HTTP server.");

    # this doesn't work... weird...
    # $self->{_httpd}->shutdown();
    # this one does... weird...
    $poe_kernel->call($self->{_httpd}->getSessionId(), "shutdown");
    delete($self->{_httpd});
  }

  # kill the process (if any)...
  my $pid = $self->{_pid};
  if ($pid) {
    $_log->debug("Stopping process pid $pid.");
    unless (kill(15, $pid)) {
      $_log->error("Unable to send SIGTERM to process $pid: $!");
    }
  }

  if (defined $self->{_wheel}) {
    $_log->debug("Wheel doesn't exist; that's okay anyway...");
    delete($self->{_wheel});
    return 1;
  }

  # destroy the wheel...
  # delete($self->{_wheel});

  return 1;
}

sub _cpuFreqRun {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # if we should die...
  if ($self->{_stopping}) {
    delete($self->{_wheel});
    return 1;
  }

  # check for correct binary...
  unless (defined $self->{program}) {
    $self->{_error} = "Undefined cpufreq-info binary.";
    return 0;
  }
  unless (-f $self->{program} && -x $self->{program}) {
    $self->{_error} = "Invalid program binary: '$self->{program}'";
    return 0;
  }

  my $prog = $self->{program};
  my @args = qw(-f);

  # untie standard streams if they're tied...
  untie *STDOUT if (tied *STDOUT);
  untie *STDERR if (tied *STDERR);

  # create run wheel...
  $_log->debug("Starting program: '$prog " . join(" ", @args) . "'");
  $self->{_wheel} = POE::Wheel::Run->new(
    Program     => $prog,
    ProgramArgs => \@args,
    StdinEvent  => '_evtStdin',     # Flushed all data to the child's STDIN.
    StdoutEvent => '_evtStdout',    # Received data from the child's STDOUT.
    StderrEvent => '_evtStderr',    # Received data from the child's STDERR.
    ErrorEvent  => '_evtError',     # An I/O error occurred.
    CloseEvent  => '_evtClose',     # Child closed all output handles.
  );

  unless (defined $self->{_wheel}) {
    $self->{_error} = "Unable to create POE wheel: $!";
    $_log->error($self->{error});
    return 0;
  }

  $self->{_last_run_time} = Time::HiRes::time();

  # save pid
  $self->{_pid} = $self->{_wheel}->PID();

  # create sigchld handler
  $kernel->sig_child($self->{_pid}, "_sigh_CHLD");

  # wow, we made it...
  return 1;
}

sub _evtStdin {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $self->{_wheel}->shutdown_stdin();
}

sub _evtStdout {
  my ($self, $str) = @_[OBJECT, ARG0];

  # sanitize string...
  $str =~ s/^\s+//g;
  $str =~ s/\s+$//g;

  my $freq = 0;
  {
    no warnings;
    $freq = int($str);
  }

  # should we compute average?
  if ($self->{mode} == OP_AVG_VAL) {
    $self->{_data}->{freq} += $freq;

    # we read one more line... ;)
    $self->{_data_reads}++;
  }

  # should we check for maximum values?
  elsif ($self->{mode} == OP_MAX_VAL) {
    $self->{_data}->{freq} = $freq if ($self->{_data}->{freq} < $freq);

    # we read only one line - this disables avg value computation
    $self->{_data_reads} = 1;
  }

  # should we only set last value?
  elsif ($self->{mode} == OP_LAST_VAL) {
    $self->{_data}->{freq} = $freq;

    # we read only one line - this disables avg value computation
    $self->{_data_reads} = 1;
  }

  # everything else is bug
  else {
    $_log->error("Invalid operate mode: '$self->{mode}', ignoring program input.");
  }

  # this is it...
  return 1;
}

sub _evtStderr {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->warn("Program STDERR output: ", $_[ARG0]);
}

sub _evtError {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # $_log->error("I/O Error accoured: ", $_[ARG0]);
}

sub _evtClose {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # destroy the wheel
  $self->{_wheel} = undef;
  $self->{_pid}   = undef;

  # compute next execution delay...
  my $exec_duration = Time::HiRes::time() - $self->{_last_run_time};
  my $delay         = $self->{check_interval} - $exec_duration;
  if ($_log->is_debug()) {
    $_log->debug("Program execution finished in "
        . sprintf("%-.3f ms", ($exec_duration * 1000))
        . "; scheduling next program invocation in "
        . sprintf("%-.3f ms.", ($delay * 1000)));
  }

  # schedule next execution
  $kernel->delay_add("_cpuFreqRun", $delay);

  return 1;
}

sub _sigh_CHLD {
  my ($self, $kernel, $signame, $pid, $r) = @_[OBJECT, KERNEL, ARG0 .. ARG2];
  my $exit_st  = $r >> 8;
  my $exit_sig = $r & 127;
  my $core     = $r & 128;

  if ($exit_st != 0) {
    $_log->warn(
      "Got SIG$signame. Reaping process pid $pid terminated by signal $exit_sig "
        . ($core ? "with" : "without"),
      " coredump."
    );
  }

  # this signal was handled...
  $kernel->sig_handled();
}

sub _dataReset {
  my ($self) = @_;

  $self->{_data_reads} = 0;
  $self->{_data} = {freq => 0,};

  return 1;
}

sub _checkConfiguration {
  my ($self) = @_;

  # check calculation mode
  my $m = $self->{mode};
  unless (defined $m) {
    $self->{_error} = "Undefined configuration property: 'mode'.";
    return 0;
  }
  if ($m eq OP_AVG_VAL && $m eq OP_MAX_VAL && $m eq OP_LAST_VAL) {
    $self->{_error} = "Invalid configuration property 'mode': '$m'.";
    return 0;
  }

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Plugin>
L<POE::Component::Server::HTTPEngine>
L<POE::Component::Server::HTTPEngine::Handler>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
