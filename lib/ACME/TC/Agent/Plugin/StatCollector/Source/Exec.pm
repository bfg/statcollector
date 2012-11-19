package ACME::TC::Agent::Plugin::StatCollector::Source::Exec;


use strict;
use warnings;

use Log::Log4perl;

use POE;
use POE::Wheel::Run;

use ACME::Util;
use ACME::TC::Agent::Plugin::StatCollector::Source;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Source);

use constant EXIT_CODE_IGNORE => -1;

our $VERSION = 0.03;

my $u = ACME::Util->new();

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Source::Exec

External command statistics source implementation.

=head1 DESCRIPTION

This source implementation is able to fetch statistics data by invoking external
programs or scripts and reading their output. 

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

=over 

Object constructor accepts all named parameters supported by 
L<ACME::TC::Agent::Plugin::StatCollector::Source> plus the
following ones:

=item B<command> (string, ""):

Command to spawn. Command line arguments can be also specified.

B<NOTE>: You can use special variable %{HOSTNAME} as part of command
string to refer to B<hostname> configuration property.

=item B<ignoreStderr> (boolean, 1):

Ignores program's stderr output - Source will never complain if program writes
anything to stderr.

=item B<requiredExitCode> (integer, -1)

If set and different to default value of B<-1>, source will wait for SIGCHLD;
after signal is received, external program's exit code will be evaluated. If
this property is set to default value, source object will not wait for SIGCHLD,
thus accepting any external program's exit code. If you really want to set this
property you probably want set it to value of 0.

=item B<hostname> (string, undef)

Report specified hostname as part of returned raw content.

=back

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{command}          = '';
  $self->{ignoreStderr}     = 1;
  $self->{requiredExitCode} = -1;
  $self->{hostname}         = undef;

  # private vars
  $self->{_wheel}  = undef;    # poe::wheel::run object
  $self->{_stderr} = "";       # program's stderr output
  $self->{_stdout} = "";       # program's stdout output...

  # exposed POE object events
  $self->registerEvent(
    qw(
      _cmdClose
      _cmdError
      _cmdStdout
      _cmdStderr
      _cmdCHLD
      )
  );

  # must return 1 on success
  return 1;
}

sub getFetchUrl {
  my ($self) = @_;
  return $self->{command};
}

