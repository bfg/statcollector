package ACME::TC::Agent::Plugin::Cache;


use strict;
use warnings;

use POE;
use Log::Log4perl;
use Time::HiRes qw(time);
use Storable qw(lock_nstore lock_retrieve);

use ACME::TC::Agent::Plugin;

use constant DEFAULT_TTL => 0;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin);

our $VERSION = 0.05;

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 NAME ACME::TC::Agent::Plugin::Cache

POE enabled cache for tc agent.

=head1 SYNOPSIS

B<Initialization from perl code>:

	my %opt = (
		default_ttl => 300,
	);
	my $poe_session_id = $agent->pluginInit("Cache", %opt);

B<Initialization via tc configuration>:

	{
		driver => 'Cache',
		params => {
			default_ttl => 300,
		},
	},

=head1 CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::Plugin> and the following ones:

=item B<default_ttl> (integer, 0):

Sets default TTL for added cache items. Value of 0 means that cache entry will never expire.

=item B<cache_file> (string, undef):

Load cache items from specified file name on startup and save cache contents to
specified file while plugin is running if property B<store_interval> is non-zero.

=item B<store_interval> (integer, 0):

Store cache contents to file specified by property B<cache_file> every specified number of seconds.
Cache is stored to file only if this property is non-zero and if B<cache_file> is defined.

=item B<store_perm> (string, "0600"):

Cache filename permissions.

=over

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
      add
      get
      remove
      replace
      purge
      store
      load
      dump
      size
      getKeys
      _checkExpired
      _dumpCache
      )
  );

  # cache structure...
  $self->{_cache} = {};

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);

  return $self;
}

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
  $self->{default_ttl} = DEFAULT_TTL;

  # cache filename
  $self->{cache_file} = undef;

  # cache storage interval
  $self->{store_interval} = 0;

  # cache file permissions...
  $self->{store_perm} = "0600";

  # private settings
  $self->{_time_cache} = 0;
  $self->{_time_store} = 0;

  return 1;
}

sub run {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->info("Plugin '" . $self->_getBasePackage() . "' startup.");

  # try to load anything from persistent cache file
  $kernel->yield("load");

  # check expire loop...
  # $kernel->yield("_checkExpired");

  # check store loop...
  $kernel->yield("_dumpCache");

  return 1;
}

=item add ($key, $value, [$expire = <default_ttl>], [$replace = 0]) [POE]

Adds new entry in cache with TTL specified by $expire argument. Item will be removed from cache
after $expire seconds, if expire is non-zero. Returns 1 on success, otherwise 0.

=cut

sub add {
  my ($self, $kernel, $key, $value, $expire, $replace) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  $expire  = $self->{default_ttl} unless (defined $expire);
  $expire  = int($expire);
  $replace = 0 unless (defined $replace);

  unless (defined $key) {
    $self->{_error} = "Undefined keys are not supported.";
    return 0;
  }

  # is specified key already in cache?
  if (exists($self->{_cache}->{$key})) {
    if ($replace) {
      delete($self->{_cache}->{$key});
    }
    else {
      $self->{_error} = "Key is already in cache.";
      return 0;
    }
  }

  my $t = time();

  # add item...
  $self->{_cache}->{$key} = [$value, $expire, $t];

  # enqueue removal from cache...
  if ($expire > 0) {
    $kernel->alarm_add("remove", ($t + $expire), $key);
  }

  # add cache changed timestamp
  $self->{_time_cache} = $t;

  return 1;
}

=item get ($key) [POE]

Checks cache for item described by $key. Returns item on success, otherwise undef.

=cut

sub get {
  my ($self, $kernel, $key) = @_[OBJECT, KERNEL, ARG0];
  unless (defined $key) {
    $self->{_error} = "Undefined keys are not supported.";
    return undef;
  }

  if (exists($self->{_cache}->{$key})) {
    return $self->{_cache}->{$key}->[0];
  }

  $self->{_error} = "Key not found in cache.";
  return undef;
}

=item remove ($key) [POE]

Removes item identified by $key from cache. Returns 1 on success, otherwise 0.

=cut

sub remove {
  my ($self, $kernel, $key) = @_[OBJECT, KERNEL, ARG0];
  if (exists($self->{_cache}->{$key})) {
    $_log->debug("Removing cache key '$key'.");
    delete($self->{_cache}->{$key});
    return 1;
  }

  return 0;
}

=item replace ($key, $value, [$expire]) [POE]

Replace any possible existing entry in cache with TTL specified by $expire argument.
Item will be removed from cache after $expire seconds, if expire is non-zero. Returns
1 on success, otherwise 0.

=cut

