package POE::Component::Server::HTTPEngine::Logger;


use strict;
use warnings;

use Data::Dumper;

use POE;
use IO::File;
use File::Spec;
use File::Basename;
use POE::Wheel::Run;
use POE::Wheel::ReadWrite;

use constant MAX_ERRORS   => 10;
use constant MAX_ERR_TIME => 5;

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

our $VERSION = 0.10;

my $Error = "";

# logging object
my $_log = undef;

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  ##################################################
  #              PUBLIC PROPERTIES                 #
  ##################################################

  ##################################################
  #              PRIVATE PROPERTIES                #
  ##################################################

  $self->{_error} = "";
  $self->{_id}    = time() . "_" . rand();

  $self->{_num_errs} = 0;
  $self->{_last_err} = time();

  # logging destination object
  $self->{_obj}     = undef;
  $self->{_session} = undef;
  $self->{_event}   = undef;

  # logging object
  if (DEBUG && !defined $_log) {
    $_log = Log::Log4perl->get_logger(__PACKAGE__);
  }

  # this logger was not started yet.
  $self->{_spawned} = 0;

  # bless ourselves...
  bless($self, $class);

  # spawn ourselves...
  unless ($self->spawn(@_)) {
    $Error = "Logger initialization failed: $self->{_error}";
    return undef;
  }

  return $self;
}

sub getError {
  my $self = shift;
  return $Error if (ref($self) eq '');
  return $self->{_error};
}

sub getPoeSessionID {
  my $self = shift;
  return $self->{_poe_session};
}

sub ID {
  my $self = shift;
  return $self->{_id};
}

