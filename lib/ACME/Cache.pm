package ACME::Cache;


use strict;
use warnings;

use Time::HiRes qw(time);

use constant CACHE_TTL => 60;

my $__singleton = undef;
our $VERSION = 0.21;

=head1 NAME ACME::Cache

Simple in-memory cache.

=head1 SYNOPSIS

	my $cache = ACME::Cache->new();
	$cache->setDefaultPeriod(20);
	
	# put to cache
	$cache->put("key", "value");
	$cache->put("key2", "value2", 10.3);
	
	# ... and time flies by...
	
	# get contents from cache
	my $x = $cache->get("key");
	my $y = $cache->get("key2");

=cut

=head1 OBJECT CONSTRUCTOR

Object constructor accepts only one optional argument: cache ttl in seconds (default: 60), which can be also set by
invoking L<"setTtl"> method.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  ##################################################
  #               PUBLIC VARS                      #
  ##################################################

  $self->{cacheTtl} = CACHE_TTL;

  ##################################################
  #              PRIVATE VARS                      #
  ##################################################
  $self->{_cache} = {};
  $self->{_error} = "";

  bless($self, $class);
  $self->setTtl(@_);
  $self->destroy();
  return $self;
}

##################################################
#               PUBLIC METHODS                   #
##################################################

=head1 METHODS

=cut

=item getInstance ()

Returns singleton instance of cache class, meaning that getInstance() will always return the very same
cache object anywhere inside perl interpreter. This is convenient for sharing the same cache between
different perl modules.

EXAMPLE:

	package X;
	
	use ACME::Cache;
	my $c_a = ACME::Cache->getInstance();
	$c_a->put("a", "b");

	package Y;
	use ACME::Cache;
	$c_b = ACME::Cache->getInstance();
	print $c_b->get("a"), "\n";

=cut

sub getInstance {
  unless (defined $__singleton) {
    $__singleton = __PACKAGE__->new();
  }

  # perform cleanup...
  $__singleton->cleanup();

  # return the object...
  return $__singleton;
}

=item getError ()

Returns last error accoured.

=cut

sub getError {
  my ($self) = @_;
  return $self->{_error};
}

=item destroy ()

Removes all cache entries. Always returns 1.

=cut

sub destroy {
  my ($self) = @_;
  $self->{_error} = "";
  $self->{_cache} = {};
  return 1;
}

=item cleanup ()

Removes all expired entries from cache. Returns number of expired entries. This
is a maintenance method - you don't need to call it; but you can, if you want :)

=cut

sub cleanup {
  my ($self) = @_;
  my $t      = time();
  my $num    = 0;

  foreach (keys %{$self->{_cache}}) {
    if ($self->{_cache}->{$_}->{expires} > 0 && $self->{_cache}->{$_}->{expires} < $t) {

      # print "DELETING STALLED OBJECT FROM CACHE: $_\n";
      delete($self->{_cache}->{$_});
      $num++;
    }
  }

  return $num;
}

=item size ()

Returns number of elements held in cache.

=cut

sub size {
  my ($self) = @_;
  $self->cleanup();
  return (scalar(keys %{$self->{_cache}}));
}

=item exists ($key)

Returns 1 if specified key is held in cache and is not expired yet, otherwise 0.

=cut

sub exists {
  my ($self, $key) = @_;
  unless (defined $key) {
    $self->{_error} = "Undefined key.";
    return 0;
  }
  return 0 unless (exists($self->{_cache}->{$key}));

  # check if object is too old...
  # if too old, remove it from cache and
  # return non-existence...
  if ($self->{_cache}->{$key}->{expires} > 0) {
    my $t = time();
    if ($self->{_cache}->{$key}->{expires} < $t) {

      # print "DELETING STALLED OBJECT FROM CACHE: $key\n";
      delete($self->{_cache}->{$key});
      return 0;
    }
  }

  return 1;
}

=item get ($key)

Returns element referred by key $key if is held in cache and is not expired yet, otherwise undef.

=cut

sub get {
  my ($self, $key) = @_;
  unless (defined $key) {
    $self->{_error} = "Undefined key.";
    return undef;
  }
  return undef unless ($self->exists($key));

  # print "CACHE HIT for $key.\n";
  return $self->{_cache}->{$key}->{data};
}

=item put ($key, $value[, $ttl = <default_ttl>])

Puts element $value in cache by key $key for $ttl seconds. $ttl can be float to specify
sub seconds cache ttl. If $ttl is omitted, default value (See L<setTtl()>) will be used. If $ttl == 0, value
will be stored in cache forever.

=cut

sub put {
  my ($self, $key, $value, $ttl) = @_;
  unless (defined $key) {
    $self->{_error} = "Undefined key.";
    return 0;
  }
  {
    no warnings;
    $ttl = $self->{cacheTtl} unless (defined $ttl && $ttl >= 0);
  }

  # put in cache...
  $self->{_cache}->{$key} = {expires => (($ttl > 0) ? time() + $ttl : 0), data => $value,};

  return 1;
}

=item delete ($key)

Removes entry identified by $key from cache. Always returns 1.

=cut

sub delete {
  my ($self, $key) = @_;
  if (exists($self->{_cache}->{$key})) {
    delete($self->{_cache}->{$key});
  }

  return 1;
}

=item remove ($key)

Synonim for L<delete()> method.

=cut

sub remove {
  my $self = shift;
  return $self->delete(@_);
}

=item getTtl ()

Returns cache default ttl.

=cut

sub getTtl {
  my ($self) = @_;
  return $self->{cacheTtl};
}

=item setTtl ($ttl)

Sets cache default ttl in seconds. If $ttl == 0, entries put in cache without specifying $ttl using
L<put()> method will be held in cache forever. Argument can be float to specify sub-second
precision.

Returns 1 on success, otherwise 0.

=cut

sub setTtl {
  my ($self, $ttl) = @_;
  my $e = "Invalid cache ttl.";
  unless (defined $ttl) {
    $self->{_error} = $e;
    return 0;
  }
  {
    no warnings;
    $ttl += 0;    # force number;
    unless ($ttl >= 0) {
      $self->{_error} = $e;
      return 0;
    }
  }

  $self->{cacheTtl} = $ttl;
  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