sub replace {
  my ($self, $kernel, $key, $value, $expire) = @_[OBJECT, KERNEL, ARG0 .. $#_];
  $expire = $self->{default_ttl} unless (defined $expire);
  return $kernel->call($self->{_poe_session}, "add", $key, $value, $expire, 1);
}

=item purge () [POE]

Removes all items from cache. Always returns 1.

=cut

sub purge {
  my $self = shift;
  $_log->debug("Purging cache.");
  $self->{_cache}      = {};
  $self->{_time_cache} = time();
  return 1;
}

=item store ([$file]) [POE]

Stores cache contents to file. Returns 1 on success, otheriwse 0.

=cut

sub store {

  # force calling via poe...
  my ($package, $filename, $line) = caller();
  my $poe = ($package =~ m/^POE::/);
  unless ($poe) {
    shift;
    return $poe_kernel->call("store", @_);
  }

  my ($self, $kernel, $file) = @_[OBJECT, KERNEL, ARG0];
  $file = $self->{cache_file} unless (defined $file && length($file) > 0);
  unless (defined $file && length($file)) {
    $self->{_error} = "Undefined cache filename.";
    return 0;
  }

  # try to save
  $_log->debug("Storing cache to file: '$file'.");
  eval { lock_nstore($self->{_cache}, $file); };

  # check for injuries...
  if ($@) {
    $_log->error("Error storing cache to file '$file': $@");
    return 0;
  }

  # set permissions...
  $self->_setFilePermission($file, $self->{store_perm});

  # set store timestamp
  $self->{_time_store} = time();

  return 1;
}

=item load ([$file]) [POE]

Loads cache contents from file. Returns 1 on success, otherwise 0.

=cut

sub load {
  my ($self, $kernel, $file) = @_[OBJECT, KERNEL, ARG0];
  $file = $self->{cache_file} unless (defined $file);
  unless (defined $file && length($file)) {
    $self->{_error} = "Undefined cache filename.";
    return 0;
  }

  # check for file existence.
  unless (-f $file) {
    $self->{_error} = "Unexistent or unreadable cache file: $file";
    return 0;
  }

  $self->{_error} = "";

  my $data = undef;

  # try to load file
  $_log->info("Trying to load cache from file: '$file'.");
  eval { $data = lock_retrieve($file); };

  # check for injuries...
  if ($@) {
    my $str = "Error loading cache from file '$file': $@";
    $self->{_error} = $str;
    $_log->error($str);
    return 0;
  }

  # check what we've got...
  unless (defined $data && ref($data) eq 'HASH') {
    $_log->error("Read weird cache. Ignoring content.");
    return 0;
  }

  $self->{_cache}      = $data;
  $self->{_time_cache} = time();
  $_log->info("Successfully loaded ", (scalar(keys %{$data})), " cache entries from file '$file'.");

  # if we were invoked by run(), we should try to change cache file permissions...
  if ($_[SENDER]->ID() == $_[SESSION]->ID() && $_[CALLER_STATE] eq 'run') {

    # set permissions...
    $self->_setFilePermission($file, $self->{store_perm});
  }

  # enqueue weeding out of expired items...
  $kernel->yield("_checkExpired");

  return 1;
}

=item dump () [POE]

Returns anonymous hash reference containing current cache copy.

=cut

sub dump {
  my ($self) = @_;

  my $r = {};
  %{$r} = %{$self->{_cache}};

  return $r;
}

=item size () [POE]

Returns number of elements in cache.

=cut

sub size {
  my $self = $_[OBJECT];
  return scalar(keys %{$self->{_cache}});
}

=item getKeys () [POE]

Returns list containing cache keys.

=cut

sub getKeys {
  my $self = $_[OBJECT];
  return keys %{$self->{_cache}};
}

##################################################
#               PRIVATE METHODS                  #
##################################################

# repeated task... check for expired keys in cache...
sub _checkExpired {
  my ($self, $kernel, $reinstall) = @_[OBJECT, KERNEL, ARG0];
  $reinstall = 0 unless (defined $reinstall);
  $_log->debug("Checking for expired cache items.");

  my $t = time();
  my $i = 0;

  # iterate trough cache contents...
  map {
    if (ref($self->{_cache}->{$_}) eq 'ARRAY')
    {
      my $expire = $self->{_cache}->{$_}->[1];
      $expire = 1 unless (defined $expire);
      { no warnings; $expire = int($expire); }
      if ($expire > 0) {
        my $time_added = $self->{_cache}->{$_}->[2];
        $time_added = 0 unless (defined $time_added);
        if ($t > ($time_added + $expire)) {
          $_log->debug("Removing expired item from cache: '$_'");
          delete($self->{_cache}->{$_});
          $i++;
        }
      }
    }
    else {
      $_log->warn("Invalid cache item '$_', removing.");
      delete($self->{_cache}->{$_});
      $i++;
    }
  } keys %{$self->{_cache}};

  # add cache changed timestamp (if we've done anything ofcourse)...
  if ($i) {
    $self->{_time_cache} = time();
  }

  $_log->debug("Removed $i cache item(s.)");

  # reinstall ourselves.
  if ($reinstall) {
    $kernel->delay("_checkExpired", $reinstall, $reinstall);
  }

  return 1;
}

sub _dumpCache {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  # check filename must be defined
  unless (defined $self->{cache_file} && length($self->{cache_file})) {
    $self->{_error} = "Undefined cache filename.";
    return 0;
  }

  # store_inteval must be non-zero
  unless ($self->{store_interval} > 0) {
    $self->{_error} = "Store interval is not set to non-zero value.";
    return 0;
  }

  # is it worth storing a file?
  if ($self->{_time_cache} > $self->{_time_store}) {

    # enqueue storing
    $_log->debug("Cache was altered since last cache storage, enqueing store.");
    $kernel->yield("store");
  }
  else {
    $_log->debug("Cache was not altered since last cache store.");
  }

  # reinstall ourselves
  $kernel->delay_add("_dumpCache", $self->{store_interval});
}

sub _setFilePermission {
  my ($self, $file, $perm) = @_;
  unless (defined $file) {
    $_log->error("Error setting file permissions: undefined file.");
    return 0;
  }
  $perm = "0600" unless (defined $perm);
  my $oct_perm = ($perm =~ m/^0/) ? oct($perm) : $perm;

  $_log->debug("Setting permissions '$perm' (oct: $oct_perm) on file '$file'.");
  unless (chmod($oct_perm, $file)) {
    $_log->error("Error setting permissions '$perm' (oct: $oct_perm) on file '$file': $!");
    return 0;
  }

  return 1;
}

sub _shutdown {
  my $self = shift;

  # try to dump stuff to file...
  $poe_kernel->call("store");

  # destroy cache
  $poe_kernel->call("purge");

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
