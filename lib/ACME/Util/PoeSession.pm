package ACME::Util::PoeSession;

use strict;
use warnings;

use POE;
use Attribute::Handlers;

=head1 NAME ACME::Util::PoeSession

Simple POE session base class with some very sweet candies.

=head1 SYNOPSIS

package MyPackage;

 use strict;
 use warnings;
 
 use POE;
 use base 'ACME::Util::PoeSession';

 # :State or :Event method attribute automaticaly marks
 # method as POE session event handler 
 sub someEvent : State {
   my ($self, $kernel, $arg) = @_[OBJECT, KERNEL, ARG0];
   print "SOMEEVENT: GOT arg: $arg\n";
   $kernel->yield('someOtherEvent', ($arg + 1));
 }

 sub someOtherEvent : Event {
   my ($self, $kernel, $arg) = @_[OBJECT, KERNEL, ARG0];
   print "SOMEOTHEREVENT: GOT arg: $arg\n";
 }

 sub sessionStart {
   $_[KERNEL]->yield('someEvent', 10);
 }
 1;
 
 package main;
 
 use strict;
 use warnings;
 
 my $obj = MyPackage->new();
 
 # ->spawn() and POE::Kernel->run() combined
 $obj->run();

=head1 ABSTRACT

A simple base class for objectsattribute handler mixin that makes POE state easier to keep track of.

=head1 DESCRIPTION

Provides an attribute handler that does some bookkeeping for state
handlers. There are alot of similar modules out there with similar
functionality, most notably L<POE::Session::AttributeBased>, but none of them
offer default event handlers and full OO inheritance support and optional
L<Log::Log4perl> debugging.

=head1 WARNING

It looks like POE session event method attributes offered by this class do not work
for classes that were loaded in runtime using require... Use B<registerEvent> method
instead. 

=cut

use vars qw(@ISA @EXPORT @EXPORT_OK);

@ISA       = qw(Exporter);
@EXPORT    = qw(is_poe);
@EXPORT_OK = qw();

our $VERSION = 0.09;

my @_default_events = qw(
  sessionStart _start _stop
  _default _parent _child
);

# event hash...
my $_pkg_ev = {};

# event cache...
my $_cache = {};

# log4perl object
my $_log = undef;

# Invoked for any subroutine declared in MyClass (or a
# derived class) with an :State or :Event attribute.
sub State : ATTR(CODE) {
  __registerEv(@_);
}

sub Event : ATTR(CODE) {
  __registerEv(@_);
}

# registers POE event handler for State or Event method attribute
sub __registerEv {
  my ($package, $symbol, $referent, $attr, $data, $phase, $filename, $linenum) = @_;
  if (defined $_log) {
    $_log->debug("Package: $package; symbol: $symbol");
    no warnings;
  }

  # don't bother on anonymous symbols...
  return 0 if ($symbol eq 'ANON');

  # try to resolve method name
  my $method = eval { *{$symbol}{NAME} };
  unless (defined $method) {
    warn("Unable to resolve method name from symbol: $symbol");
  }

  # add method to list if it's not already there
  if (grep(/^$method$/, @{$_pkg_ev->{$package}}) < 1) {
    push(@{$_pkg_ev->{$package}}, $method);
  }
}

=head1 EXPORTED FUNCTIONS

=head2 is_poe (ARRAYREF)

Returns 1 if provided arrayref is POE event invocation, otherwise 0.

