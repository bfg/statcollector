package ACME::TC::Agent::Plugin::StatCollector::Storage::File;


use strict;
use warnings;

use POE;
use POE::Wheel::ReadWrite;
use POE::Filter::Reference;

use IO::File;
use File::Spec;
use Log::Log4perl;
use Storable qw(nfreeze);
use POSIX qw(strftime);

use ACME::Util;
use ACME::TC::Agent::Plugin::StatCollector::Storage;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Storage);

our $VERSION = 0.01;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

my $util = ACME::Util->new();

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Storage::File

Serializes ParsedData objects using B<Storable> function B<nfreeze>.

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin::StatCollector::Storage> and the following ones:

=over

=item B<dir> (string, "/tmp"):

Where to store serialized objects. This string can contain
strftime(3) pattern.

=item B<prefix> (string, ""):

Filename prefix.

=item B<perm> (string, "644"):

Written filename permissions.

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  $self->SUPER::clearParams();

  $self->{dir}    = File::Spec->tmpdir();
  $self->{prefix} = "";
  $self->{perm}   = "644";

  # wheel hash...
  $self->{__wheel} = {};

  # exposed POE object events
  $self->registerEvent(
    qw(
      _fileError
      _fileFlushed
      _noop
      )
  );

  # must return 1 on success
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _run {
  my ($self) = @_;

  # filename prefix...
  unless (defined $self->{prefix}) {
    $self->{prefix} = "";
  }

  return 1;
}

# enqueue storage...
sub _store {
  my ($self, $id, $data) = @_;

  my $fs = $data->getFetchStartTime();

  # calculate directory
  my $dir = strftime($self->{dir}, localtime(time()));
  unless (-e $dir) {
    $_log->info($self->getStoreSig($id) . "Creating missing directory: $dir");
    unless ($util->mkdir_r($dir)) {
      $self->{_error} = $util->getError();
      return 0;
    }
  }

  # calculate filename
  my $file = File::Spec->catfile($dir, $self->{prefix} . $data->getFetchStartTime() . "-" . $id . ".bin");

  # open file
  $_log->debug($self->getStoreSig($id) . "Storing to file: $file");
  my $fd = IO::File->new($file, 'w');
  unless (defined $fd) {
    $self->{_error} = "Unable to open file '$file' for writing: $!";
    return 0;
  }

  # change permissions...
  if (defined $self->{perm}) {
    $_log->debug($self->getStoreSig($id) . "Setting permissions $self->{perm}");
    unless (chmod(oct($self->{perm}), $file)) {
      $self->{_error} = "Error setting permissions $self->{perm} on file $file: $!";
      return 0;
    }
  }

  # create rw wheel
  my $wheel = POE::Wheel::ReadWrite->new(
    Handle       => $fd,
    Filter       => POE::Filter::Stream->new(),
    FlushedEvent => "_fileFlushed",
    ErrorEvent   => "_fileError"
  );
  my $wid = $wheel->ID();
  $_log->debug($self->getStoreSig($id) . "Created RW wheel: $wid");

  # don't even try to read from wheel...
  $wheel->pause_input();

  # enqueue data for storage...
  eval { $wheel->put(nfreeze($data)); };
  if ($@) {
    $self->{_error} = "Error serializing data: $@";
    return 0;
  }

  # $wheel->put($data);

  # store it to our little hash
  $self->{__wheel}->{$wid} = {obj => $wheel, sid => $id, file => $file,};

  return 1;
}

sub _storeCancel {
  my ($self, $id) = @_;

  # look for store if $id
  foreach my $wid (keys %{$self->{__wheel}}) {
    if ($self->{__wheel}->{$wid}->{sid} eq $id) {

      # destroy the wheel, and we're done
      delete($self->{__wheel}->{$wid});
      return 1;
    }
  }

  $self->{_error} = "Store id not found: $id";
  return 0;
}

# shutdown!
sub _shutdown {
  my ($self) = @_;

  # close all unclosed filehandles...
  my $i = 0;
  my $j = 0;
  foreach (keys %{$self->{__fd}}) {
    $j++;
    $_log->info($self->getStorageSignature() . "Flushing POE wheel: $_");

    # try to flush it...
    eval { $self->{__fd}->{$_}->flush(); };
    if ($@) {
      $_log->error($self->getStorageSignature() . "Error flushing wheel $_: $@");
    }
    else {
      $i++;
    }

    # destroy the wheel
    delete($self->{__fd}->{$_});
  }
  $_log->info($self->getStorageSignature() . "Successfully finished $i of $j pending write(s).");

  return 1;
}

sub _fileError {
  my ($self, $kernel, $operation, $errnum, $errstr, $wid) = @_[OBJECT, KERNEL, ARG0 .. ARG3];
  return 0 unless (exists($self->{__wheel}->{$wid}));

  # get storage id && file...
  my $sid  = $self->{__wheel}->{$wid}->{sid};
  my $file = $self->{__wheel}->{$wid}->{file};

  if ($errnum != 0) {
    $_log->error($self->getStoreSig($sid)
        . "Got errno $errnum while running operation on file $file: $operation: $errstr");
  }

  # destroy the wheel
  delete($self->{__wheel}->{$wid});

  # this is fukked up!
  $kernel->yield(STORE_ERR, $sid, $errstr);
}

sub _fileFlushed {
  my ($self, $kernel, $wid) = @_[OBJECT, KERNEL, ARG0];
  return 0 unless (exists($self->{__wheel}->{$wid}));
  $_log->debug($self->getStorageSignature() . " Wheel $wid flushed.");

  # get storage id
  my $sid  = $self->{__wheel}->{$wid}->{sid};
  my $file = $self->{__wheel}->{$wid}->{file};

  # we were successfull!
  $kernel->yield(STORE_OK, $sid, $file);

  # destroy the wheel
  delete($self->{__wheel}->{$wid});

  return 1;
}


=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::ParsedData>
L<ACME::TC::Agent::Plugin::StatCollector::Storage>
L<ACME::TC::Agent::Plugin::StatCollector>
L<Storable>
L<POE>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
