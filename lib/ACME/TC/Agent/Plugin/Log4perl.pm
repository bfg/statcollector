package ACME::TC::Agent::Plugin::Log4perl;


use strict;
use warnings;

use POE;
use Log::Log4perl;
use POSIX qw(strftime);
use Time::HiRes qw(time);

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin);

use constant DEFAULT_CHECK_INTERVAL => 60;

our $VERSION = 0.03;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::Log4perlConfigReload

This plugin checks Log4perl configuration file for changes every
specified interval of seconds and reconfigures log4perl logging subsystem.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my %opt = (
		check_interval => 60,
		file => $file,
	);
	my $poe_session_id = $agent->pluginInit("Log4perlConfigReload", %opt);

B<Initialization via tc configuration>:

	{
		driver => 'Log4perlConfigReload',
		params => {
			check_interval => 60,
			file => $file,
		},
	},

=head1 CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=item B<check_interval> (integer, 60):

Log4perl configuration file check interval in seconds.

=item B<file> (string, ""):

Log4perl configuration file.

=item B<useUSR1> (boolean, 0):

Reload log4perl configuration on SIGUSR1 signal.

=over

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 METHODS

Methods marked with B<[POE]> can be invoked as POE events.

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  # "public" settings

  # default cache ttl
  $self->{check_interval} = DEFAULT_CHECK_INTERVAL;

  # log4perl configuration file
  $self->{file} = undef;

  # private stuff...

  $self->{_mtime} = 0;    # last file's mtime

  # exposed POE object events
  $self->registerEvent(
    qw(
      configCheck
      configReload
      sighReload
      )
  );

  return 1;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->info("Plugin '" . $self->_getBasePackage() . "' startup.");

  # sanity check...
  unless (defined $self->{file} && length($self->{file})) {
    $_log->error("Unspecified log4perl file. Shutting down the plugin");
    $kernel->yield("shutdown");
    return 0;
  }

  { no warnings; $self->{check_interval} = int($self->{check_interval}); }
  unless ($self->{check_interval} > 0) {
    $_log->error("Invalid check inteval: $self->{check_interval}; shutting down.");
    $kernel->yield("shutdown");
    return 0;
  }

  if ($self->{useUSR1}) {
    $_log->info("Installing SIGUSR1 signal handler.");
    $kernel->sig("USR1", 'sighReload');
  }

  # try to load anything from persistent cache file
  $_log->info("Checking Log4perl configuration file '$self->{file}' every $self->{check_interval} seconds.");
  $kernel->yield("configCheck");

  return 1;
}

sub sighReload {
  my ($self, $kernel, $sig) = @_[OBJECT, KERNEL, ARG0];
  return 0 unless (defined $sig);

  $_log->info("Got SIG${sig}; reloading log4perl configuration.");
  $kernel->yield('configReload');
  $kernel->sig_handled();

  return 1;
}

sub configCheck {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  my $ts = time();
  $_log->debug("Checking Log4perl configuration file '$self->{file}' for modifications.");

  # try to stat the file...
  my @s = stat($self->{file});
  unless (@s) {
    $_log->error("Error stat(2)-ing file '$self->{file}': $!");
    goto outta_check;
  }

  # check mtime...
  if (!defined $self->{_mtime} || $self->{_mtime} < 1) {
    $_log->info("First check, remembering modification time ("
        . strftime("%Y/%m/%d %H:%M:%S", localtime($s[9]))
        . ").");
    $self->{_mtime} = $s[9];
  }

  # was file modified?!
  elsif ($s[9] != $self->{_mtime}) {
    $_log->info("Log4perl configuration '$self->{file}' changed on "
        . strftime("%Y/%m/%d %H:%M:%S", localtime($s[9]))
        . ". Reloading.");

    $self->{_mtime} = $s[9];

    # schedule configuration reload...
    $kernel->yield("configReload");
  }

outta_check:
  my $t_diff = $self->{check_interval} - (time() - $ts);
  $_log->debug("Scheduling next check in $t_diff second(s).");
  $kernel->delay_add("configCheck", $t_diff);
  return 1;
}

sub configReload {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  unless (defined $self->{file}) {
    $_log->debug("Unable to reload undefined log4perl configuration file.");
    return 0;
  }
  unless (-f $self->{file} && -r $self->{file}) {
    $_log->error("Invalid log4perl configuration file: $self->{file}; skipping reload.");
    return 0;
  }

  $_log->debug("Reloading Log4perl configuration file '$self->{file}'.");

  # try to reconfigure logger...
  eval { Log::Log4perl->init($self->{file}); };

  if ($@) {
    $_log->error("Error reloading log4perl configuration from file '$self->{file}': $@");
    return 0;
  }

  $_log->info("Log4perl configuration successfully reloaded.");
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _shutdown {
  my ($self) = @_;
  if ($self->{useUSR1}) {
    $_log->info("Removing SIGUSR1 signal handler.");
    $poe_kernel->sig("USR1");
  }

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Plugin>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
