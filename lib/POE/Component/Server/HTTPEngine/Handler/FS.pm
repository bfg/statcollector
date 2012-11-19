package POE::Component::Server::HTTPEngine::Handler::FS;


use strict;
use warnings;

use POE;
use IO::File;
use IO::Scalar;
use File::Spec;
use POE::Wheel::Run;
use POSIX qw(strftime);
use POE::Wheel::ReadWrite;
use HTTP::Status qw(:constants);
use HTTP::Date qw(time2str str2time);

use POE::Component::Server::HTTPEngine::Handler;

# inherit everything from base class
use base 'POE::Component::Server::HTTPEngine::Handler';

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

use constant HAS_TIME_HRES => eval 'require Time::HiRes';

our $VERSION = 0.13;

my $_log = undef;

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

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
  push(
    @{$self->{_exposed_events}}, qw(
      __cgiStderr __cgiStdout	__cgiClosed
      __cgiError __cgiFlushed
      __sigh_CHLD
      )
  );

  # logging object
  if (DEBUG && !defined $_log) {
    $_log = Log::Log4perl->get_logger(__PACKAGE__);
  }

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);
  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  $self->SUPER::clearParams();

  $self->{path}         = undef;
  $self->{dir_listing}  = 1;
  $self->{cgi_enabled}  = 0;
  $self->{interpreters} = {

    # regex => interpreter
  };

  @{$self->{env_vars}}  = qw(HOST HOSTNAME PATH);
  @{$self->{dir_index}} = qw(
    index.cgi index.html index.htm
  );
}

