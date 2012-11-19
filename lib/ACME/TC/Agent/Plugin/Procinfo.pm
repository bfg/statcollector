package ACME::TC::Agent::Plugin::Procinfo;


use strict;
use warnings;

use POE;
use Log::Log4perl;
use Time::HiRes qw(time);

use ACME::StatQueue;
use ACME::TC::Agent::Plugin;

use base qw(ACME::TC::Agent::Plugin);

use constant QUEUE_CAPACITY => 60;
use constant PROC_DIR       => '/proc';
use constant CTX_DEFAULT    => "/info/procinfo";

our $VERSION = 0.12;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::Procinfo

This plugin monitors for number of processes and threads currently running
on a system.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my %opt = (
	);
	my $poe_session_id = $agent->pluginInit("Procinfo", %opt);

B<Initialization via tc configuration>:

	{
		driver => 'Procinfo',
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
  $self->{contextPath} = CTX_DEFAULT;

  # "private" stuff
  $self->{_data} = {};

  # register our events...
  $self->registerEvent(
    qw(
      dataGet
      dataReset
      checkProc
      )
  );

  $self->_dataReset();

  return 1;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $self->{_error} = "";

  # check platform...
  if ($^O !~ m/linux/i) {
    $_log->error("This plugin doesn't support $^O operating system.");
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
      return $kernel->yield('shutdown');
    }
  }

  # start checking...
  $kernel->yield('checkProc');

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
  foreach (keys %{$self->{_data}}) {
    $data->{$_} = $self->{_data}->{$_}->clone();
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

sub checkProc {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  my $ts = time();
  $self->_checkProc();
  my $duration = time() - $ts;
  $_log->debug("Processinfo check done in " . sprintf("%-.3f msec", $duration * 1000));

  $kernel->delay('checkProc', 10);
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _checkProc {
  my ($self) = @_;

  my $dirh = undef;
  unless (opendir($dirh, PROC_DIR)) {
    $_log->error("Unable to open directory /proc: $!");
    return 0;
  }

  # read entries...
  my $num_proc = 0;
  my $num_thr  = 0;
  my $num_fd   = 0;
  while (defined(my $entry = readdir($dirh))) {
    next if ($entry eq '.' || $entry eq '..');
    next if ($entry !~ m/^\d+$/);

    $num_proc++;

    # get number of threads...
    $num_thr += $self->_checkProcEntry($entry);

    # get number of open filedescriptors...
    $num_fd += $self->_checkProcEntryFd($entry);
  }
  closedir($dirh);

  $self->{_data}->{'proc.num'}->add($num_proc);
  $self->{_data}->{'thread.num'}->add($num_thr);
  $self->{_data}->{'fd.num'}->add($num_fd);

  return 1;
}

sub _checkProcEntry {
  my ($self, $entry) = @_;
  return 0 unless (defined $entry);

  my $dirh = undef;
  my $dir  = PROC_DIR . "/$entry/task";
  return 0 unless (opendir($dirh, $dir));
  my $num = 0;
  while (defined(my $entry = readdir($dirh))) {
    next if ($entry eq '.' || $entry eq '..');
    $num++;
  }
  closedir($dirh);

  return $num;
}

sub _checkProcEntryFd {
  my ($self, $entry) = @_;
  return 0 unless (defined $entry);

  my $dirh = undef;
  my $dir  = PROC_DIR . "/$entry/fd";
  return 0 unless (opendir($dirh, $dir));
  my $num = 0;
  while (defined(my $entry = readdir($dirh))) {
    next if ($entry eq '.' || $entry eq '..');
    $num++;
  }
  closedir($dirh);

  return $num;
}

sub _dataReset {
  my ($self) = @_;
  $self->{_data} = {
    'thread.num' => ACME::StatQueue->new(QUEUE_CAPACITY),
    'proc.num'   => ACME::StatQueue->new(QUEUE_CAPACITY),
    'fd.num'     => ACME::StatQueue->new(QUEUE_CAPACITY),
  };
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
