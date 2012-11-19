package ACME::TC::Agent::Plugin::SocketStats;


use strict;
use warnings;

use POE;
use IO::File;
use Log::Log4perl;
use File::Basename;
use POE::Filter::Line;
use Time::HiRes qw(time);
use POE::Wheel::ReadWrite;

use ACME::TC::Agent::Plugin;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin);

use constant INTERVAL => 5;
use constant PREFIX   => 'net.socket';

our $VERSION = 0.10;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

# states from /usr/include/netinet/tcp.h
my $_states_tcp = {
  1  => 'ESTABLISHED',
  2  => 'SYN_SENT',
  3  => 'SYN_RECV',
  4  => 'FIN_WAIT1',
  5  => 'FIN_WAIT2',
  6  => 'TIME_WAIT',
  7  => 'CLOSE',
  8  => 'CLOSE_WAIT',
  9  => 'LAST_ACK',
  10 => 'LISTEN',
  11 => 'CLOSING',       # now a valid state
};

my $_states_unix = {1 => 'LISTENING', 3 => 'CONNECTED',};

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::SocketStats

Linux socket statistics module.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my $poe_session_id = $agent->pluginInit("SocketStats");

B<Initialization via tc configuration>:

	{
		driver => 'ConnectionTracking',
		params => {
		},
	},


=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=over

=item B<interval> (integer, default: 20) Data refresh interval

=item B<context_path> (string, default: "/info/sockets"): Web interface path

=back

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
      _statsRead
      _evInput
      _evError
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

  # fetch interval
  $self->{interval} = INTERVAL;

  # context path
  $self->{context_path} = "/info/sockets";

  # private settings
  $self->{_data}     = {};
  $self->{_data_tmp} = {};
  $self->{_wheels}   = {};
  $self->{_acc}      = [];

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
      args    => {session => $self->getSessionId(), prefix => '',},
    );
  }
  else {
    $_log->error("Error mounting context: " . $self->{_error});
  }

  # let's get to the point...
  $kernel->yield("_statsRead");

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
  %{$data} = %{$self->{_data}};

  return $data;
}

=item dataReset () [POE]

Resets internal data structure, erasing all gathered data. Always returns 1.

=cut

sub dataReset {
  my ($self, $kernel, $sender) = @_[OBJECT, KERNEL, SENDER];
  $self->{_data} = {};
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _shutdown {
  my $self = shift;

  # set stopping flag...
  $self->{_stopping} = 1;

  # remove server handler
  my $agent = $self->getAgent();
  if (defined $agent) {
    $agent->connectorUmountContext($self->{context_path});
  }

  # destroy all the wheels...
  map { delete($self->{_wheels}->{$_}) } keys %{$self->{_wheels}};

  return 1;
}

sub _statsRead {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  return if ($self->{_stopping});
  if (%{$self->{_wheels}}) {
    $_log->warn("Still reading stats, aborting new statistics read cycle.");
    return 1;
  }

  # destroy old tmp data...
  $self->{_data_tmp} = {};

  $self->{_read_start_time} = time();
  $_log->debug("Reading socket statistics.");

  # start async status file parsing...
  $self->_parseFile('/proc/net/tcp');
  $self->_parseFile('/proc/net/tcp6');
  $self->_parseFile('/proc/net/udp');
  $self->_parseFile('/proc/net/udp6');
  $self->_parseFile('/proc/net/raw');
  $self->_parseFile('/proc/net/raw6');
  $self->_parseFile('/proc/net/unix');
  $self->_parseFile('/proc/net/udplite');

  return 1;
}

sub _parseFile {
  my ($self, $file) = @_;

  # open it...
  my $fd = IO::File->new($file, 'r');
  $_log->debug("Opening file: $file");
  unless (defined $fd) {
    $_log->debug("Unable to open file $file for reading: $!");
    return;
  }

  # create wheel
  my $wheel = POE::Wheel::ReadWrite->new(
    Handle     => $fd,
    Filter     => POE::Filter::Line->new(),
    InputEvent => '_evInput',
    ErrorEvent => '_evError',
  );

  my $wid   = $wheel->ID();
  my $proto = basename($file);

  # save wheel
  $self->{_wheels}->{$wid} = {wheel => $wheel, file => $file, proto => $proto,};
}

sub _evInput {
  my ($self, $data, $wid) = @_[OBJECT, ARG0 .. $#_];
  return unless (exists $self->{_wheels}->{$wid});
  my $proto = $self->{_wheels}->{$wid}->{proto};
  return $self->_parseLine($proto, $data);
}

sub _evError {
  my ($self, $kernel, $operation, $errno, $error, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  unless ($errno == 0) {
    $_log->error("Error $errno on wheel $wid while performing operation $operation: $error");
  }

  # destroy wheel
  delete($self->{_wheels}->{$wid});

  # no more wheels?
  # looks like we read everything and this parsing cycle is over
  unless (%{$self->{_wheels}}) {
    my $duration = time() - $self->{_read_start_time};
    $_log->debug("Socket statistics parsed in " . sprintf("%-.3f msec.", $duration * 1000));

    # install tmpdata
    %{$self->{_data}} = %{$self->{_data_tmp}};

    # schedule next read interval...
    $kernel->delay('_statsRead', $self->{interval} - $duration);
  }
}

sub _parseLine {
  my ($self, $proto, $line) = @_;
  $line =~ s/^\s+//g;
  return if ($line =~ m/^(?:sl|num)\s+/i);

  my $key = PREFIX . '.' . $proto;
  $self->{_data_tmp}->{$key}++;

  if ($proto =~ m/^tcp/) {
    my @tmp = split(/\s+/, $line);

# sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
# 0: 00000000:0610 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 5328869 1 ffff81002279ec00 750 0 0 2 -1
    my $state_hex = $tmp[3];
    my $state     = hex($state_hex);
    my $state_str = (exists $_states_tcp->{$state}) ? lc($_states_tcp->{$state}) : 'invalid';

    #print "State_hex [$proto] $state_hex => $state => $state_str\n";

    $key .= '.' . $state_str;
    $self->{_data_tmp}->{$key}++;
  }
  elsif ($proto eq 'unix') {
    my @tmp = split(/\s+/, $line);

    # Num       RefCount Protocol Flags    Type St Inode Path
    # ffff81003cbcfa00: 00000002 00000000 00010000 0001 01 6977292 /tmp/ssh-hnmgVd6813/agent.6813
    # ffff810025ad7a00: 00000002 00000000 00010000 0001 01 3628896 /dev/log
    #return unless ($tmp[7] && length $tmp[7] > 0);

    my $state = hex($tmp[5]);
    my $state_str = (exists $_states_unix->{$state}) ? lc($_states_unix->{$state}) : 'invalid';

    $key .= '.' . $state_str;
    $self->{_data_tmp}->{$key}++;
  }
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
