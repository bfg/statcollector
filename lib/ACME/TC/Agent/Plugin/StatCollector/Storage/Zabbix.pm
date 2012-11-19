package ACME::TC::Agent::Plugin::StatCollector::Storage::Zabbix;


# check for IPv6 support...
BEGIN { eval 'require Socket6'; }
my $_has_ipv6 = (exists($INC{'Socket6.pm'}) && defined $INC{'Socket6.pm'}) ? 1 : 0;

use strict;
use warnings;

use POE;
use POE::Wheel::Run;
use POE::Wheel::SocketFactory;
use POE::Filter::Stream;
use POE::Wheel::ReadWrite;

use bytes;
use Socket;
use IO::File;
use File::Spec;
use Log::Log4perl;
use File::Basename;
use File::Copy qw(move);
use Time::HiRes qw(time);
use File::Glob qw(:glob);

use ACME::Util;
use ACME::TC::Agent::Plugin::StatCollector::Storage;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Storage);

use constant MODE_SENDER     => 1;
use constant MODE_TCP        => 2;
use constant DNS_RESOLVE_INT => 600;

our $VERSION = 0.06;
my $u = ACME::Util->new();

# async DNS support
my $_adns_session = undef;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Storage::Zabbix

This storage plugin stores data to Zabbix(TM) server using zabbix_sender(8) binary
or using built-in TCP sender protocol implementation (requires zabbix 1.8.x).

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin::StatCollector::Storage> and the following ones:

=over

=item B<mode> (string, "sender"): Operate mode ("sender", "tcp")

This option select two operational modes of this storage plugin. Mode B<sender> uses B<zabbix_sender(1)> binary to push
data to zabbix server, mode B<tcp> uses pure-perl implementation of zabbix sender version >= 1.8.x protocol. The latter
should perform better, doesn't require zabbix_sender binary installed on system, but requires Zabbix server version >= 1.8.x.

=item B<zabbix_sender> (string, "/usr/bin/zabbix_sender"):

Path to zabbix_sender binary.

=item B<zabbixServer> (string, "localhost"):

Zabbix server hostname or IP.

=item B<zabbixServerPort> (integer, 10051):

Zabbix server trapper port.

=item B<concurrency> (integer, 50):

Maximum number of concurrently active storage requests

=item B<queueInterval> (float, 0.5):

Flush storage queue every specified amount of seconds.

=item B<debugData> (boolean, 0):

Enables some storage data debugging without requiring special log4perl configuration

=back

=head1 METHODS

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{mode}             = "sender";
  $self->{zabbix_sender}    = "/usr/bin/zabbix_sender";
  $self->{zabbixServer}     = "localhost";
  $self->{zabbixServerPort} = 10051;
  $self->{concurrency}      = 50;
  $self->{queueInterval}    = 0.5;
  $self->{debugData}        = 0;

  # integer representation of $self->{_mode}
  $self->{_mode} = MODE_SENDER;

  # file wheel hash...
  $self->{_wfile} = {};

  # zabbix_sender program wheel hash...
  $self->{_wsender} = {};

  # zabbix server socketfactory wheel hash
  $self->{_tcp_wheel} = {};

  # pid => wheel id mapping
  $self->{_pid_wheel} = {};

  # zabbix_sender queue
  $self->{_senders} = 0;
  $self->{_queue}   = [];

  # zabbix server ip address
  $self->{_zabbixServerAddr} = undef;

  # exposed POE object events
  $self->registerEvent(
    qw(
      _storeToFile
      _storeToZabbix
      _fileError
      _fileFlushed
      _senderClose
      _senderError
      _senderStdout
      _senderStderr
      _senderCHLD
      _queueAdd
      _queueFlush
      _zabbixTcpStore
      _sockConnOk
      _sockConnErr
      _sockInput
      _sockFlushed
      _sockError
      resolveZabbixServer
      )
  );

  # must return 1 on success
  return 1;
}

=head2 getZabbixSenderStr ($data)

Returns zabbix_sender(8) representation of specified object data.

=cut

sub getZabbixSenderStr {
  my ($self, $data) = @_;
  my $str = "";

  my $host = $data->getHost();
  unless (defined $host) {
    $self->{_error} = "Invalid or undefined hostname.";
    return undef;
  }
  my $fetch_time = int($data->getFetchStartTime());

  # content
  my $c = $data->getContent(1);
  map {
    if (defined $_ && defined $c->{$_})
    {
      my @tmp = split(/\s+/, $_);
      my $key = join(".", @tmp);
      $str .= $host . ' ' . $key . ' ' . $fetch_time . ' ' . $c->{$_} . "\n";
    }
  } keys %{$c};

  return $str;
}

=head2 getZabbixJsonStr ($obj)

Returns JSON representation of specified L<ParsedData> object.

=cut

