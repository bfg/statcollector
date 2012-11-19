package ACME::TC::Agent::Plugin::StatCollector::Source::MySQL;


use strict;
use warnings;

use Log::Log4perl;

use POE;
use POSIX;
use POE::Wheel::Run;

use ACME::TC::Agent::Plugin::StatCollector::Source::Exec;

use vars qw(@ISA);
use base qw(ACME::TC::Agent::Plugin::StatCollector::Source::Exec);

our $VERSION = 0.02;

my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Source::MySQL

MySQL statistics sources.

=head1 DESCRIPTION

This source implementation is able to fetch statistics data extra process
which queries MySQL for statistics data. Requires L<DBI> and L<DBD::mysql>
perl modules.

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

MySQL server hostname.

=item B<port> (interger, 3306):

MySQL server port.

=item B<username> (string, undef):

MySQL server username.

=item B<password> (string, undef):

MySQL server password.

=back

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());
  delete($self->{command});

  $self->{hostname} = 'localhost';
  $self->{port}     = 3306;
  $self->{username} = undef;
  $self->{password} = undef;

  # must return 1 on success
  return 1;
}

sub getFetchUrl {
  my ($self) = @_;
  no warnings;
  return $self->{username} . '@' . $self->{hostname} . ':' . $self->{port};
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
  $self->{command} = 'xxx';

  # check parent...
  return 0 unless ($self->SUPER::_run());
  delete($self->{command});

  # check username...
  unless (defined $self->{username} && length($self->{username}) > 0) {
    $self->{_error} = "Undefined username.";
    return 0;
  }
  if ($self->{username} =~ m/[^\w]+/) {
    $self->{_error} = "Username contains invalid characters.";
    return 0;
  }

  # check password
  unless (defined $self->{password} && length($self->{password}) > 0) {
    $self->{_error} = "Undefined password.";
    return 0;
  }

  # check hostname
  unless (defined $self->{hostname} && length($self->{hostname}) > 0) {
    $self->{_error} = "Undefined MySQL server hostname.";
    return 0;
  }

  # check port...
  { no warnings; $self->{port} = int($self->{port}); }
  if ($self->{port} < 1 || $self->{port} > 65635) {
    $self->{port} = 3306;
  }

  # we don't want to ignore stderr..
  $self->{ignoreStderr} = 0;

  # we want exit code evaluation
  $self->{requiredExitCode} = 0;

  return 1;
}

sub _getExecStr {
  my ($self) = @_;

  # return anonymous code reference...
  return sub {
    __fetch_perform($self->{hostname}, $self->{port}, $self->{username}, $self->{password});
  };
}

sub __fetch_perform {
  my ($host, $port, $user, $passwd) = @_;

  # load DBI
  eval { require DBI; };
  if ($@) {
    my $err = "Unable to load DBI perl module: $@";
    $_log->error($err);
    print STDERR $err, "\n";
    POSIX::_exit 1;
  }

  # build DSN
  my $dsn = 'DBI:mysql:host=' . $host;
  $dsn .= ';port=' . $port if (defined $port);

  # connect
  $_log->debug("Connecting: dsn: $dsn; username: $user");
  my $conn = DBI->connect($dsn, $user, $passwd, {RaiseError => 0, PrintError => 0});
  unless (defined $conn) {
    my $err = "Error connecting to '$dsn': " . DBI->errstr();
    $_log->error($err);
    print STDERR $err, "\n";
    POSIX::_exit 1;
  }
  $_log->debug("Connection established.");

  # prepare SQL statement...
  my $stmt = $conn->prepare('SHOW GLOBAL STATUS');
  unless (defined $stmt) {
    my $err = "Error preparing SQL: " . $conn->errstr();
    $_log->error($err);
    print STDERR $err, "\n";
    POSIX::_exit 1;
  }
  $_log->debug("SQL query compiled.");

  # execute SQL
  my $r = $stmt->execute();
  unless (defined $r) {
    my $err = "Error executing SQL: " . $conn->errstr();
    $_log->error($err);
    print STDERR $err, "\n";
    POSIX::_exit 1;
  }
  $_log->debug("SQL query executed.");

  # read data...
  while (defined(my $row = $stmt->fetchrow_arrayref())) {
    my $key = $row->[0];
    my $val = $row->[1];
    next unless (defined $key && defined $val);
    $key = lc($key);
    $key =~ s/_/\./g;
    print "$key: $val\n";
  }
  $_log->debug("Result rowset read.");

  # disconnect...
  $conn->disconnect();
  $_log->debug("Disconnected.");

  POSIX::_exit 0;
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