sub getHostname {
  my ($self) = @_;
  return $self->{hostname};
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _run {
  my ($self) = @_;
  unless (defined $self->{command} && length($self->{command}) > 0) {
    $self->{_error} = "Command is not set.";
    return 0;
  }

  return 1;
}

sub _fetchStart {
  my ($self) = @_;

  # clear buffers...
  $self->_clearBuffers();

  # create wheel (start the program)...
  return 0 unless ($self->_wheelCreate());

  # wait for output...
  return 1;
}

sub _fetchCancel {
  my ($self) = @_;

  # destroy child...
  $self->_wheelDestroy();

  # clear buffers...
  $self->_clearBuffers();
}

sub _shutdown {
  my ($self) = @_;

  # cancel last request
  $self->_fetchCancel();
}

sub _wheelCreate {
  my ($self) = @_;

  # create options...
  my %opt = (
    CloseEvent   => "_cmdClose",
    ErrorEvent   => "_cmdError",
    StdoutEvent  => "_cmdStdout",
    StderrEvent  => "_cmdStderr",
    StdioFilter  => POE::Filter::Stream->new(),
    StderrFilter => POE::Filter::Line->new(),
  );

  # get command string
  my $exec_str = $self->_getExecStr();
  return 0 unless (defined $exec_str);

  # assign exec string
  $opt{Program} = $exec_str;

  $_log->debug($self->getFetchSignature(), " Spawning program: '$exec_str'");

  # create run wheel... safely!
  my $wheel = undef;
  eval { $wheel = POE::Wheel::Run->new(%opt) };

  # check for injuries...
  if ($@) {
    $self->{_error} = "Error creating POE wheel: $@";
    return 0;
  }
  elsif (!defined $wheel) {
    $self->{_error} = "Error creating POE wheel: returned undefined value; this is seriously weird.";
    return 0;
  }

  my $id  = $wheel->ID();
  my $pid = $wheel->PID();
  $_log->debug($self->getFetchSignature(), " Program spawned as pid $pid, wheel id $id.");

  # install signal handler...
  $poe_kernel->sig_child($pid, "_cmdCHLD");

  # store wheel
  $self->{_wheel} = $wheel;

  # wait for output...
  return 1;
}

sub _wheelDestroy {
  my ($self) = @_;

  if (defined $self->{_wheel}) {
    my $pid = $self->{_wheel}->PID();
    if (defined $pid && $pid > 0 && kill(0, $pid)) {
      $_log->debug($self->getFetchSignature(), " Killing process $pid using SIGKILL");
      kill(9, $pid);
    }

    # destroy the wheel
    delete($self->{_wheel});
    $self->{_wheel} = undef;
  }

  # empty output buffers...
  $self->_clearBuffers();

  return 1;
}

sub _clearBuffers {
  my ($self) = @_;

  # clear buffers...
  $self->{_stderr} = "";
  $self->{_stdout} = "";

  return 1;
}

# got something on stdout
sub _cmdStdout {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  $_log->trace($self->getFetchSignature(), " Got STDOUT output from program wheel $wid: $data");
  $self->{_stdout} .= $data;
}

# got something on stderr
sub _cmdStderr {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  return 1 if ($self->{ignoreStderr});

  # $_log->trace($self->getFetchSignature(), " Got STDERR output from program wheel $wid: $data");
  $self->{_stderr} .= $data . "\n";
}

# sigchld signal handler...
sub _cmdCHLD {
  my ($self, $kernel, $name, $pid, $exit_val) = @_[OBJECT, KERNEL, ARG0, ARG1, ARG2];

  # what is desired exit code?
  my $desired_exit_val = ($self->{requiredExitCode} == EXIT_CODE_IGNORE) ? 0 : $self->{requiredExitCode};

  # check exit code...
  my $r = $u->evalExitCode($exit_val, $desired_exit_val);

  # do we need to evaluate program's exit code?
  if ($self->{requiredExitCode} != EXIT_CODE_IGNORE) {

    # check exit status...
    if ($r) {

      # validate output and send it to appropriate handler...
      $self->_validateOutput();
    }
    else {

      # exit status check failed, report error to handler...
      $kernel->yield(FETCH_ERR, $u->getError());
    }

    # perform cleanup...
    $self->_wheelDestroy();
  }
  else {
    unless ($r) {
      $_log->debug($self->getFetchSignature(),
        " Process pid $pid exited with invalid exit code: " . $u->getError());
    }
  }

  $kernel->sig_handled();
}

sub _cmdClose {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  $_log->debug($self->getFetchSignature(), " Program closed communication i/o streams.");

  # we can return immediately if we're not
  # supposed to check for program's exit code...
  if ($self->{requiredExitCode} == EXIT_CODE_IGNORE) {

    # validate output and send it to appropriate handler...
    $self->_validateOutput();

    # perform cleanup...
    $self->_wheelDestroy();
  }
}

sub _cmdError {
  my ($self, $kernel, $operation, $errnum, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. ARG3];
  return 1 if ($errnum == 0);
  $kernel->yield(FETCH_ERR, "Program wheel $wid got error no $errnum during operation $operation: $errstr");

  # perform cleanup...
  $self->_wheelDestroy();
}

sub _validateOutput {
  my ($self) = @_;

  unless ($self->{ignoreStderr}) {
    if (length($self->{_stderr}) > 0) {
      $_log->warn($self->getFetchSignature() . " --- BEGIN STDERR ---\n" . $self->{_stderr});
      $_log->warn($self->getFetchSignature() . " --- END STDERR ---\n");
    }
  }

  # did we even get *any* output?!
  if (length($self->{_stdout}) > 0) {

    # send content to success handler...
    $poe_kernel->yield(FETCH_OK, $self->{_stdout});
  }
  else {

    # send error
    $poe_kernel->yield(FETCH_ERR, "Program didn't write any output to stdout.");
  }
}

sub _getExecStr {
  my ($self) = @_;
  my $str    = $self->{command};
  my $host   = $self->getHostname();
  $host = '' unless (defined $host);
  $str =~ s/%{HOSTNAME}/$host/g;

  return $str;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Source>
L<ACME::TC::Agent::Plugin::StatCollector>
L<POE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