sub getZabbixJsonStr {
  my ($self, $obj) = @_;
  unless (defined $obj) {
    $self->{_error} = "Invalid parsed data object.";
    return undef;
  }

  my $host = $obj->getHost();
  unless (defined $host && length($host) > 0) {
    $self->{_error} = "ParsedData object contains undefined or invalid hostname.";
    return undef;
  }

  my $t = int($obj->getFetchDoneTime());

  my $tmp_str = "{\n";
  $tmp_str .= "\t" . '"request":"sender data",' . "\n";
  $tmp_str .= "\t" . '"data":[';
  my @chunks = ();
  my $data   = $obj->getContent(1);
  foreach (sort keys %{$data}) {
    my $x .= "\n";
    $x    .= "\t\t{\n";
    $x    .= "\t\t\t" . '"host":"' . $host . '",' . "\n";
    $x    .= "\t\t\t" . '"key":"' . $_ . '",' . "\n";
    $x    .= "\t\t\t" . '"value":"' . $data->{$_} . '",' . "\n";
    $x    .= "\t\t\t" . '"clock":' . $t;
    $x    .= "}";
    push(@chunks, $x);
  }
  $tmp_str .= join(",", @chunks);
  $tmp_str .= "],\n";
  $tmp_str .= "\t" . '"clock":' . $t . '}';

  # zabbix message header...
  my $result = 'ZBXD' . chr(1);
  $result .= _len2zbxlen(length($tmp_str));

  # zabbix message payload..
  $result .= $tmp_str;

  return $result;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

# startup hook
sub _run {
  my ($self) = @_;

  # check zabbix server address
  unless (defined $self->{zabbixServer} && length($self->{zabbixServer}) > 0) {
    $self->{_error} = "Undefined zabbix server hostname.";
    return 0;
  }

  # check zabbix server port
  { no warnings; $self->{zabbixServerPort} = int($self->{zabbixServerPort}); }
  unless ($self->{zabbixServerPort} > 0 && $self->{zabbixServerPort} <= 65536) {
    $self->{_error} = "Invalid zabbix server port: $self->{zabbixServerPort}";
    return 0;
  }

  # check operation mode
  if (!defined $self->{mode} || length($self->{mode}) < 1) {
    $_log->warn($self->getStorageSignature() . "Undefined operation mode; falling back to sender mode.");
    $self->{mode}  = 'sender';
    $self->{_mode} = MODE_SENDER;
  }
  elsif (lc($self->{mode}) eq 'sender') {
    $self->{_mode} = MODE_SENDER;
  }
  elsif (lc($self->{mode}) eq 'tcp') {
    $self->{_mode} = MODE_TCP;
  }
  else {
    $_log->warn($self->getStorageSignature()
        . "Unknown operational mode '$self->{mode}'; falling back to sender mode.");
    $self->{mode}  = 'sender';
    $self->{_mode} = MODE_SENDER;
  }

  # check for zabbix_sender binary if necessary
  if ($self->{_mode} == MODE_SENDER) {
    unless (defined $self->{zabbix_sender} && length($self->{zabbix_sender})) {
      $self->{_error} = "Undefined or zero-length zabbix_sender binary specification.";
      return 0;
    }
    unless (-f $self->{zabbix_sender} && -x $self->{zabbix_sender}) {
      $self->{_error} = "Invalid zabbix_sender binary: $self->{zabbix_sender}";
      return 0;
    }
  }

  # try to resolve zabbix server address if we're using tcp mode...
  if ($self->{_mode} == MODE_TCP) {
    $self->{_zabbixServerAddr} = $self->{zabbixServer};
    $poe_kernel->yield('resolveZabbixServer');
  }

  # start queue flush process
  $poe_kernel->yield("_queueFlush", 1);

  return 1;
}

# enqueue storage...
sub _store {
  my ($self, $id, $data) = @_;

  if ($self->{_mode} == MODE_TCP) {
    $poe_kernel->yield("_queueAdd", $id, $data);
  }
  elsif ($self->{_mode} == MODE_SENDER) {

    # PHASE I: store data to file
    $poe_kernel->yield("_storeToFile", $id, $data);
  }
  else {
    $self->{_error} = "Invalid operational mode: $self->{_mode}";
    return 0;
  }

  # when storing to file is done, file will
  # be picked up by running zabbix_sender program...

  return 1;
}

sub _storeCancel {
  my ($self, $id) = @_;
  unless (defined $id && length($id) > 0) {
    $self->{_error} = "Invalid store id.";
    return 0;
  }

  $_log->debug($self->getStorageSignature() . "Canceling storage request: $id.");


  # check waiting queue
  my $qlen = $#{$self->{_queue}};
  for (my $i = 0; $i <= $qlen; $i++) {
    if (defined $self->{_queue}->[$i] && $self->{_queue}->[$i]->[0] eq $id) {
      $_log->debug($self->getStorageSignature() . "Found store request $id in waiting queue.");
      $self->{_queue}->[$i] = undef;
      last;
    }
  }

  # if request is already in processing
  # check all sender wheels...

  foreach my $key (keys %{$self->{_wfile}}) {
    my $s = $self->{_wfile}->{$key};
    if (defined $s && defined $s->{sid} && $s->{sid} eq $id) {
      $_log->trace($self->getStorageSignature() . "Found cancelation in _wfile");
      delete($self->{_wfile}->{$key});
      last;
    }
  }
  foreach my $key (keys %{$self->{_wsender}}) {
    my $s = $self->{_wsender}->{$key};
    if (defined $s && defined $s->{sid} && $s->{sid} eq $id) {
      $_log->trace($self->getStorageSignature() . "Found cancelation in _wsender");
      delete($self->{_wsender}->{$key});
      last;
    }
  }
  foreach my $key (keys %{$self->{_tcp_wheel}}) {
    my $s = $self->{_tcp_wheel}->{$key};
    if (defined $s && defined $s->{sid} && $s->{sid} eq $id) {
      $_log->trace($self->getStorageSignature() . "Found cancelation in _tcp_wheel");
      delete($self->{_tcp_wheel}->{$key});
      last;
    }
  }

  $self->{_senders}--;
  return 1;
}

# shutdown!
sub _shutdown {
  my ($self) = @_;

  # destroy filehandle wheels
  my $i = 0;
  if (defined $self->{_wfile} && ref($self->{_wfile}) eq 'ARRAY') {
    foreach my $wid (@{$self->{_wfile}}) {
      next unless (defined $wid);
      $i++;

      my $wheel = $self->{_wfile}->{$wid}->{wheel};
      my $file  = $self->{_wfile}->{$wid}->{file};

      # try to flush it
      eval { $wheel->flush(); };
      if ($@) {
        $_log->error($self->getStorageSignature() . "Error flushing wheel $wid: $@");
        unlink($file);
        delete($self->{_wfile}->{$wid});
      }

      # destroy struct
      delete($self->{_wfile}->{$wid});
    }
    $_log->info($self->getStorageSignature() . "Destroyed $i pending filehandles.");
  }

  # destroy zabbix sender wheels
  $i = 0;
  if (defined $self->{_wsender} && ref($self->{_wsender}) eq 'HASH') {
    foreach my $wid (keys %{$self->{_wsender}}) {
      next unless (defined $wid);
      $i++;
      my $wheel = $self->{_wsender}->{$wid}->{wheel};
      my $pid   = 0;
      eval { $pid = $wheel->PID() };

      # kill the process...
      kill(9, $pid) if (defined $pid && $pid > 0);

      # destroy struct
      delete($self->{_wsender}->{$wid});
    }
    $_log->info($self->getStorageSignature() . "Destroyed $i pending sender processes/connections.");
  }

  # destroy socket factory wheels
  foreach my $wid (keys %{$self->{_tcp_wheel}}) {
    delete($self->{_tcp_wheel}->{$wid});
  }

  return 1;
}

sub _storeToFile {
  my ($self, $kernel, $id, $data) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  my $fs = $data->getFetchStartTime();

  # get zabbix data
  my $str = $self->getZabbixSenderStr($data);
  unless (defined $str && length($str) > 0) {
    $kernel->yield(STORE_ERR, $id, "Invalid parsed data: " . $data->getError());
    return 1;
  }

  # calculate filename
  my $file = File::Spec->catfile(File::Spec->tmpdir(), 'zbx-' . $fs . "-" . $id . ".txt");

  # open file
  $_log->debug($self->getStoreSig($id) . " Storing to file: $file");
  my $fd = IO::File->new($file, 'w');
  unless (defined $fd) {
    $self->{_error} = "Unable to open file '$file' for writing: $!";
    return 0;
  }

  # create rw wheel
  my $wheel = POE::Wheel::ReadWrite->new(
    Handle       => $fd,
    Filter       => POE::Filter::Stream->new(),
    FlushedEvent => "_fileFlushed",
    ErrorEvent   => "_fileError"
  );
  my $wid = $wheel->ID();
  $_log->debug($self->getStoreSig($id) . " Created RW wheel: $wid");

  # don't even try to read from wheel...
  $wheel->pause_input();

  if ($_log->is_trace()) {
    $_log->trace($self->getStoreSig($id) . "--- BEGIN ZABBIX SENDER DATA ---" . "\n" . $str);
    $_log->trace($self->getStoreSig($id) . "--- END ZABBIX SENDER DATA ---");
  }
  elsif ($self->{debugData}) {
    $_log->info($self->getStoreSig($id) . "--- BEGIN ZABBIX SENDER DATA ---" . "\n" . $str);
    $_log->info($self->getStoreSig($id) . "--- END ZABBIX SENDER DATA ---");
  }

  # put data to wheel
  $wheel->put($str);

  # save wheel
  $self->{_wfile}->{$wid} = {wheel => $wheel, file => $file, sid => $id,};

  # wait until writing is finished, then
  # run zabbix sender on it...
  return 1;
}

sub _queueAdd {
  my ($self, $kernel, $id, $file) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  $_log->debug($self->getStoreSig($id) . "Enqueuing file $file, storage id $id.");

  if ($_log->is_trace()) {
    my $str = "";
    map { $str .= $_->[0] . ": " . $_->[1] . "; "; } @{$self->{_queue}};
    my $size = $#{$self->{_queue}} + 1;
    $_log->trace($self->getStorageSignature() . "Current queue ($size): ", $str);
  }

  push(@{$self->{_queue}}, [$id, $file]);

  #$kernel->yield("_queueFlush");
  return 1;
}

sub _queueFlush {
  my ($self, $kernel, $periodic) = @_[OBJECT, KERNEL, ARG0];
  $periodic = 0 unless (defined $periodic);

  $_log->debug($self->getStorageSignature() . "Flushing zabbix sender queue.");

  if ($_log->is_trace()) {
    my $str = "";
    map {
      $str .= (defined $_) ? ($_->[0] . ": " . $_->[1]) : "undef";
      $str .= "; ";
    } @{$self->{_queue}};

    my $size = $#{$self->{_queue}} + 1;
    $_log->trace($self->getStorageSignature() . "Current queue ($size): ", $str);
  }

  if (@{$self->{_queue}}) {
    my $no_items = $#{$self->{_queue}} + 1;

    # compute number of items that we will flush
    my $num = $self->{concurrency} - $self->{_senders};
    $num = $no_items if ($num > $no_items);

    $_log->debug($self->getStorageSignature()
        . "Zabbix_sender queue contains $no_items item(s); Currently there are $self->{_senders} senders running."
    );
    my $i = 0;
    while ($i < $num && (defined(my $e = shift(@{$self->{_queue}})))) {
      $i++;
      next unless (defined $e);
      my $event = ($self->{_mode} == MODE_SENDER) ? '_storeToZabbix' : '_zabbixTcpStore';
      $kernel->yield($event, $e->[0], $e->[1]);
    }
    $_log->debug($self->getStorageSignature() . "Enqueued $i zabbix_sender files.");
  }
  else {
    $_log->debug($self->getStorageSignature() . "No zabbix_sender files in waiting queue.");
  }

  # if this was periodic flush, re-schedule ourselves
  # again. and again. and again.
  #
  # See: http://www.youtube.com/watch?v=9VDvgL58h_Y
  if ($periodic) {
    if ($self->{queueInterval} > 0) {
      $_log->debug($self->getStorageSignature()
          . "Periodic queue check done, scheduling next one in "
          . sprintf("%-.3f", $self->{queueInterval})
          . " second(s).");
      $poe_kernel->delay("_queueFlush", $self->{queueInterval}, 1);
    }
  }
}

sub _storeToZabbix {
  my ($self, $kernel, $id, $file) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  return 0 unless (defined $id && defined $file);
  unless (-f $file && -r $file) {
    $_log->error($self->getStoreSig($id) . "Invalid zabbix_sender file: $file");
    return 0;
  }

  $_log->debug($self->getStoreSig($id) . "Storing id $id from file $file using zabbix_sender");

  # create poe run wheel
  my $args
    = [$self->{zabbix_sender}, '-z', $self->{zabbixServer}, '-p', $self->{zabbixServerPort}, '-T', '-i',
    $file,];

  if ($_log->is_debug()) {
    no warnings;
    $_log->debug($self->getStoreSig($id) . "Starting program: " . join(" ", @{$args}));
  }

  my $wheel = POE::Wheel::Run->new(
    Program     => $args,
    StdioFilter => POE::Filter::Stream->new(),
    StdoutEvent => "_senderStdout",
    StderrEvent => "_senderStderr",
    CloseEvent  => "_senderClose",
    ErrorEvent  => "_senderError",
  );

  # get the pid
  my $pid = $wheel->PID();
  my $wid = $wheel->ID();

  $_log->debug($self->getStoreSig($id) . "Started program pid $pid as wheel $wid.");

  # install sigchld handler
  $poe_kernel->sig_child($pid, "_senderCHLD");

  # store wheel
  $self->{_wsender}->{$wid} = {
    pid      => $pid,
    sid      => $id,
    file     => $file,
    wheel    => $wheel,
    stdout   => "",
    stderr   => "",
    error    => "",
    alarm_id => undef,
  };

  # save pid => wheel id mapping...
  $self->{_pid_wheel}->{$pid} = $wid;

  # increment senders count
  $self->{_senders}++;

  return 1;
}

sub _fileError {
  my ($self, $kernel, $operation, $errnum, $errstr, $wheel_id) = @_[OBJECT, KERNEL, ARG0 .. ARG3];

  # get storage id
  my $sid  = $self->{_wfile}->{$wheel_id}->{sid};
  my $file = $self->{_wfile}->{$wheel_id}->{file};

  $_log->error($self->getStoreSig($sid) . "Got errno $errnum while running operation: $operation: $errstr");

  # destroy the wheel structure...
  delete($self->{_wfile}->{$wheel_id});

  $_log->warn($self->getStoreSig($sid) . "Removing bogux zabbix_sender file: $file");
  unless (unlink($file)) {
    $_log->error($self->getStoreSig($sid) . "Unable to remove bogus zabbix_sender file $file: $!");
  }

  # we were successfull!
  $kernel->yield(STORE_ERR, $sid, $errstr) if (defined $sid);
}

sub _fileFlushed {
  my ($self, $kernel, $wheel_id) = @_[OBJECT, KERNEL, ARG0];
  $_log->debug($self->getStorageSignature() . "Wheel $wheel_id flushed.");

  # get storage id
  my $sid = $self->{_wfile}->{$wheel_id}->{sid};


  # data has been written to file,
  # let's fire zabbix sender...
  my $file = $self->{_wfile}->{$wheel_id}->{file};

  # destroy the wheel
  delete($self->{_wfile}->{$wheel_id});

  # enqueue zabbix storage of file
  $kernel->yield("_queueAdd", $sid, $file);

  return 1;
}

sub _senderStdout {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  my $pid = $self->{_wsender}->{$wid}->{pid};
  my $sid = $self->{_wsender}->{$wid}->{sid};
  $_log->debug($self->getStoreSig($sid) . "Got STDOUT output from program pid $pid wheel id $wid: $data");
  $self->{_wsender}->{$wid}->{stdout} .= $data;
}

sub _senderStderr {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  my $pid = $self->{_wsender}->{$wid}->{pid};
  my $sid = $self->{_wsender}->{$wid}->{sid};
  $_log->debug($self->getStoreSig($sid) . "Got STDERR output from program pid $pid wheel id $wid: $data");
  $self->{_wsender}->{$wid}->{stderr} .= $data;
}

sub _senderClose {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  my $pid = $self->{_wsender}->{$wid}->{pid};
  my $sid = $self->{_wsender}->{$wid}->{sid};
  $_log->debug($self->getStoreSig($sid) . "Zabbix sender pid $pid exited.");

  # we need to wait for SIGCHLD in order to check
  # if execution was successful
  $self->{_senders}--;
  return $self->_validateSenderRun($wid);
}

sub _senderError {
  my ($self, $kernel, $operation, $errnum, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. ARG3];
  return 1 if ($errnum == 0);
  return 0 unless (exists($self->{_wsender}->{$wid}));
  my $s = $self->{_wsender}->{$wid};

  my $pid = $s->{pid};
  my $sid = $s->{sid};

  my $err = "Program $pid wheel $wid got error no $errnum during operation $operation: $errstr";

  # destroy anything containing
  $self->_destroySenderWheel($wid);

  # report failed storage operation
  $kernel->yield(STORE_ERR, $sid, $err);
}

sub _senderCHLD {
  my ($self, $kernel, $name, $pid, $exit_val) = @_[OBJECT, KERNEL, ARG0, ARG1, ARG2];

  # check exit status...
  unless ($u->evalExitCode($exit_val)) {
    $_log->warn($self->getStorageSignature()
        . "Zabbix sender child $pid exited with invalid exit code: "
        . $u->getError());
  }

  $kernel->sig_handled();

  # $self->_destroySenderPid($pid);
}

sub _destroySenderWheel {
  my ($self, $wid) = @_;
  return 0 unless (defined $wid);
  unless (exists($self->{_wsender}->{$wid})) {
    $_log->warn(
      $self->getStorageSignature() . "Unable to destroy zabbix sender wheel $wid: Wheel doesn't exist.");
    return 0;
  }

  # get the pid
  my $pid = $self->{_wsender}->{$wid}->{pid};

  # kill the pid (this is not necessary, but you never know...)
  kill(9, $pid);

  # destroy
  delete($self->{_wsender}->{$wid});
  delete($self->{_pid_wheel}->{$pid});

  # decrement sender counter
  #$self->{_senders}--;

  $_log->debug($self->getStorageSignature() . "Destroyed zabbix sender wheel $wid pid $pid");
}

sub _destroySenderPid {
  my ($self, $pid) = @_;
  return 0 unless (defined $pid);

  # get the wheel id...
  my $wid = $self->{_pid_wheel}->{$pid};

  # kill the pid (this is not necessary, but you never know...)
  kill(9, $pid);

  # destroy
  delete($self->{_wsender}->{$wid});
  delete($self->{_pid_wheel}->{$pid});

  # decrement sender counter
  #$self->{_senders}--;

  $_log->debug($self->getStorageSignature() . "Destroyed zabbix sender wheel $wid pid $pid");
}

sub _validateSenderRun {
  my ($self, $wid, $exit_val) = @_;
  $exit_val = 0 unless (defined $exit_val);

  # check for wheel validity...
  unless (defined $wid && exists($self->{_wsender}->{$wid})) {
    $_log->error($self->getStorageSignature() . "Invalid sender wheel: $wid");
    return 0;
  }

  my $s    = $self->{_wsender}->{$wid};
  my $sid  = $s->{sid};
  my $pid  = $s->{pid};
  my $file = $s->{file};

  # remove IO alarm for this wid
  my $alarm_id = $s->{alarm_id};
  if (defined $alarm_id) {
    $poe_kernel->alarm_remove($alarm_id);
  }

  # destroy wheel
  $self->_destroySenderPid($pid);

  # remove the file
  if (defined $file) {
    $_log->debug($self->getStorageSignature() . "Removing zabbbix_sender input file $file");
    unless (unlink($file)) {
      no warnings;
      $_log->error($self->getStorageSignature() . "Unable to remove zabbix_sender input file $file: $!");
    }
  }

  my $ok = $u->evalExitCode($exit_val);
  if ($ok) {
    my $msg = $s->{stdout};
    $msg =~ s/[\r\n]+/ /g;
    $_log->debug($self->getStoreSig($sid) . "Zabbix sender child $pid exited with successful exit code.");

  # check zabbix_sender output...
  # Info from server: "Processed 12 Failed 21 Total 33 Seconds spent 0.000371" sent: 33; skipped: 0; total: 33
    my $n_processed = 0;
    my $n_failed    = 0;
    my $n_total     = 0;
    if ($msg =~ m/processed\s*(\d+)\s*failed\s*(\d+)\s*total\s*(\d+)/i) {
      $n_processed = $1;
      $n_failed    = $2;
      $n_total     = $3;

      $msg = "processed: $n_processed; failed: $n_failed; total: $n_total";
    }

    # no processed items?!
    if ($n_processed < 1) {
      my $err = "Zabbix server didn't accept any parameter.";

      # report failed storage...
      $poe_kernel->yield(STORE_ERR, $sid, $err, $n_processed);
      return 1;
    }

    # report successfull storage...
    $poe_kernel->yield(STORE_OK, $sid, $msg);
  }
  else {
    my $err = $s->{stderr} . " " . $s->{stdout};
    $err =~ s/[\r\n]+/ /g;
    $_log->error(
      $self->getStoreSig($sid) . "Zabbix sender child $pid exited with invalid exit code: " . $u->getError());

    # report failed storage...
    $poe_kernel->yield(STORE_ERR, $sid, $err);
  }

  return 1;
}

sub _validateSenderRunByPid {
  my ($self, $pid) = @_;

  # get sender wheel id
  my $wid = undef;
  $wid = $self->{_pid_wheel}->{$pid} if (exists($self->{_pid_wheel}->{$pid}));
  return 0 unless (defined $wid);

  # check seder run by wheel id...
  return $self->_validateSenderRun($wid);
}

sub resolveZabbixServer {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  my $host = $self->{zabbixServer};
  if ($u->isIpv4Addr($host) || $u->isIpv6Addr($host)) {
    $_log->debug($self->getStorageSignature()
        . "Zabbix server hostname '$host' looks like IP address, skipping resolving process.");
    $self->{_zabbixServerAddr} = $host;
    return 1;
  }

  my @addrs = $u->resolveHost($self->{zabbixServer});
  unless (@addrs) {
    $_log->error("Unable to resolve zabbix server address: " . $!);
    return 0;
  }


  $_log->debug($self->getStorageSignature() . "Resolved addresses for host $self->{zabbixServer}: ",
    join(", ", @addrs));

  my $addr = shift(@addrs);
  $_log->debug($self->getStorageSignature() . "Assigning zabbix server $self->{zabbixServer} address: $addr");

  # re-enqueue
  $_log->debug($self->getStorageSignature()
      . "Next zabbix hostname resolution will start in "
      . DNS_RESOLVE_INT
      . " seconds.");
  $kernel->delay('resolveZabbixServer', DNS_RESOLVE_INT);

  return 1;
}

sub _zabbixTcpStore {
  my ($self, $kernel, $id, $data) = @_[OBJECT, KERNEL, ARG0, ARG1];

  my $addr          = $self->{_zabbixServerAddr};
  my $socket_domain = AF_INET;
  {
    no strict;
    no warnings;
    $socket_domain = ($_has_ipv6 && $u->isIpv6Addr($addr)) ? AF_INET6 : AF_INET;
  }

  # create tcp connection wheel
  $_log->debug($self->getStoreSig($id) . "Connecting to Zabbix server $addr port $self->{zabbixServerPort}.");
  my %opt = (
    Reuse         => 1,
    SocketDomain  => $socket_domain,
    RemoteAddress => $addr,
    RemotePort    => $self->{zabbixServerPort},
    SuccessEvent  => "_sockConnOk",
    FailureEvent  => "_sockConnErr",
  );

  my $wheel = POE::Wheel::SocketFactory->new(%opt);
  my $wid   = $wheel->ID();

  # save this wheel and wait for connection
  $self->{_tcp_wheel}->{$wid}
    = {wheel => $wheel, sid => $id, data => $data, rw_wid => undef, alarm_id => undef,};

  # increment senders count
  $self->{_senders}++;

  # wait for connection.
  return 1;
}

sub _sockConnOk {
  my ($self, $kernel, $sock, $addr, $port, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  if ($_log->is_debug()) {
    my $remote_ip = "";
    if (length($addr) > 4) {
      $remote_ip = Socket6::inet_ntop(AF_INET6, $addr);
    }
    else {
      $remote_ip = inet_ntoa($addr);
    }
    $_log->debug($self->getStorageSignature()
        . "Connection has been successfuly established with host $remote_ip port $port.");
  }

  # check if conn wheel is ok...
  unless (exists($self->{_tcp_wheel}->{$wid})) {
    $_log->warn($self->getStorageSignature() . "Invalid socket wheel: $wid");
    return 0;
  }

  # get storage id
  my $sid = $self->{_tcp_wheel}->{$wid}->{sid};

  # create rw/wheel on socket handle...
  my %opt = (
    Handle       => $sock,
    Driver       => POE::Driver::SysRW->new(BlockSize => 1024),
    Filter       => POE::Filter::Stream->new(),
    InputEvent   => "_sockInput",
    FlushedEvent => "_sockFlushed",
    ErrorEvent   => "_sockError",
  );
  if ($_log->is_trace) {
    $_log->trace($self->getStoreSig($sid) . "Creating zabbix server socket read-write wheel with options: ",
      $u->dumpVarCompact(\%opt));
  }
  my $rw     = POE::Wheel::ReadWrite->new(%opt);
  my $rw_wid = $rw->ID();
  $_log->debug($self->getStoreSig($sid) . "Created zabbix server socket read-write wheel id $rw_wid.");

  # get data...
  my $data = $self->getZabbixJsonStr($self->{_tcp_wheel}->{$wid}->{data});
  unless (defined $data) {
    $kernel->yield(STORE_ERR, $sid, $self->getError());
    return 0;
  }

  # enqueue data for writing...
  if ($_log->is_trace()) {
    $_log->trace($self->getStoreSig($sid) . "--- BEGIN ZABBIX JSON DATA ---\n" . $data);
    $_log->trace($self->getStoreSig($sid) . "--- END ZABBIX JSON DATA ---");
    $_log->trace($self->getStoreSig($sid) . "Enqueued to socket read-write wheel $rw_wid.");
  }
  else {
    if ($self->{debugData}) {
      $_log->info($self->getStoreSig($sid) . "--- BEGIN ZABBIX JSON DATA ---\n" . $data);
      $_log->info($self->getStoreSig($sid) . "--- END ZABBIX JSON DATA ---");
    }
  }
  $rw->put($data);

  # save the wheel...
  $self->{_wsender}->{$rw_wid}
    = {sid => $sid, wheel => $rw, sf_wid => $wid, stdout => '', error => undef, alarm_id => undef,};

  # mark ourselves in socketfactory wheel struct
  $self->{_tcp_wheel}->{$wid}->{rw_wid} = $rw_wid;

  # wait for server response
  return 1;
}

sub _sockConnErr {
  my ($self, $kernel, $operation, $errno, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  my $err
    = "Error $errno on zabbix server connection wheel $wid "
    . "[$self->{zabbixServer} port $self->{zabbixServerPort}]: "
    . $errstr;

  unless (exists($self->{_tcp_wheel}->{$wid})) {
    $_log->warn($self->getStorageSignature()
        . "Sock conn error $errno while operation $operation on non-existing"
        . " tcp wheel $wid: $errstr");
    return 0;
  }

  # get storage request id...
  my $sid = $self->{_tcp_wheel}->{$wid}->{sid};

  # get rw wheel id for this socketfactory...
  my $rw_wid = $self->{_tcp_wheel}->{$wid}->{rw_wid};

  if (defined $rw_wid) {
    $self->_validateTcpSenderRun($rw_wid);
  }
  else {

    # report failed storage
    $kernel->yield(STORE_ERR, $sid, $err);
  }

  # destroy the socketfactory wheel
  delete($self->{_tcp_wheel}->{$wid});

  # decrement number of senders
  $self->{_senders}--;

  return 1;
}

sub _sockInput {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  unless (exists($self->{_wsender}->{$wid})) {
    $_log->warn($self->getStorageSignature() . "Data from unknown zabbix server socket wheel: $wid");
    return 0;
  }

  if ($_log->is_trace()) {
    $_log->trace($self->getStorageSignature() . "Got ",
      length($data) . " bytes of data from zabbix server socket wheel $wid: " . $data);
  }

  # append data
  $self->{_wsender}->{$wid}->{stdout} .= $data;

  return 1;
}

sub _sockFlushed {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  if ($_log->is_trace()) {
    $_log->trace(
      $self->getStorageSignature() . "Zabbix server connection read-write wheel $wid was flushed.");
  }
}

sub _sockError {
  my ($self, $kernel, $operation, $errno, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  unless (exists($self->{_wsender}->{$wid})) {
    $_log->warn($self->getStorageSignature() . "Data from unknown zabbix server socket wheel: $wid");
    return 0;
  }

  my $sid = $self->{_wsender}->{$wid}->{sid};

  # errno == 0; this is usually EOF...
  if ($errno == 0) {

    # do nothing, just validate gathered data...
  }
  else {
    $self->{_wsender}->{$wid}->{error}
      = "Error $errno accoured while performing operation $operation on zabbix server socket wheel $wid: $errstr";
  }

  # clear buffers and disconnect from zabbix server
  return $self->_validateTcpSenderRun($wid);
}

sub _validateTcpSenderRun {
  my ($self, $wid) = @_;
  unless (exists($self->{_wsender}->{$wid})) {
    $_log->warn($self->getStorageSignature() . "Data from unknown zabbix server socket wheel: $wid");
    return 0;
  }

  # remove IO alarm for this wid
  if (defined $self->{_wsender}->{$wid}->{alarm_id}) {
    $poe_kernel->alarm_remove($self->{_wsender}->{$wid}->{alarm_id});
  }

  my $sid = $self->{_wsender}->{$wid}->{sid};

  # destroy socket factory wheel
  my $sf = $self->{_wsender}->{$wid}->{sf_wid};
  if (exists($self->{_tcp_wheel}->{$sf})) {
    $_log->trace($self->getStoreSig($sid) . "Deleting socketfactory wheel $sf");
    delete($self->{_tcp_wheel}->{$sf});
  }

  # check gathered data
  if (defined $self->{_wsender}->{$wid}->{error}) {

    # err is defined, our run was not successful.
    $poe_kernel->yield(STORE_ERR, $sid, $self->{_wsender}->{$wid}->{error});
  }
  else {

    # validate output...
    my $data = $self->{_wsender}->{$wid}->{stdout};
    if ($_log->is_trace()) {
      $_log->trace($self->getStoreSig($sid) . "--- BEGIN ZABBIX JSON RESPONSE ---\n" . $data);
      $_log->trace($self->getStoreSig($sid) . "--- END ZABBIX JSON RESPONSE ---");
    }
    my $response    = undef;
    my $n_processed = 0;
    my $n_failed    = 0;
    my $n_total     = 0;
    my $msg         = '';

    # "response":"success",
    if ($data =~ m/"response":"([^"]+)"/gm) {
      $response = lc($1);
    }

    # "info":"Processed 3 Failed 0 Total 3 Seconds spent 0.000167"}
    if ($data =~ m/"info":"Processed\s+(\d+)\s+Failed\s+(\d+)\s+Total\s+(\d+)/gim) {
      $n_processed = $1;
      $n_failed    = $2;
      $n_total     = $3;
      $msg         = "processed: $n_processed; failed: $n_failed; total: $n_total";
    }

    if (defined $response && $response eq 'success') {
      if ($n_processed < 1) {
        my $err = "Zabbix server didn't accept any parameter.";

        # report failed storage...
        $poe_kernel->yield(STORE_ERR, $sid, $err);
      }
      else {

        # report successful storage
        $poe_kernel->yield(STORE_OK, $sid, $msg, $n_processed);
      }
    }
    else {

      # report failed storage
      $poe_kernel->yield(STORE_ERR, $sid,
        "Invalid zabbix server output (" . length($data) . " bytes): " . $data);
    }
  }

  # destroy rw wheel
  delete($self->{_wsender}->{$wid});

  # decrement number of senders
  $self->{_senders}--;

  return 1;
}

# this function is perl implementation of function
# zbx_htole_uint64 found in zabbix 1.8.x distribution
# (File: ./src/libs/zbxcommon/comms.c, line 192)
sub _len2zbxlen {
  my ($len) = @_;
  my $r = '';

  # append data for each byte...
  for (1 .. 8) {
    $r .= sprintf("%c", $len);
    $len >>= 8;
  }

  return $r;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::ParsedData>
L<ACME::TC::Agent::Plugin::StatCollector::Storage>
L<ACME::TC::Agent::Plugin::StatCollector>
L<POE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
