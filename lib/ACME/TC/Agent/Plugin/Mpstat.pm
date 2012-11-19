package ACME::TC::Agent::Plugin::Mpstat;


use strict;
use warnings;

use POE;
use Log::Log4perl;
use POE::Wheel::Run;

use ACME::StatQueue;
use ACME::TC::Agent::Plugin;
use POE::Component::Server::HTTPEngine;

use base qw(ACME::TC::Agent::Plugin);

use constant QUEUE_CAPACITY => 15;
use constant MAX_RUNS       => 10;
use constant RUN_TIMEOUT    => 6;
use constant CTX_DEFAULT    => "/info/mpstat";

our $VERSION = 0.01;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::Mpstat

tc mpstat plugin. This plugin invokes mpstat(8) on startup and reads it's output.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my %opt = (
		httpd_start => 1,
		httpd_port => 10004,
	);
	my $poe_session_id = $agent->pluginInit("Mpstat", %opt);

B<Initialization via tc configuration>:

	{
		driver => 'Mpstat',
		params => {
			httpd_start => 1,
			httpd_port => 5118,
		},
	},

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=item B<mpstat> (string, <automatically determined from $PATH>)

Full path to mpstat(8) binary. Mpstat binary will be searched in $PATH if this option is omitted.

=item B<mpstat_args> (string, "1"):

Mpstat(8) binary command line options. Don't set this option unless you really know what you're doing.

=item B<httpd_start> (boolean, 0):

Start our own webserver to serve requests?

=item B<httpd_addr> (string, "0.0.0.0"):

HTTP server listening address. See L<POE::Component::Server::HTTPEngine> for details.

=item B<httpd_port> (integer, 5117):

HTTP server listening port. See L<POE::Component::Server::HTTPEngine> for details.

=item B<httpd_ssl> (boolean, 0):

HTTP server should accept only SSL-negotitated connections. See L<POE::Component::Server::HTTPEngine> for details.

=item B<httpd_ssl_cert> (string, ""):

Full path to SSL x509 certificate file. See L<POE::Component::Server::HTTPEngine> for details.

=item B<httpd_ssl_key> (string, ""):

Full path to SSL x509 certificate private key file. See L<POE::Component::Server::HTTPEngine> for details.

=item B<httpd_access_log> (mixed, undef):

Access log hander. see L<POE::Component::Server::HTTPEngine> for details.

=item B<httpd_error_log> (mixed, undef):

Error log hander, see L<POE::Component::Server::HTTPEngine> for details.

=item B<context_path> (string, "/info/mpstat")

tc agent connector URI context path. If undef, connector URI will not be mounted.

=item B<httpd_context_path> (string, "/info/mpstat")

If B<httpd_start> is enabled and you want to mount different context URI as the one on connector. If undef,
httpd context will not be mounted (this is silly - why then you need your own httpd?!).

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

  # path to mpstat program
  $self->{mpstat} = $self->_which("mpstat");

  # mpstat args
  $self->{mpstat_args} = "-P ALL -u 1";

  # value computation mode
  # $self->{mode} = OP_AVG_VAL;

  # start our own http server?
  $self->{httpd_start} = 0;

  # http server configuration...
  $self->{httpd_addr}         = "0.0.0.0";
  $self->{httpd_port}         = 5117;
  $self->{httpd_ssl}          = 0;
  $self->{httpd_ssl_cert}     = undef;
  $self->{httpd_ssl_key}      = undef;
  $self->{httpd_access_log}   = undef;
  $self->{httpd_error_log}    = undef;
  $self->{httpd_context_path} = CTX_DEFAULT;

  # context path
  $self->{context_path} = CTX_DEFAULT;

  # private settings
  $self->{_run_last_time} = 0;        # last time we've started mpstat
  $self->{_run_count}     = 0;        # mpstat run count ... :)
  $self->{_stopping}      = 0;        # we're not stopping...
  $self->{_wheel}         = undef;    # POE::Wheel::Run wheel object...

  # register our events...
  $self->registerEvent(qw(_mpstatRun _evClose _evError _evStderr _evStdout _sigh_CHLD dataGet dataReset));

  $self->_dataReset();

  return 1;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $self->{_error} = "";

  # start our own http server?
  if ($self->{httpd_start}) {
    $_log->info("Creating our own HTTP server.");

    # create options
    my %opt = ();
    map {
      if ($_ ne 'httpd_start' && $_ ne 'httpd_context_path' && $_ =~ m/^httpd_(.+)$/)
      {
        $opt{$1} = $self->{$_};
      }
    } sort keys %{$self};

    my $httpd = POE::Component::Server::HTTPEngine->new(%opt);

    # mount our handler somewhere...
    if (defined $self->{httpd_context_path}) {
      my $r = $httpd->mount(
        {
          uri     => $self->{httpd_context_path},
          handler => __PACKAGE__ . "::WebHandler",
          args    => {session => $self->getSessionId(),},
        },
      );

      unless ($r) {
        $_log->error("Error mounting context path '$self->{httpd_context_path}': " . $httpd->getError());
      }
    }
    else {
      $_log->warn("Undefined property httpd_context_path. Internal http server will be unusable.");
    }

    # mount context list handler if context path != /
    if ($self->{httpd_context_path} ne '/') {
      $httpd->mount(uri => "/", handler => "ContextList", args => {},);
    }

    # start the server
    $httpd->spawn();

    # save it to ourselves...
    $self->{_httpd} = $httpd;
  }

  # try to mount context_path on all agent connectors
  if (defined $self->{context_path}) {
    $_log->debug("Mounting connector context: $self->{context_path}'");
    my $agent = $self->getAgent();
    if (defined $agent) {
      my $r = $agent->connectorMountContext(
        uri     => $self->{context_path},
        handler => __PACKAGE__ . "::WebHandler",
        args    => {session => $self->getSessionId()},
      );

      unless ($r) {
        $_log->error("Error mounting context on agent's connectors: " . $agent->getError());
      }
    }
    else {
      $_log->error("Error retrieving agent object: " . $self->{_error});
    }
  }
  else {
    $_log->warn("Will not mount context on agent's connectors.");
  }

  # let's get to the point...
  $kernel->yield("_mpstatRun");
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

  # do we have have our own webserver?
  if (defined $self->{_httpd}) {
    $_log->info("Stopping our own HTTP server.");

    # this doesn't work... weird...
    # $self->{_httpd}->shutdown();
    # this one does... weird...
    $poe_kernel->call($self->{_httpd}->getSessionId(), "shutdown");
    delete($self->{_httpd});
    $self->{_httpd} = undef;
  }

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

  # stop mpstat process...
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