sub log {
  my ($package) = caller();
  my $poe = ($package =~ m/^POE::Sess/);
  my ($self, $str, $request, $response) = @_;
  if ($poe) {
    my ($self, $str, $request, $response) = @_[OBJECT, ARG0 .. $#_];
  }

  if (defined $self->{_obj}) {
    return $self->{_obj}->put($str);
  }
  elsif (defined $self->{_session} && defined $self->{_event}) {

    # sent logging statement to other poe session
    if (DEBUG) {
      $_log->debug("Sending message to session '$self->{_session}', event '$self->{_event}'.");
    }
    my $x = $poe_kernel->post(
      $self->{_session}, $self->{_event},

      # be simple-http compatible...
      $request, $response, $str
    );

    unless ($x) {
      if (DEBUG) {
        $_log->error("Error sending message to session '$self->{_session}', event '$self->{_event}': $!");
      }
    }

    return $x;
  }

  return 1;
}

sub flush {
  my $self = shift;

  # try to flush logger...
  eval { $self->{_obj}->flush() };
  if ($@) {
    if (DEBUG) {
      $_log->error("Error flushing logger: $@");
    }
  }

  return ($?) ? 0 : 1;
}

sub spawn {
  my ($self, $dest) = @_;

  if ($self->{_spawned}) {
    $self->{_error} = "This logger was already spawned.";
    return 0;
  }

  # create POE session...
  my $id = POE::Session->create(
    args          => [$dest],
    object_states => [
      $self => [
        qw(
          _start _stop _parent _child _default
          _init
          __loggerClose __loggerError __loggerFlushed __loggerStderr __loggerStdout
          __sigh_CHLD
          shutdown
          )
      ],
    ],
  )->ID();

  # mark ourselves as spawned...
  $self->{_id}      = $id;
  $self->{_spawned} = 1;

  return $id;
}

sub _start {
  my ($self, $kernel, $dest) = @_[OBJECT, KERNEL, ARG0];
  $_log->debug("Starting new logger ", ref($self), " in POE session: " . $_[SESSION]->ID()) if (DEBUG);

  # $kernel->detach_myself();

  # try to initialize logger...
  return 0 unless ($self->_init($dest));

  # thiz iz it!
  return 1;
}

sub _stop {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  if (DEBUG) {
    $_log->debug("Stopping logger ", ref($self), " POE session: " . $_[SESSION]->ID()) if (defined $_log);
  }

  return 1;
}

sub _child {
  my ($self, $reason, $child) = @_[OBJECT, ARG0, ARG1];
  if ($reason eq 'close') {
    $_log->debug("_child: POE session exit: " . $child->ID()) if (DEBUG);
  }
  else {
    $_log->debug("_child: Reason: $reason; id: " . $child->ID()) if (DEBUG);
  }
}

sub _default {
  my ($self, $event, $args) = @_[OBJECT, ARG0, ARG1];
  my $str
    = "Object "
    . ref($self)
    . ", POE session "
    . $_[SESSION]->ID()
    . " caught unhandled event from session id '"
    . $_[SENDER]->ID()
    . "'. Called event '$event' with arguments: ["
    . join(", ", @{$args}) . "].";

  if (DEBUG) {
    $_log->warn($str);
  }
  else {
    print STDERR __PACKAGE__, " WARNING: $str\n";
  }
}

sub _parent {
  my ($self, $old, $new) = @_[OBJECT, ARG0, ARG1];
  $_log->warn("Object ", ref($self), " parent POE session change: from ", $old->ID(), " to ", $new->ID())
    if (DEBUG);
}

sub _init {
  my ($self, $dest) = @_;

  # sanity check...
  unless (defined $dest) {
    $_log->debug("Undefined destination, returning undefined logging object.") if (DEBUG);
    return undef;
  }

  my $fd = undef;

  # is destination glob reference/filehandle?
  if (defined(fileno($dest))) {

    # yup, it is...
    $fd = $dest;
    $_log->debug("Will use glob $dest as logging filedescriptor.") if (DEBUG);
  }

  # reference to anything?
  elsif (ref($dest) ne '') {

    # does it have put() method?
    if ($dest->can("put") && $dest->can("ID")) {
      return $dest;
    }
    $_log->debug("Dont know what to do with a reference: '$dest'.") if (DEBUG);
    return undef;
  }

  # poe session maybe?
  elsif ($dest =~ m/^\s*(\w+):(\w+)\s*$/) {
    my $session = $1;
    my $event   = $2;
    $_log->debug("Dispatching to: POE session '$session', event '$event'.") if (DEBUG);

    $self->{_session} = $session;
    $self->{_event}   = $event;

    return 1;
  }

  # starts with "|" character?
  elsif ($dest =~ m/^\s*\|+\s*(.+)/) {
    my $cmd = $1;
    $cmd =~ s/^\s+//g;
    $cmd =~ s/\s+$//g;
    $_log->debug("Will spawn logger command: '$cmd'") if (DEBUG);

    # create wheel...
    $self->{_obj} = POE::Wheel::Run->new(
      Program     => $cmd,
      StdioFilter => POE::Filter::Line->new(),
      StdinEvent  => '__loggerFlushed',          # Flushed all data to the child's STDIN.
      StdoutEvent => '__loggerStdout',           # Received data from the child's STDOUT.
      StderrEvent => '__loggerStderr',           # Received data from the child's STDERR.
      ErrorEvent  => '__loggerError',            # An I/O error occurred.
      CloseEvent  => '__loggerClose',            # Child closed all output handles.
    );

    # register sigchld handler
    $poe_kernel->sig_child($self->{_obj}->PID(), "__sigh_CHLD");

    return 1;
  }

  # other this should be a filename...
  else {
    $_log->debug("Looks like a filename: '$dest'") if (DEBUG);

    # check if parent exists...
    my $parent = dirname($dest);
    unless (-d $parent && -w $parent) {
      $self->{_error} = "Parent directory doesn't exist or is not writeable: $parent";
      return undef;
    }

    # try to open file
    $fd = IO::File->new($dest, 'a');
    unless (defined $fd) {
      $self->{_error} = "Unable to open file '$dest': $!";
      return undef;
    }
  }

  # everything seems ok, let's
  # create RW wheel...
  $self->{_obj} = POE::Wheel::ReadWrite->new(
    Handle       => $fd,
    Filter       => POE::Filter::Line->new(),
    FlushedEvent => "__loggerFlushed",
    ErrorEvent   => "__loggerError",
  );

  return 1;
}

sub __loggerFlushed {
  my ($self, $wheel_id) = @_[OBJECT, ARG0];

  #if (DEBUG) {
  #	$_log->debug("Logger FLUSHED: $wheel_id") if (DEBUG);
  #}
}

sub __loggerError {
  my ($self, $operation, $errnum, $errstr, $wheel_id) = @_[OBJECT, ARG0 .. ARG3];

  if ($errnum != 0) {
    if (DEBUG) {
      $_log->warn("Logger wheel '$wheel_id' got error $errnum while doing '$operation': $errstr");
    }
  }

  return 1;
}

sub __loggerStdout {
  my ($self, $data, $wheel_id) = @_[OBJECT, ARG0, ARG1];
  if (DEBUG) {
    $_log->warn("Logger '$wheel_id' STDOUT: $data");
  }
}

sub __loggerStderr {
  my ($self, $data, $wheel_id) = @_[OBJECT, ARG0, ARG1];
  if (DEBUG) {
    $_log->warn("Logger '$wheel_id' STDERR: $data");
  }
}

sub __loggerClose {
  my ($self, $wheel_id) = @_[OBJECT, ARG0];
  if (DEBUG) {
    $_log->warn("Logger (PIPE) wheel '$wheel_id' closed.");
  }
}

sub __sigh_CHLD {
  my ($self, $kernel, $signame, $pid, $exit_val) = @_[OBJECT, KERNEL, ARG0, ARG1, ARG2];
  my $exit_st  = $exit_val >> 8;
  my $exit_sig = $exit_val & 127;
  my $core     = $exit_val & 128;

  if (DEBUG) {
    $_log->warn(
      "Logger $self->{_id} Got SIG$signame for pid $pid: exit status: $exit_st; exit_sig = $exit_sig; core = $core"
    );
  }

  # if we're still started, try again...
  if ($self->{_spawned}) {

  }

  $kernel->sig_handled();
}

sub shutdown {
  my $self = shift;
  $_log->debug("Object deconstruction started...") if (DEBUG);

  my $pid = undef;
  eval { $pid = $self->{_obj}->PID(); };

  # poe::wheel::run?
  if (defined $pid) {

    # try to kill it...
    eval { $self->{_obj}->kill(); };
  }

  # poe::wheel::readwrite?
  elsif (defined $self->{_obj}) {

    # try to flush output (poe::wheel::readwrite)
    eval { $self->{_obj}->flush(); };

  }

  $self->{_spawned} = 0;

  # destroy the object...
  $self->{_obj} = undef;
  delete($self->{_obj});

  $self->{_spawned} = 0;

  return 1;
}

sub DESTROY {
  my $self = shift;
  if (DEBUG) {
    $_log->debug("Destroying: $self") if (defined $_log);
  }
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE::Component::Server::HTTPEngine>

=cut

1;
