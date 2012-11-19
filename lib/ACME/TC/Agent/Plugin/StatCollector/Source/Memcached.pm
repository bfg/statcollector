package ACME::TC::Agent::Plugin::StatCollector::Source::Memcached;


use strict;
use warnings;

use POE;
use Log::Log4perl;

use ACME::TC::Agent::Plugin::StatCollector::Source;
use ACME::TC::Agent::Plugin::StatCollector::Source::_Socket;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Source::_Socket);

our $VERSION = 0.02;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Source::Memcached

Memcached statistics source.

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts all named parameters supported by 
L<ACME::TC::Agent::Plugin::StatCollector::Source>, 
L<ACME::TC::Agent::Plugin::StatCollector::Source::_Socket>
and the following ones:

=over

=item B<address> (string, "localhost:11211")

Memcached <hostname>:<port number> address.

=back

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{address} = "localhost:11211";

  $self->{_data} = "";
  $self->{_host} = undef;
  $self->{_port} = 11211;

  # must return 1 on success
  return 1;
}


sub getFetchUrl {
  my ($self) = @_;
  return $self->{address};
}

sub getHostname {
  my ($self) = @_;
  return $self->{_host};
}

sub getPort {
  my ($self) = @_;
  return $self->{_port};
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _run {
  my ($self) = @_;

  # check address
  unless (defined $self->{address} && length($self->{address})) {
    $self->{_error} = "Undefined address.";
    return 0;
  }

  # parse address
  my ($host, $port) = split(/:/, $self->{address}, 2);
  unless (defined $host && length($host) > 0) {
    $self->{_error} = "Invalid hostname.";
    return 0;
  }

  # check port
  { no warnings; $port = int($port); };
  if ($port < 1 || $port > 65536) {
    $port = 11211;
  }

  $self->{_host} = $host;
  $self->{_port} = $port;

  # everything is ok, start fetching data...
  return 1;
}

sub _fetchStart {
  my ($self) = @_;

  # connect
  $poe_kernel->yield("connect", $self->{_host}, $self->{_port});
  return 1;
}

sub _fetchCancel {
  my ($self) = @_;
  $_log->debug($self->getFetchSignature(), " Got cancel request.");
  $poe_kernel->call($poe_kernel->get_active_session(), "disconnect");
  $self->{_data} = "";
  return 1;
}

sub _connOk {
  my ($self) = @_;

  # connection succeeded, huh, rw wheel created, well,
  # send "stats" command and wait for results...
  $poe_kernel->yield("sendData", "stats");
  return 1;
}

sub rwInput {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];
  $_log->trace($self->getFetchSignature(), " Server: $data");

  $data =~ s/^\s+//g;
  $data =~ s/\s+$//g;
  return 0 unless (length($data) > 0);

  # end of statistics?!
  if (lc($data) eq 'end') {

    # send command to reset data...
    $kernel->yield("sendData", "stats reset");
    return 1;
  }

  # last command was reset?!
  elsif (lc($data) eq 'reset') {

    # this is it!
    $kernel->yield(FETCH_OK, $self->{_data});
    $self->{_data} = "";

    # disconnect...
    $kernel->yield("disconnect");
    return 1;
  }
  elsif (lc($data) eq 'error') {
    return 1;
  }
  else {
    my @tmp = split(/\s+/, $data);
    shift @tmp;
    $self->{_data} .= join("=", @tmp) . "\n";
  }
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent::Plugin::StatCollector::Source::_Socket>
L<ACME::TC::Agent::Plugin::StatCollector::Source>
L<ACME::TC::Agent::Plugin::StatCollector>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