sub _mpstatRun : State {
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
      $_log->error("Program mpstat died to many times ($self->{_run_count}) in to short time (",
        RUN_TIMEOUT, " second(s)).");
      $_log->warn("Selfdestructing plugin.");
      $self->unload();
      return 0;
    }
  }

  $self->{_run_count}++;
  $self->{_run_last_time} = time();

  # reset the data structure...
  $self->_dataReset();

  # check for stuff...
  unless (defined $self->{mpstat}) {
    $self->{_error} = "Undefined mpstat binary.";
    return 0;
  }
  unless (-f $self->{mpstat} && -x $self->{mpstat}) {
    $self->{_error} = "Invalid mpstat binary: '$self->{mpstat}'";
    return 0;
  }

  my $prog = $self->{mpstat};
  my @args = split(/\s+/, $self->{mpstat_args});

  # untie standard streams if they're tied...
  untie *STDOUT if (tied *STDOUT);
  untie *STDERR if (tied *STDERR);

  # create run wheel...
  $_log->debug("Starting mpstat: '$prog " . join(" ", @args) . "'");
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
  $_log->info("Mpstat process invoked as pid $pid.");

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

  #
  # parse the goddamn line...
  #
  # $ mpstat  -P ALL -u 1
  # Linux 2.6.32-2-amd64 (rex) 	08. 03. 2010 	_x86_64_	(2 CPU)
  #
  # 12:48:50     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest   %idle
  # 12:48:51     all    1,23    0,00    1,23    0,00    0,61    0,00    0,00    0,00   96,93
  # 12:48:51       0    1,00    0,00    1,00    0,00    0,00    0,00    0,00    0,00   98,00
  # 12:48:51       1    1,64    0,00    0,00    0,00    0,00    0,00    0,00    0,00   98,36
  #
  # 12:48:51     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest   %idle
  # 12:48:52     all    1,36    0,00    0,45    0,00    0,00    0,00    0,00    0,00   98,18
  # 12:48:52       0    0,00    0,00    0,00    0,00    0,00    0,00    0,00    0,00  100,00
  # 12:48:52       1    1,67    0,00    0,83    0,00    0,00    0,00    0,00    0,00   97,50
  #

  # return if line isn't kosher
  return 1 unless ($str =~ m/^\d{2}:\d{2}:\d{2}\s+\d+/);

  # mpstat outputs commas (,) instead of dots (.) which causes havoc with arithmetic operations
  $str =~ s/,/./g;

  $_log->warn("GOT STRING: '$str'");

  my ($time, $cpu, $usr, $nice, $sys, $iowait, $irq, $soft, $steal, $guest, $idle) = split(/\s+/, $str);

  # add values...
  $self->{_data}->{"usr"}->add($usr);
  $self->{_data}->{"nice"}->add($nice);
  $self->{_data}->{"sys"}->add($sys);
  $self->{_data}->{"iowait"}->add($iowait);
  $self->{_data}->{"irq"}->add($irq);
  $self->{_data}->{"soft"}->add($soft);
  $self->{_data}->{"steal"}->add($steal);
  $self->{_data}->{"guest"}->add($guest);
  $self->{_data}->{"idle"}->add($idle);

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

  # restart mpstat process if this plugin is
  # not stopping...
  unless ($self->{_stopping}) {
    $_log->warn("Mpstat program '$self->{mpstat}' closed.") if (defined $_log);
    $kernel->yield("_mpstatRun");
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
    "usr"    => ACME::StatQueue->new(QUEUE_CAPACITY),
    "nice"   => ACME::StatQueue->new(QUEUE_CAPACITY),
    "sys"    => ACME::StatQueue->new(QUEUE_CAPACITY),
    "iowait" => ACME::StatQueue->new(QUEUE_CAPACITY),
    "irq"    => ACME::StatQueue->new(QUEUE_CAPACITY),
    "soft"   => ACME::StatQueue->new(QUEUE_CAPACITY),
    "steal"  => ACME::StatQueue->new(QUEUE_CAPACITY),
    "guest"  => ACME::StatQueue->new(QUEUE_CAPACITY),
    "idle"   => ACME::StatQueue->new(QUEUE_CAPACITY),
  };

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::Mpstat::MpstatHandler>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Plugin>
L<POE::Component::Server::HTTPEngine>
L<POE::Component::Server::HTTPEngine::Handler>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
