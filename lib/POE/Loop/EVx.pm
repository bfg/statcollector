package POE::Loop::EVx;

# EV.pm (libev) event loop bridge


use strict;

our $VERSION = '0.06';

# Everything plugs into POE::Kernel.
package    # hide me from PAUSE
  POE::Kernel;

use strict;

# require POE::Loop::PerlSignals;


use EV;
use POE::Kernel;

# Loop debugging
sub EV_DEBUG () { $ENV{POE_EV_DEBUG} || 0 }

# Global EV timer object
my $_watcher_timer;

# Global SIGCHLD watcher
my $_child_watcher;

# Global list of EV signal objects
my %signal_events;

# Global list of EV filehandle objects, indexed by fd number
my @fileno_watcher;

my $DIE_MESSAGE;

############################################################################
# Initialization, Finalization, and the Loop itself
############################################################################

sub loop_initialize {
  my $self = shift;

  if (EV_DEBUG) {
    my $methods = {
      EV::BACKEND_SELECT()  => 'select',
      EV::BACKEND_POLL()    => 'poll',
      EV::BACKEND_EPOLL()   => 'epoll',
      EV::BACKEND_KQUEUE()  => 'kqueue',
      EV::BACKEND_DEVPOLL() => 'devpoll',
      EV::BACKEND_PORT()    => 'port',
    };

    warn "loop_initialize, EV is using method: " . $methods->{EV::backend()} . "\n";
  }

  # Set up the global timer object
  $_watcher_timer = EV::periodic_ns(0, 0, 0, \&_loop_timer_callback);

  # Set up the callback for SIGCHLD
  $_child_watcher = EV::child(0, 0, \&_child_callback);

  $EV::DIED = \&_die_handler;
}

# Timer callback to dispatch events.
my $last_time = time();

sub _loop_timer_callback {
  my $self = $poe_kernel;

  EV_DEBUG && warn "_loop_timer_callback, at " . time() . "\n";

  if (TRACE_STATISTICS) {
    $self->_data_stat_add('idle_seconds', time() - $last_time);
  }

  $self->_data_ev_dispatch_due();
  $self->_test_if_kernel_is_idle();

  # Transferring control back to EV; this is idle time.
  $last_time = time() if TRACE_STATISTICS;
}

sub loop_finalize {
  EV_DEBUG && warn "loop_finalize\n";

  foreach my $fd (0 .. $#fileno_watcher) {
    next unless defined $fileno_watcher[$fd];
    foreach my $mode (EV::READ, EV::WRITE) {
      if (defined $fileno_watcher[$fd]->[$mode]) {
        POE::Kernel::_warn("Mode $mode watcher for fileno $fd is defined during loop finalize");
      }
    }
  }

  loop_ignore_all_signals();
}

sub loop_attach_uidestroy {

  # does nothing, no UI
}

sub loop_do_timeslice {

  # does nothing
}

sub loop_run {
  EV_DEBUG && warn "loop_run\n";

  EV::loop();

  if (defined $DIE_MESSAGE) {
    my $message = $DIE_MESSAGE;
    undef $DIE_MESSAGE;
    die $message;
  }
}

sub loop_halt {
  EV_DEBUG && warn "loop_halt\n";

  $_watcher_timer->stop();
  undef $_watcher_timer;

  EV::unloop();
}

sub _die_handler {
  EV_DEBUG && warn "_die_handler( $@ )\n";

  # EV doesn't let you rethrow an error here, so we have
  # to stop the loop and get the error later
  $DIE_MESSAGE = $@;

  # This will cause the EV::loop call in loop_run to return,
  # and cause the process to die.
  EV::unloop();
}

############################################################################
# Signal Handling
############################################################################
#=pod
sub loop_watch_signal {
  my ($self, $signame) = @_;

  # Child process has stopped.
  # XXX: libev always sets a SIGCHLD handler
  if ($signame eq 'CHLD' or $signame eq 'CLD') {
    $_child_watcher->start();

    return;
  }

  EV_DEBUG && warn "loop_watch_signal( $signame )\n";

  $signal_events{$signame} ||= EV::signal(
    $signame,
    sub {
      if (TRACE_SIGNALS) {
        my $pipelike = $signame eq 'PIPE' ? 'PIPE-like' : 'generic';
        POE::Kernel::_warn "<sg> Enqueuing $pipelike SIG$signame event";
      }

      EV_DEBUG && warn "_loop_signal_callback( $signame )\n";

      $poe_kernel->_data_ev_enqueue($poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [$signame], __FILE__,
        __LINE__, undef, time());
    },
  );
}

sub loop_ignore_signal {
  my ($self, $signame) = @_;

  # print "loop_ignore_signal: $signame\n";

  if ($signame eq 'CHLD' or $signame eq 'CLD') {
    if ($_child_watcher) {
      $_child_watcher->stop();
    }

    return;
  }

  if (defined $signal_events{$signame}) {
    $signal_events{$signame}->stop();
  }
}

sub loop_ignore_all_signals {
  my $self = shift;

  map { $_->stop() if defined $_ } values %signal_events;

  %signal_events = ();

  if ($_child_watcher) {
    $_child_watcher->stop();
  }
}

