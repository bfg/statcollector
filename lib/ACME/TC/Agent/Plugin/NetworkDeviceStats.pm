package ACME::TC::Agent::Plugin::NetworkDeviceStats;


use strict;
use warnings;

use POE;
use IO::File;
use Log::Log4perl;
use Time::HiRes qw(time);

use ACME::TC::Agent::Plugin;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin);

use constant INTERVAL    => 5;
use constant PREFIX      => 'net.dev';
use constant FILE_NETDEV => '/proc/net/dev';

our $VERSION = 0.10;

my @_item_order = qw(
  rx_bytes rx_packets rx_errs rx_drop rx_fifo rx_frame rx_compressed rx_multicast
  tx_bytes tx_packets tx_errs tx_drop tx_fifo tx_colls tx_carrier tx_compressed

);

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::SocketStats

Linux network device statistics module.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my $poe_session_id = $agent->pluginInit("NetworkDeviceStats");

B<Initialization via tc configuration>:

	{
		driver => 'NetworkDeviceTracking',
		params => {
		},
	},


=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=over

=item B<interval> (integer, default: 20) Data refresh interval

=item B<context_path> (string, default: "/info/netdev"): Web interface path

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
  $self->{context_path} = "/info/netdev";

  # private settings
  $self->{_data} = {};

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

  return 1;
}

sub _statsRead {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  return if ($self->{_stopping});

  my $file = FILE_NETDEV;
  my $fd = IO::File->new($file, 'r');
  $_log->debug("Parsing network device statistics file $file.");
  unless (defined $fd) {
    $_log->error("Unable to open network device statistics file $file: $!");
    $kernel->yield('shutdown');
    return;
  }

  my $ts = time();

  # temporary data...
  my $tmpd = {};

  # read.
  while (<$fd>) {
    $_ =~ s/^\s+//g;
    $_ =~ s/\s+$//g;
    next if ($_ =~ m/\|/);

#Inter-|   Receive                                                |  Transmit
# face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
#    lo: 42558155   48353    0    0    0     0          0         0 42558155   48353    0    0    0     0       0          0
    my @tmp = split(/\s+/, $_);

    # remove : from device name...
    my $dev = shift(@tmp);
    $dev =~ s/:+//g;

    foreach my $e (@_item_order) {
      my $key = PREFIX . ".$e\[$dev\]";
      $tmpd->{$key} = shift(@tmp);
    }
  }

  # assign data
  %{$self->{_data}} = %{$tmpd};

  my $duration = time() - $ts;
  if ($_log->is_debug()) {
    $_log->debug("Network device statistics parsed in " . sprintf("%-.3f msec.", $duration * 1000));
  }

  # schedule next run
  $kernel->delay('_statsRead', ($self->{interval} - $duration));

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