sub getDescription {
  return "Artbitrary file serving module with CGI execution support.";
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # check if we're configured properly...
  unless (exists($self->{path}) && defined $self->{path} && length($self->{path})) {
    $response->setError($request->uri()->path(),
      HTTP_INTERNAL_SERVER_ERROR,
      "Invalid configuration of FS handler. Configuration key <b>path</b> is missing.");
    return $self->requestFinish();
  }

  # get the real uri path...
  my $uri_path = join("/", $request->uri()->path_segments());

  # where are we mounted?
  my $sub_path = substr($uri_path, length($self->{_mount_path}));

  # print STDERR "URI_PATH: '$uri_path'\n";
  $_log->debug("dir: '$self->{path}', uri_path: '$uri_path'; sub_path: '$sub_path'.") if (DEBUG);

  # check mount path (is it file and we have cgi enabled?)
  if ($self->{cgi_enabled} && -f $self->{path}) {
    $_log->debug("CGI is enabled and handler is mounted to file. Fixing sub_path.") if (DEBUG);
    $response->pathInfo($sub_path);
    $sub_path = "";
  }

  # compute filesystem path...
  #my $path = File::Spec->catfile($self->{path}, $sub_path);
  my $path = File::Spec->catdir($self->{path}, $sub_path);

  $_log->debug("Computed FS path: '$path'") if (DEBUG);

  # doesn't exist?
  if (!-e $path) {
    return $self->errNotFound($response);
  }

  # is a directory?
  elsif (-d $path) {

    # uri_path not ending with trailing /?
    # redirect request...
    if ($uri_path !~ /\/$/) {
      $uri_path .= "/";
      $response->header("Location", $uri_path);
      $response->code(HTTP_FOUND);
      return $self->requestFinish();
    }

    my $found_index = 0;

    # check for directory index...
    foreach (@{$self->{dir_index}}) {
      my $x = File::Spec->catfile($path, $_);
      if (-e $x && -f $x) {
        $found_index = 1;
        $path        = $x;
        $_log->debug("Found directory index, fixing path to '$path'.") if (DEBUG);
        last;
      }
    }

    # have we found directory index?
    unless ($found_index) {

      # directory listing enabled?
      if ($self->{dir_listing}) {
        $response->code(HTTP_OK);
        $response->header("Content-Type", "text/html");
        $response->content($self->renderDir($path, $uri_path));
        return $self->requestFinish($response);
      }
      else {
        return $self->errForbidden($response, "Directory listing is forbidden.");
      }
    }
  }

  # file?
  if (-f $path) {

    # is cgi enabled?
    my $interpreter = undef;
    if ($self->{cgi_enabled}) {
      my $interpreter = $self->_getInterpreter($path);

      # do we have an interpreter?
      if (defined $interpreter) {
        return $self->_cgiRun($interpreter, $path);
      }

      # hm... is this file executable?
      elsif (-x $path) {
        return $self->_cgiRun($path);
      }
    }

    # just send the file...
    return $self->sendFile($path);
  }

  # no?! wtf...
  else {
    $response->setError($uri_path, HTTP_SERVICE_UNAVAILABLE,
      "Specified URL cannot be retrieved (not a plain file)");
  }

  return $self->requestFinish();
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _getInterpreter {
  my ($self, $file) = @_;
  foreach (keys %{$self->{interpreters}}) {
    if ($file =~ m/$_/i) {
      return $self->{interpreters}->{$_};
    }
  }

  return undef;
}

sub _cgiRun {
  my ($self, $interpreter, $file) = @_;

  # backup %ENV
  $self->_envBackup();

  # set new %ENV
  my $e = $self->_getCGIEnv();

  # Set PATH_INFO if needed...
  my $pi = $self->{_response}->pathInfo();
  $e->{PATH_INFO} = $pi if (defined $pi);

  # set SCRIPT_FILENAME...
  $e->{SCRIPT_FILENAME} = defined($file) ? $file : $interpreter;

  $self->_envSet($e);

  my $cmd = $interpreter;
  $cmd .= " " . $file if (defined $file);

  $_log->debug("Invoking CGI: $cmd") if (DEBUG);

  if (DEBUG && HAS_TIME_HRES) {
    if ($_log->is_debug()) {
      $self->{_cgi_start_time} = Time::HiRes::time();
    }
  }

  # create the wheel!
  $self->{_cgi} = POE::Wheel::Run->new(
    Program => $cmd,

    # NoSetSid => 1,
    StdinFilter  => POE::Filter::Stream->new(),
    StdoutFilter => POE::Filter::Stream->new(),
    StderrFilter => POE::Filter::Line->new(),
    StdinEvent   => '__cgiFlushed',               # Flushed all data to the child's STDIN.
    StdoutEvent  => '__cgiStdout',                # Received data from the child's STDOUT.
    StderrEvent  => '__cgiStderr',                # Received data from the child's STDERR.
    ErrorEvent   => '__cgiError',                 # An I/O error occurred.
    CloseEvent   => '__cgiClosed',                # Child closed all output handles.
  );

  # install sigchld...
  $poe_kernel->sig_child($self->{_cgi}->PID(), "__sigh_CHLD");

  # put the request content...
  $self->{_cgi}->put($self->{_request}->content());

  $self->{_got_headers} = 0;
  $self->{_content}     = "";

  # restore %ENV
  $self->_envRestore();
  delete($ENV{PATH_INFO});
  delete($ENV{SCRIPT_FILENAME});

  return 1;
}

# archives current process env
sub _envBackup {
  my ($self) = @_;
  $_log->debug("Backing up process environment.") if (DEBUG);
  $self->{_env} = {};
  map { $self->{_env}->{$_} = $ENV{$_}; } keys %ENV;

  return 1;
}

# restores process environment from backup
sub _envRestore {
  my ($self) = @_;
  $_log->debug("Restoring process environment from backup.") if (DEBUG);
  map { $ENV{$_} = $self->{_env}->{$_}; } keys %{$self->{_env}};

  return 1;
}

# creates new process environment,
# based on request...
sub _envSet {
  my ($self, $env) = @_;
  unless (ref($env) eq 'HASH') {
    $self->{_error} = "ENV is not an hash reference.";
    return 0;
  }
  $_log->debug("Setting CGI process enviroment.") if (DEBUG);
  my $i = 0;

  # backup permitted variables...
  my %bkp = ();
  map { $bkp{$_} = $ENV{$_}; } @{$self->{env_vars}};

  # destroy ENV...
  %ENV = ();

  # set env from request
  map {

    # $_log->debug("   \$ENV{$_} = $env->{$_}") if (DEBUG);
    if (defined $_) {
      $ENV{$_} = $env->{$_};
      $i++;
    }
  } keys %{$env};

  # set env from backup keys...
  map {

    # $_log->debug("   \$ENV{$_} = $bkp{$_}") if (DEBUG);
    $ENV{$_} = $bkp{$_};
  } keys %bkp;

  $_log->debug("Set $i environmental variables.") if (DEBUG);

  return $i;
}

sub __cgiFlushed {
  my ($self, $wheel_id) = @_;
  $_log->debug("STDIN flushed on wheel $wheel_id.") if (DEBUG);
  $self->{_cgi}->shutdown_stdin();
}

sub __cgiStderr {
  my ($self, $data, $wheel_id) = @_[OBJECT, ARG0, ARG1];
  $_log->error("CGI stderr output: $data") if (DEBUG);
  return 1;
}

sub __cgiStdout {
  my ($self, $data, $wheel_id) = @_[OBJECT, ARG0, ARG1];

  # check if client is still alive...
  my $client_wheel = $self->{_response}->wheel();
  unless ($self->{_server}->clientIsValid($client_wheel)) {
    $_log->warn("Our client disappered! Shutting down the wheel!") if (DEBUG);
    $self->requestFinish($self->{_response});
    delete($self->{_cgi});
    return 0;
  }

  # add this output...
  return $self->addRawOutput($data);
}

sub __cgiError {
  my ($self, $operation, $errnum, $errstr, $wheel_id) = @_[OBJECT, ARG0 .. ARG3];

  if ($operation eq 'read' && $errnum == 0) {

    # cgi is done...
    $_log->debug("EOF on cgi fd on wheel $wheel_id.") if (DEBUG);
  }
  else {
    $_log->error("Error reading from piped program on wheel $wheel_id ($errnum): $operation: $errstr")
      if (DEBUG);
  }

  return 1;
}

sub __cgiClosed {
  my ($self, $wheel_id) = @_[OBJECT, ARG0];
  $_log->debug("CLOSED wheel: $wheel_id") if (DEBUG);

  if (DEBUG && HAS_TIME_HRES) {
    if ($_log->is_debug()) {
      $_log->debug("CGI program finished in "
          . sprintf("%-.3f second(s).", (Time::HiRes::time() - $self->{_cgi_start_time})));
    }
  }

  delete($self->{_cgi});
  $self->requestFinish();
}

sub __sigh_CHLD {
  my ($self, $kernel, $signame, $pid, $exit_val) = @_[OBJECT, KERNEL, ARG0, ARG1, ARG2];
  my $exit_st  = $exit_val >> 8;
  my $exit_sig = $exit_val & 127;
  my $core     = $exit_val & 128;

  if (DEBUG) {
    if ($_log->is_debug()) {
      $_log->debug(
        "Got SIG$signame. Reaping process pid $pid terminated by signal $exit_sig "
          . ($core ? "with" : "without"),
        " coredump. Exit status: $exit_st."
      );
    }
  }

  if ($exit_st != 0) {
    $self->logError("CGI program with exit status $exit_st.");
  }

  # this signal was handled...
  $kernel->sig_handled();

  return 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO
L<HTTP::Request>
L<HTTP::Response>
L<POE::Component::Server::HTTPEngine::Handler>
L<POE::Component::Server::HTTPEngine::Response>

=cut

1;