sub _child_callback {
  my $w = shift;

  my $pid    = $w->rpid;
  my $status = $w->rstatus;

  EV_DEBUG && warn "_child_callback( $pid, $status )\n";

  if (TRACE_SIGNALS) {
    POE::Kernel::_warn("<sg> POE::Kernel detected SIGCHLD (pid=$pid; exit=$status)");
  }

  # Check for explicit SIGCHLD watchers, and enqueue explicit
  # events for them.
  if (exists $poe_kernel->[KR_PIDS]->{$pid}) {
    my @sessions_to_clear;
    while (my ($ses_key, $ses_rec) = each %{$poe_kernel->[KR_PIDS]->{$pid}}) {
      $poe_kernel->_data_ev_enqueue(
        $ses_rec->[0], $poe_kernel, $ses_rec->[1], ET_SIGCLD,
        ['CHLD', $pid, $status], __FILE__, __LINE__, undef,
        time(),
      );
      push @sessions_to_clear, $ses_rec->[0];
    }
    $poe_kernel->_data_sig_pid_ignore($_, $pid) foreach @sessions_to_clear;
  }

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL,
    ['CHLD', $pid, $status], __FILE__, __LINE__, undef,
    time()
  );
}

# =cut

############################################################################
# Timer code
############################################################################

sub loop_resume_time_watcher {
  my ($self, $next_time) = @_;
  ($_watcher_timer and $next_time) or return;

  EV_DEBUG && warn "loop_resume_time_watcher( $next_time, in " . ($next_time - time()) . " )\n";

  $_watcher_timer->set($next_time);
  $_watcher_timer->start();
}

sub loop_reset_time_watcher {
  my ($self, $next_time) = @_;
  ($_watcher_timer and $next_time) or return;

  EV_DEBUG && warn "loop_reset_time_watcher( $next_time, in " . ($next_time - time()) . " )\n";

  $_watcher_timer->set($next_time);
  $_watcher_timer->start();
}

sub loop_pause_time_watcher {
  $_watcher_timer or return;

  EV_DEBUG && warn "loop_pause_time_watcher()\n";

  $_watcher_timer->stop();
}

############################################################################
# Filehandle code
############################################################################

# helper function, not a method
sub _mode_to_ev {

  # EV_DEBUG && warn "_mode_to_ev: $_[0]\n";
  # EV_DEBUG && warn "_mode_to_ev: EV::READ = " . EV::READ . " EV::WRITE = " . EV::WRITE . "\n";
  return EV::READ  if $_[0] == MODE_RD;
  return EV::WRITE if $_[0] == MODE_WR;

  confess "POE::Loop::EV does not support MODE_EX" if $_[0] == MODE_EX;

  confess "Unknown mode $_[0]";
}

sub loop_watch_filehandle {
  my ($self, $handle, $mode) = @_;

  my $fileno  = fileno($handle);
  my $watcher = $fileno_watcher[$fileno]->[$mode];

  if (defined $watcher) {
    $watcher->stop();
    undef $fileno_watcher[$fileno]->[$mode];
  }

  EV_DEBUG && warn "loop_watch_filehandle( $handle ($fileno), $mode ) ev mode: ", _mode_to_ev($mode), "\n";

  $fileno_watcher[$fileno]->[$mode] = EV::io($fileno, _mode_to_ev($mode), \&_loop_filehandle_callback,);
}

sub loop_ignore_filehandle {
  my ($self, $handle, $mode) = @_;

  my $fileno  = fileno($handle);
  my $watcher = $fileno_watcher[$fileno]->[$mode];

  return if !defined $watcher;

  EV_DEBUG && warn "loop_ignore_filehandle( $handle ($fileno), $mode )\n";

  $watcher->stop();

  undef $fileno_watcher[$fileno]->[$mode];
}

sub loop_pause_filehandle {
  my ($self, $handle, $mode) = @_;

  my $fileno = fileno($handle);

  $fileno_watcher[$fileno]->[$mode]->stop();

  EV_DEBUG && warn "loop_pause_filehandle( $handle ($fileno), $mode )\n";
}

sub loop_resume_filehandle {
  my ($self, $handle, $mode) = @_;

  my $fileno = fileno($handle);

  $fileno_watcher[$fileno]->[$mode]->start();

  EV_DEBUG && warn "loop_resume_filehandle( $handle ($fileno), $mode )\n";
}

sub _loop_filehandle_callback {
  my ($watcher, $ev_mode) = @_;

  EV_DEBUG && warn "_loop_filehandle_callback( " . $watcher->fh . ", $ev_mode )\n";

  my $mode = undef;
  if ($ev_mode == EV::READ) {
    $mode = MODE_RD;
  }
  elsif ($ev_mode == EV::WRITE) {
    $mode = MODE_WR;
  }
  else {

    # warn "Weird mode: $ev_mode\n";
    $mode = MODE_WR;
  }

=pod
    my $mode = ( $ev_mode == EV::READ )
        ? MODE_RD
        : ( $ev_mode == EV::WRITE )
            ? MODE_WR
            : confess "Invalid mode occured in POE::Loop::EV IO callback: $ev_mode";
=cut

  # ->fh is actually the fileno, since that's what we called EV::io with
  $poe_kernel->_data_handle_enqueue_ready($mode, $watcher->fh);

  $poe_kernel->_test_if_kernel_is_idle();
}

1;

__END__

=head1 NAME

POE::Loop::EV - a bridge that supports EV from POE

=head1 SYNOPSIS

    use EV;
    use POE;
    
    ...
    
    POE::Kernel->run();

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

=head1 CAVEATS

Certain EV backends do not support polling on normal filehandles, namely
epoll and kqueue.  You should avoid using regular filehandles with select_read,
select_write, ReadWrite, etc.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<EV>

=head1 AUTHOR

Andy Grundman <andy@hybridized.org>

=head1 THANKS

Brandon Black, for his L<POE::Loop::Event_Lib> module.

=head1 LICENSE

POE::Loop::EV is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
