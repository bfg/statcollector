package ACME::TC::Agent::Plugin::ConnectionTracking;


use strict;
use warnings;

use POE;
use IO::File;
use Log::Log4perl;
use POE::Filter::Stream;
use Time::HiRes qw(time);
use POE::Wheel::ReadWrite;

use ACME::TC::Agent::Plugin;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin);

use constant INTERVAL            => 50;
use constant PREFIX              => 'net.conntrack';
use constant CONNTRACK_FILE      => '/proc/net/nf_conntrack';
use constant CONNTRACK_STAT_FILE => '/proc/net/stat/nf_conntrack';

our $VERSION = 0.10;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::ConnectionTracking

Linux nf_conntrack statistics module. Collects L<Linux netfilter|http://netfilter.org/> connection
tracking module statistics.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my $poe_session_id = $agent->pluginInit("ConnectionTracking");

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
      _conntrackRun
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
  $self->{context_path} = "/info/conntrack";

  # private settings
  $self->{_data}     = {};
  $self->{_data_tmp} = {};
  $self->{_wheel}    = undef;
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
  $kernel->yield("_conntrackRun");

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

  # destroy the wheel...
  undef $self->{_wheel};

  return 1;
}

sub _conntrackRun {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $kernel->yield('_statsRead');
  return 1;
}

sub _statsRead {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  return if ($self->{_stopping});
  if ($self->{_wheel}) {
    $_log->warn("Still reading stats, aborting new statistics read cycle.");
    return 1;
  }

  # destroy old tmp data...
  $self->{_data_tmp} = {};

  $self->{_read_start_time} = time();

  # parse connection tracking subsystem data...
  $self->_parseStatFile();

  my $file = CONNTRACK_FILE;
  $_log->debug("Starting new connection tracking read operation, file: $file .");

  # try to open file
  my $fd = IO::File->new($file, 'r');
  unless (defined $fd) {
    $_log->error("Unable to open connection tracking file $file for reading: $!");
    $kernel->yield("shutdown");
    return 1;
  }

  # create wheel
  my $wheel = POE::Wheel::ReadWrite->new(
    Handle     => $fd,
    Filter     => POE::Filter::Stream->new(),
    InputEvent => '_evInput',
    ErrorEvent => '_evError',
  );
  $self->{_wheel} = $wheel;
  $_log->debug("Successfully opened connection tracking file $file and create POE RW wheel " . $wheel->ID());
  return 1;
}

sub _evInput {
  my ($self, $data, $wid) = @_[OBJECT, ARG0 .. $#_];
  return $self->_parseConntrackData($data);
}

sub _evError {
  my ($self, $kernel, $operation, $errno, $error, $wid) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  unless ($errno == 0) {
    $_log->error("Error $errno on wheel $wid while performing operation $operation: $error");
  }

  my $duration = time() - $self->{_read_start_time};
  $_log->debug("Connection tracking table parsed in " . sprintf("%-.3f msec.", $duration * 1000));

  # destroy wheel
  undef $self->{_wheel};

  # install tmpdata
  %{$self->{_data}} = %{$self->{_data_tmp}};

  # schedule next read interval...
  $kernel->delay('_statsRead', $self->{interval} - $duration);
}

# parses /proc/net/stats/nf_conntrack
sub _parseStatFile {
  my ($self) = @_;
  my $ts = ($_log->is_debug()) ? time() : 0;
  my $file = CONNTRACK_STAT_FILE;
  $_log->debug("Parsing connection tracking statistics file $file.");
  my $fd = IO::File->new($file);
  unless (defined $fd) {
    $_log->debug("Unable to open connection tracking statistics file $file: $!");
    return;
  }
  my @order = ();
  my $num   = 0;
  while (<$fd>) {
    $_ =~ s/^\s+//g;
    $_ =~ s/\s+$//g;
    $num++;

#print "READ: $_\n";
#entries  searched found new invalid ignore delete delete_list insert insert_failed drop early_drop icmp_error  expect_new expect_create expect_delete search_restart
#0000003e  00000b47 002ac6b0 00045652 00000d86 000080c2 000443ef 00004af3 00005d56 00000000 00000000 00000000 0000027b  00000000 00000000 00000000 00000000
#0000003e  00002ff5 004a157d 00158c6a 0000209e 00006597 00159e8f 00007398 00006173 00000000 00000000 00000000 00000166  00000000 00000000 00000000 00000000
    if ($_ =~ m/^entries\s+/i) {
      @order = split(/\s+/, $_);
      next;
    }
    my @data = map { hex($_) } split(/\s+/, $_);
    for (my $i = 0; $i <= $#order; $i++) {
      my $key = PREFIX . '.stats.' . $order[$i];
      $self->{_data_tmp}->{$key} = $data[$i];
    }
    last if ($num >= 3);
  }

  if ($_log->is_debug()) {
    my $duration = time() - $ts;
    $_log->debug("Connection tracking statistics parsed in " . sprintf("%-.3f msec.", $duration * 1000));
  }
}

sub _parseConntrackData {
  my ($self, $data) = @_;

  #
  # Q: WHY such stupid way of parsing nf_conntrack entries?
  # A: Looks like OpenSUSE 11.4 (kernel 2.6.37) contains nf_conntrack file
  #    in single line with no obvious special entry separators.

  my @tmp = split(/\s+/, $data);
  while (@tmp) {
    my $e = shift(@tmp);
    if ($e =~ m/^ipv\d+/i) {
      if (@{$self->{_acc}}) {

        # process accumulator...

        # ipv4     2 tcp      6 54 TIME_WAIT src=10.8.254.1
        # ipv4     2 tcp      6 12 TIME_WAIT src=10.9.0.16
        # ipv4     2 tcp      6 431998 ESTABLISHED src=10.8.1.19
        my $family = $self->{_acc}->[0];
        $family = lc($family) if (defined $family);
        my $proto = $self->{_acc}->[2];
        $proto = lc($proto) if (defined $proto);
        next unless (defined $family && defined $proto);
        my $state = $self->{_acc}->[5];
        $state = lc($state) if (defined $state);

        my $key = PREFIX . '.family.' . $family;
        $self->{_data_tmp}->{$key}++;
        $key .= "." . $proto;
        $self->{_data_tmp}->{$key}++;

        if ($proto eq 'tcp') {
          $key .= "." . $state;
          $self->{_data_tmp}->{$key}++;
        }

        # clear accumulator
        @{$self->{_acc}} = ();
      }
    }
    push(@{$self->{_acc}}, $e);
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