Example:

 sub someEvent {
 	# not called as POE event?
 	unless (is_poe(\ @_)) {
 		return $poe_kernel->call('someEvent', @_[1 .. $#_]);
 	}
	
 	my ($self, $kernel, $arg) = @_[OBJECT, KERNEL, ARG0];
  	# ...
 }

=cut

sub is_poe {
  no warnings;
  return (defined($_[0]->[KERNEL]) && $_[0]->[KERNEL] == $poe_kernel) ? 1 : 0;
}

=head1 OBJECT CONSTRUCTOR

Object constructor doesnt accept any arguments.

=cut

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = {};

  ##################################################
  #              PUBLIC PROPERTIES                 #
  ##################################################

  ##################################################
  #              PRIVATE PROPERTIES                #
  ##################################################

  # flag: spawned or not
  $self->{__spawned} = 0;

  # POE session id
  $self->{__poeSessionId} = undef;

  # flag: object is initialized.
  $self->{__initialized} = 0;

  bless($self, $class);

  # initialize ourselves...
  $self->__initialize();

  return $self;
}

sub __initialize {
  my ($self) = @_;

  # don't initialize twice
  return 1 if (exists($self->{__initialized}) && $self->{__initialized});

  # configure log4perl in case Log::Log4perl is already loaded
  if (exists($INC{'Log/Log4perl/Logger.pm'})) {
    $self->useLog4perl(1);
  }

  $self->{__initialized} = 1;
}

=head1 METHODS

=head2 registerEvent ($name, $name2, ...)

Registers POE events in current object instance POE session.
Event is not registered if already exists. Returns number of 
successfully registered events.

=cut

sub registerEvent {
  my $self = shift;
  my $pkg  = ref($self);
  my $i    = 0;
  foreach my $name (@_) {

    # check method existence...
    next unless ($pkg->can($name));

    # don't register event if event already exist.
    if (grep(/^$name$/, @{$_pkg_ev->{$pkg}}) < 1) {
      $i++;
      push(@{$_pkg_ev->{$pkg}}, $name);

      # if we're already running, register POE event for current class too...
      if ($self->{__spawned}) {
        $poe_kernel->state($name, ref($self));
      }
    }
  }

  return $i;
}

=head2 getRegisteredEvents ()

Returns list of registered events in current object instance POE session.

=cut

sub getRegisteredEvents {
  my ($self) = @_;
  my $package = ref($self);

  # anything in cache?
  if (exists($_cache->{$package})) {
    return @{$_cache->{$package}};
  }

  my @r = @_default_events;
  foreach my $pkg ($package, $self->getParentClasses()) {
    if (defined $pkg && exists($_pkg_ev->{$pkg})) {
      push(@r, @{$_pkg_ev->{$pkg}});
    }
  }

  # put in cache...
  $_cache->{$package} = [sort(@r)];

  # print "PUT in cache for '$package': ", join(", ", @{$_cache->{$package}});
  # return sorted array...
  return @{$_cache->{$package}};
}

=head2 getSessionId ()

Returns object's session id if object is already spawned as POE session, otherwise undef.

=cut

sub getSessionId {
  my ($self) = @_;
  return $self->{__poeSessionId};
}

=head2 setSessionId ($id)

Sets POE session Id. This method can be called only once. Returns 1 on success, otherwise 0.

=cut

sub setSessionId {
  my ($self, $id) = @_;
  return 0 if (exists($self->{__poeSessionId}) && defined $self->{__poeSessionId});
  return 0 unless ($id > 0);
  $self->{__poeSessionId} = $id;
  return 1;
}

=head2 getSessionAliases ()

Returns list containing list of POE session aliases bound to object POE session.

=cut

sub getSessionAliases {
  my $self = shift;
  my $id   = $self->getSessionId();
  return () unless (defined $id);
  return $poe_kernel->alias_list($id);
}

=head2 isSpawned ()

Returns 1 if object is spawned, otherwise 0.

=cut

sub isSpawned {
  my ($self) = @_;
  return exists($self->{__spawned}) ? $self->{__spawned} : 0;
}

=head2 getParentClasses ([$package])

Returns list of parent classes for specified class/package. Returns object parent classes
if package argument is omitted.

=cut

sub getParentClasses {
  my ($self, $pkg) = @_;
  $pkg = ref($self) unless (defined $pkg);

  my $str     = '@' . $pkg . '::ISA';
  my @parents = eval 'return ' . $str;
  return @parents;
}

=head2 spawn ([$alias])

Creates new POE session and returns session id. POE event handlers are registered via B<:State> or B<:Event> method
attributes or by using B<registerEvent()> method. POE session alias is set if $alias argument is provided.

Returns newly created POE session alias on success, otherwise 0.

=cut

sub spawn {
  my ($self, $alias) = @_;

  # already spawned?! don't do it again :)
  if ($self->{__spawned}) {
    return $self->{__poeSessionId};
  }

  # check if object has been initialized;
  $self->__initialize();

  if (defined $_log && !$self->{__silent} && $_log->is_debug()) {
    $_log->debug(
      "Spawning new POE session for object ",
      ref($self),
      " with events: ",
      join(", ", $self->getRegisteredEvents())
    );
  }

  # create session...
  my $s = eval {
    POE::Session->create(args => [$alias], object_states => [$self => [$self->getRegisteredEvents()],],);
  };

  # no session, no fun...
  unless (defined $s) {
    return 0 if (exists($self->{__silent}) && $self->{__silent});
    my $str = "Unable to create new POE session: ";
    $str .= ($@) ? $@ : $!;
    if (defined $_log) {
      $_log->error($str);
    }
    else {
      warn($str);
    }
    return 0;
  }

  # get POE session id.
  my $id = $s->ID();

  # mark ourselves as spawned.
  $self->{__spawned} = 1;

  # remember session id.
  $self->{__poeSessionId} = $id;

  if (defined $_log && !$self->{__silent}) {
    $_log->debug("Object ", ref($self), " spawned in POE session $id.");
  }
  return $id;
}

=head2 run ()

This method is invokes B<spawn()> method and starts POE kernel if it is not running already. If POE kernel is
not currently running, this method BLOCKS until POE kernel is not done!

If POE kernel is already running immediately returns spawn()'s return value otherwise returns return value of
POE::Kernel->run().

=cut

sub run {
  my $self = shift;

  # this can't hurt...
  my $r = $self->spawn();

  # figure out if POE::Kernel is already running...
  my $kr_run_warning = ${$poe_kernel->[POE::Kernel::KR_RUN()]};
  my $x              = POE::Kernel::KR_RUN_CALLED();
  my $poe_started    = ($kr_run_warning & $x);

  # start POE kernel if it's not yet started
  if ($poe_started) {
    return $r;

    #$_log->debug("POE kernel is already running.");
  }
  else {

    #$_log->debug("POE kernel is not started, starting.");
    $poe_kernel->run();
  }

  return 1;
}

=head2 useLog4perl ([$flag = 1])

If true, tries to load L<Log::Log4perl> module and configures in-package logger which
will warn about missing methods extension methods (_start, _stop, _child) or when object
receives invalid or non-existing event/state message.

Note: If Log::Log4perl is already loaded in perl interpreter, log4perl logging is
configured automatically.

Returns 1 on success, otherwise 0.

=cut

sub useLog4perl {
  my ($self, $flag) = @_;
  $flag = 1 unless (defined $flag);

  if ($flag) {

    # already initialized?
    return 1 if (defined $_log);

    # check if log4perl is already loaded
    # in this perl interpreter.
    unless (exists($INC{'Log/Log4perl/Logger.pm'})) {

      # nope, it's not; try to load it.
      eval { require Log::Log4perl; };

      # check for injuries
      if ($@) {
        warn("Unable to enable log4perl support: ", $@);
        return 0;
      }
    }

    # get logger
    eval { $_log = Log::Log4perl->get_logger(__PACKAGE__); };
  }
  else {
    $_log = undef;
  }

  return 1;
}

=head2 setSilent ([$flag = 1])

Disables/enables all error/warning reporting. Reporting is turned on by default.

=cut

sub setSilent {
  my ($self, $flag) = @_;
  $flag = 1 unless (defined $flag);
  $self->{__silent} = $flag;
}

sub _start {
  my ($self, $kernel, $alias) = @_[OBJECT, KERNEL, ARG0];

  # remember POE session ID
  $self->setSessionId($_[SESSION]->ID());

  # set POE session alias...
  if (defined $alias && length($alias) > 0) {
    if (defined $_log && !$self->{__silent}) {
      $_log->debug("Setting POE Session alias: " . $alias . " for session ", $self->getSessionId());
    }
    my $r = $kernel->alias_set($alias);
    if ($r) {
      unless ($self->{__silent}) {
        my $str = "Error setting POE session alias '$alias': $!";
        if (defined $_log) {
          $_log->error($str);
        }
        else {
          warn($str);
        }
      }

      # return invalid session id.
      return 0;
    }
  }

  $kernel->yield('sessionStart');
}

=head1 EXTENDING

You can extend the following methods:

=head1 PROTECTED METHODS

The following methods can be called from subclasses...

=head2 sessionStart [POE]

This event is invoked immediately after _start handler implemented by this class. You B<NEED> to
implement this method!

Example:
 sub sessionStart {
 	my ($self, $kernel) = @_;
 	
 	# start object execution
 	$kernel->yield('startExecution');
 }

See L<http://search.cpan.org/perldoc?POE::Kernel#Session_Management_Events_(_start,__stop,__parent,__child)>

=cut

sub sessionStart : State {
  my $self = shift;

  return 1 if (exists($self->{__silent}) && $self->{__silent});
  my $str
    = "POE session "
    . $_[SESSION]->ID()
    . " for object "
    . ref($self)
    . " started but you didn't implement your own sessionStart() method.";
  if (defined $_log) {
    $_log->error($str);
  }
  else {
    warn($str);
  }
}

=head2 _stop [POE]

See L<http://search.cpan.org/perldoc?POE::Kernel#Session_Management_Events_(_start,__stop,__parent,__child)>

=cut

sub _stop {
  my ($self) = @_;
  return 1 if (exists($self->{__silent}) && $self->{__silent});

  my $id = undef;
  $id = $_[SESSION]->ID() if (defined $_[SESSION]);
  $id = "<undefined_session>" unless (defined $id);

  my $ref = ref($self);
  $ref = "<undefined_object>" unless (defined $ref);

  my $str = "Stopping POE session " . $id . " for object " . $ref;
  if (defined $_log) {
    $_log->debug($str);
  }
  else {
    warn($str);
  }
}

=head2 _parent ($old, $new) [POE]

See L<http://search.cpan.org/perldoc?POE::Kernel#Session_Management_Events_(_start,__stop,__parent,__child)>

=cut

sub _parent {
  my ($self, $old, $new) = @_[OBJECT, ARG0, ARG1];
  return 1 if (exists($self->{__silent}) && $self->{__silent});

  my $str = "Object " . ref($self) . " parent POE session change: from " . $old->ID() . " to " . $new->ID();
  if (defined $_log) {
    $_log->debug($str);
  }
  else {
    warn($str);
  }
}

=head2 _child ($reason, $child) [POE]

See L<http://search.cpan.org/perldoc?POE::Kernel#Session_Management_Events_(_start,__stop,__parent,__child)>

=cut

sub _child {
  my ($self, $reason, $child) = @_[OBJECT, ARG0, ARG1];
  return 1 if (exists($self->{__silent}) && $self->{__silent});

  my $str = "_child: Object " . ref($self) . "; Reason: $reason; id: " . $child->ID();
  if (defined $_log) {
    $_log->debug($str);
  }
  else {
    warn($str);
  }
}

=head2 _default ($event, $args) [POE]

This POE event is invoked when object POE session receives call for undefined event/state handler.

See L<http://search.cpan.org/perldoc?POE::Kernel#Session_Management_Events_(_start,__stop,__parent,__child)>

=cut

sub _default {
  my ($self, $event, $args) = @_[OBJECT, ARG0, ARG1];
  return 1 if (exists($self->{__silent}) && $self->{__silent});

  my $str
    = "Object "
    . ref($self)
    . ", POE session "
    . $self->getSessionId()
    . " caught unhandled event from session id '"
    . $_[SENDER]->ID()
    . "'. Called event '$event' with arguments: ["
    . join(", ", @{$args}) . "].";

  if (defined $_log) {
    $_log->warn($str);
  }
  else {
    warn($str);
  }
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO
L<POE>
L<POE::Session::AttributeBased>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
