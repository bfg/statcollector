package ACME::TC::Agent::Plugin::StatCollector::Source::ExecSSH;


use strict;
use warnings;

use Log::Log4perl;

use POE;
use POE::Wheel::Run;

use ACME::TC::Agent::Plugin::StatCollector::Source::Exec;

use vars qw(@ISA);
use base qw(ACME::TC::Agent::Plugin::StatCollector::Source::Exec);

our $VERSION = 0.02;

my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Source::ExecSSH

External command statistics source via password-less SSH implementation.

=head1 DESCRIPTION

This source implementation is able to fetch statistics data by invoking external
programs or scripts and reading their output. 

=head1 WARNING

This module B<WILL NOT> work if password-less SSH login is not configured.
You B<MUST> enable ssh-key authentication between statistics collection host and monitored hosts!
For more info, see ssh-agent(1) and ssh(1) man pages.

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts all named parameters supported by 
L<ACME::TC::Agent::Plugin::StatCollector::Source> and
L<ACME::TC::Agent::Plugin::StatCollector::Source::Exec> plus the
following ones:

=over

=item B<hostname> (string, "localhost"):

Remote SSH hostname.

=item B<port> (interger, 22):

Remote SSH server port.

=item B<username> (string, undef):

Remote SSH hostname username.

=item B<command> (string, ""):

Command to execute.

=item B<sshAgentSocket> (string, undef):

Path to SSH agent socket if you want to use your own custom
spawned SSH agent instance.

=back

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{hostname}       = 'localhost';
  $self->{port}           = 22;
  $self->{username}       = '';
  $self->{command}        = '';
  $self->{sshAgentSocket} = undef;

  # must return 1 on success
  return 1;
}

sub getFetchUrl {
  my ($self) = @_;
  my $str = $self->{username} . '@' . $self->{hostname} . '/' . $self->{port};
  $str .= " " . $self->{command};

  return $str;
}

sub getPort {
  my ($self) = @_;
  return $self->{port};
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _run {
  my ($self) = @_;

  # check parent...
  return 0 unless ($self->SUPER::_run());

  # check username...
  unless (defined $self->{username} && length($self->{username}) > 0) {
    $self->{_error} = "Undefined username.";
    return 0;
  }
  if ($self->{username} =~ m/[^\w]+/) {
    $self->{_error} = "Username contains invalid characters.";
    return 0;
  }

  # check hostname
  unless (defined $self->{hostname} && length($self->{hostname}) > 0) {
    $self->{_error} = "Undefined SSH server hostname.";
    return 0;
  }
  if ($self->{hostname} =~ m/[^a-z0-9\.\-]+/i) {
    $self->{_error} = "Username contains invalid characters.";
    return 0;
  }

  # check port...
  { no warnings; $self->{port} = int($self->{port}); }
  if ($self->{port} < 1 || $self->{port} > 65635) {
    $self->{port} = 22;

    #$self->{_error} = "Invalid port number: $self->{port}";
    #return 0;
  }

  return 1;
}

sub _wheelCreate {
  my ($self) = @_;

  my $agent_sock_backup = undef;
  if (defined $self->{sshAgentSocket} && length($self->{sshAgentSocket})) {

    # backup old $SSH_AUTH_SOCK variable, if any
    if (exists($ENV{SSH_AUTH_SOCK}) && length($ENV{SSH_AUTH_SOCK}) > 0) {
      $agent_sock_backup = $ENV{SSH_AUTH_SOCK};
    }

    # install new one :)
    $_log->debug("Setting SSH_AUTH_SOCK variable to: '$self->{sshAgentSocket}'.");
    $ENV{SSH_AUTH_SOCK} = $self->{sshAgentSocket};
  }

  # run parent's method
  my $r = $self->SUPER::_wheelCreate();

  # restore old $SSH_AUTH_SOCK environment variable
  if (defined $agent_sock_backup) {
    $ENV{SSH_AUTH_SOCK} = $agent_sock_backup;
    $_log->debug("Restoring old SSH_AUTH_SOCK env variable to: '$agent_sock_backup'.");
  }

  # return result...
  return $r;
}

sub _getExecStr {
  my ($self) = @_;

  # get SSH string
  my $str = 'ssh';

  # port number
  $str .= ' -p ' . $self->{port} if ($self->{port} != 22);

  # Additional SSH options...

  # Username && hostname
  $str .= ' ' . $self->{username} . '@' . $self->{hostname};

  # Real real command...
  return $str . ' ' . $self->SUPER::_getExecStr();
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Source::Exec>
L<ACME::TC::Agent::Plugin::StatCollector::Source>
L<ACME::TC::Agent::Plugin::StatCollector>
L<POE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
