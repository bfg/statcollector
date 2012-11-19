package ACME::TC::Agent::Connector::HTTP;


use strict;
use warnings;

use POE;
use Data::Dumper;
use File::Spec;
use Log::Log4perl;

use POE::Component::Server::HTTPEngine;
use ACME::TC::Agent::Connector;

use base qw(ACME::TC::Agent::Connector);

our $VERSION = 0.03;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Connector::HTTP

Receive tc agent commands via HTTP! 

=head1 SYNOPSIS

B<Initialization from perl code>:

	my %opt = (
		port => 8007,
		contexts => [
			{
				uri => '/something',
				handler => 'FS',
				args => {
					path => '/tmp',
				}
			},
		],
	);
	my $poe_session_id = $agent->connectorInit("HTTP", %opt);

B<Initialization via tc configuration>:

	{
		driver => 'HTTP',
		params => {
			port => 8007,
			contexts => [
				{
					uri => '/something',
					handler => 'FS',
					args => {
						path => '/tmp',
					}
				},
			],
		},
	},

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Connector> and the following ones:

=item B<addr> (string, "*"):

HTTP server listening address. "*" means that http server will try to listen
on all available IPv4 AND IPv6 addresses.

=item B<port> (integer, 8000):

HTTP server listening port.

=item B<ssl> (boolean, 0):

Enable SSL engine if available?

=item B<ssl_cert> (string, undef):

x509 certificate file.

=item B<ssl_key> (string, undef): 

x509 certificate key file.

=item B<contexts> (array reference, []):

Pre-mount specified contexts just after connector startup.

=item B<access_log> (string, undef):

Access log destination. Value can be set to filename, if it's prefixed with B<'|'> character, logging will
be done by invoking external program, if is it form B<'session:event'> message will be sent to POE session
B<session>, event B<event>.

=item B<error_log> (string, undef):

Error log destination. Value can be set to filename, if it's prefixed with B<'|'> character, logging will
be done by invoking external program, if is it form B<'session:event'> message will be sent to POE session
B<session>, event B<event>. 

=over

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub allowMultipleInstances {
  return 0;
}

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # "public" settings
  $self->{addr} = '*', $self->{port} = 8000;
  $self->{ssl} = 0;
  $self->{ssl_cert}   = undef;
  $self->{ssl_key}    = undef;
  $self->{access_log} = undef;
  $self->{error_log}  = undef;
  $self->{contexts}   = [];

  # private settings

  # server object...
  $self->{_httpd} = undef;

  # server session id...
  $self->{_httpd_session} = undef;

  return 1;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->debug("Invoking run().");
  if (defined $self->{_httpd}) {
    $_log->error("Server is already started.");
    return 0;
  }

  $_log->info("Starting connector: " . $self->_getBasePackage());

  # create http server object...
  $self->{_httpd} = POE::Component::Server::HTTPEngine->new(
    addr       => $self->{addr},
    port       => $self->{port},
    ssl        => $self->{ssl},
    ssl_cert   => $self->{ssl_cert},
    ssl_key    => $self->{ssl_key},
    access_log => $self->{access_log},
    error_log  => $self->{error_log},
  );

  unless (defined $self->{_httpd}) {
    $self->{_error} = "Unable to create http server object: " . ACME::Server::HTTP->getError();
    $_log->error($self->{_error});
    return 0;
  }

  # mount server contexts...
  $_log->debug("Mounting server contexts.");
  foreach my $ctx (@{$self->{contexts}}) {
    next unless (defined $ctx && ref($ctx) eq 'HASH');
    unless ($self->{_httpd}->mount($ctx)) {
      $_log->error($self->{_httpd}->getError());
    }
  }

  # start the server
  $_log->info("Starting HTTP server.");
  my $session_id = $self->{_httpd}->spawn();

  unless ($session_id) {
    $self->{_error} = "Unable to spawn http server: " . $self->{_httpd}->getError();
    delete($self->{_httpd});
    return 0;
  }

  $self->{_httpd_session} = $session_id;
  return $session_id;
}

sub mount {
  my $self = undef;
  my @args;
  my $num       = 0;
  my ($package) = caller();
  my $poe       = ($package =~ m/^POE::Sess/) ? 1 : 0;
  if ($poe) {
    $self = $_[OBJECT];
    @args = @_[ARG0 .. $#_];
  }
  else {
    $self = shift;
    @args = @_;
  }

  $self->{_error} = "";

  $_log->debug("Mounting context.");
  my $r = $self->{_httpd}->mount(@args);
  $self->{_error} = $self->{_httpd}->getError() unless ($r);

  return $r;
}

sub umount {
  my ($self, $ctx) = @_;
  $_log->debug("Unmounting context: $ctx");
  my $r = $self->{_httpd}->umount(uri => $ctx);
  $self->{_error} = $self->{_httpd}->getError() unless ($r);
  return $r;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _child {
  my ($self, $kernel, $reason, $child) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # kill ourselves if our http server died.
  if (defined $self->{_httpd_session} && $self->{_httpd_session} == $child->ID() && $reason eq 'lose') {
    $_log->error("HTTP server stopped; shutting down.");
    $kernel->yield('shutdown');
  }
}

sub _shutdown {
  my $self = shift;

  if (defined $self->{_httpd}) {
    $_log->info("Shutting down HTTP engine.");
    $poe_kernel->call($self->{_httpd_session}, "shutdown");
    delete($self->{_httpd});
    delete($self->{_httpd_session});
  }
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Connector::EXAMPLE>
L<POE::Component::Server::HTTPEngine>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
