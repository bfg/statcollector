package POE::Component::Server::HTTPEngine::Handler;


use strict;
use warnings;

use POE;
use IO::File;
use IO::Scalar;
use HTTP::Date;
use Sys::Hostname;
use URI::QueryParam;
use POSIX qw(strftime);
use POE::Wheel::ReadWrite;
use Scalar::Util qw(blessed);
use HTTP::Status qw(:constants);
use LWP::MediaTypes qw(guess_media_type add_type);

use vars qw(@ISA @EXPORT);

@ISA    = qw(Exporter);
@EXPORT = qw(
  KB MB GB HTTP_SERVER_CLASS
);

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

use constant KB => 1024;
use constant MB => 1024 * 1024;
use constant GB => 1024 * 1024 * 1024;

use constant CLASS_HTTP_SERVER   => "POE::Component::Server::HTTPEngine";
use constant CLASS_HTTP_REQUEST  => "HTTP::Request";
use constant CLASS_HTTP_RESPONSE => "POE::Component::Server::HTTPEngine::Response";

my @_poe_events = qw(
  _start _stop _parent _child _default
  __handleInput __handleError
  processRequest shutdown
);

# logging object
my $_log = undef;

# parse mime types...
my $_mime_types_parsed = _parseMimeTypes();

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

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

  # additional exposed events...
  @{$self->{_exposed_events}} = ();

  if (DEBUG && !defined $_log) {
    $_log = Log::Log4perl->get_logger(__PACKAGE__);
  }

  $self->{_finished} = 0;

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);

  return $self;
}

sub DESTROY {
  my $self = shift;
  if (DEBUG) {
    $_log->debug("Destroying: $self") if (defined $_log);
  }
}

##################################################
#                PUBLIC METHODS                  #
##################################################

sub getDescription {
  return "Base URL handler module";
}

sub setParams {
  my $self = shift;
  while (defined(my $key = shift(@_)) && defined(my $v = shift(@_))) {
    next if ($key =~ m/^_/);
    $self->{$key} = $v;
  }

  return 1;
}

sub clearParams {
  my ($self) = @_;

  # io/buffer size...
  $self->{buffer_size} = 256 * KB;
  $self->{auth_realm}  = undef;

  # other, internal stuff...

  # check if "DONE|CLOSE" event was sent on session shutdown
  $self->{_check_done} = 1;

  return 1;
}

sub getRequest {
  my $self = shift;
  return $self->{_request};
}

sub getResponse {
  my $self = shift;
  return $self->{_response};
}

sub getServer {
  my $self = shift;
  return $self->{_server};
}

sub streamSend {
  my ($self, $data) = @_;
  my $response = $self->{_response};
  $response->content($data);

  return $poe_kernel->post($self->{_server_poe_session}, "STREAM", $response,);
}

sub htmlEncode {
  my ($self, $str) = @_;
  return undef unless (defined $str);
  $str =~ s/</&lt;/gm;
  $str =~ s/>/&gt;/gm;
  return $str;
}

sub spawn {
  my ($self, $server, $request, $response) = @_;

  # check parameters...
  unless (blessed($server) && $server->isa(CLASS_HTTP_SERVER)) {
    $_log->error("First argument must be " . CLASS_HTTP_SERVER . " initialized object.") if (DEBUG);
    return 0;
  }
  unless (blessed($request) && $request->isa(CLASS_HTTP_REQUEST)) {
    $_log->error("Second argument must be " . CLASS_HTTP_REQUEST . " initialized object.") if (DEBUG);
    return 0;
  }
  unless (blessed($response) && $response->isa(CLASS_HTTP_RESPONSE)) {
    $_log->error("Third argument must be " . CLASS_HTTP_RESPONSE . " initialized object.") if (DEBUG);
    return 0;
  }

  if (DEBUG) {
    $_log->debug(
      "Creating new POE session with defined events: ",
      join(", ", @_poe_events, @{$self->{_exposed_events}})
    );
  }

  # create new POE session
  my $id = POE::Session->create(
    args => [$server, $request, $response],
    object_states => [$self => [@_poe_events, @{$self->{_exposed_events}}],],
  )->ID();

  # return session id...
  return $id;
}

sub _start {
  my ($self, $kernel, $server, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1, ARG2];

  # save server, request, response object references to our selves...
  $self->{_server}   = $server;
  $self->{_request}  = $request;
  $self->{_response} = $response;

  $self->{_server_poe_session} = $server->getSessionId();

  $_log->debug("Starting handler ", ref($self), " in POE session: " . $_[SESSION]->ID()) if (DEBUG);

  # run the handler method...
  $kernel->yield("processRequest", $request, $response);
}

sub _stop {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  $_log->debug("Stopping handler ", ref($self), " POE session: " . $_[SESSION]->ID()) if (DEBUG);

  # was DONE|CLOSE event to sent to the server?
  unless ($self->{_finished}) {
    if ($self->{_check_done}) {
      $_log->debug("Request handler didn't send DONE event to http server; Sending it.") if (DEBUG);
      $self->requestFinishSync();
    }
    else {
      $_log->debug("Request handler didn't send DONE event to http server. Not sending it...") if (DEBUG);
    }
  }
}

sub _parent {
  my ($self, $old, $new) = @_[OBJECT, ARG0, ARG1];
  $_log->warn("Object ", ref($self), " parent POE session change: from ", $old->ID(), " to ", $new->ID())
    if (DEBUG);
}

sub _child {
  my ($self, $reason, $child) = @_[OBJECT, ARG0, ARG1];
  if ($reason eq 'close') {
    $_log->debug("_child: POE session exit: " . $child->ID()) if (DEBUG);
  }
  else {
    $_log->debug("_child: Reason: $reason; id: " . $child->ID()) if (DEBUG);
  }
}

sub _default {
  my ($self, $event, $args) = @_[OBJECT, ARG0, ARG1];
  my $str
    = "Object "
    . ref($self)
    . ", POE session "
    . $_[SESSION]->ID()
    . " caught unhandled event from session id '"
    . $_[SENDER]->ID()
    . "'. Called event '$event' with arguments: ["
    . join(", ", @{$args}) . "].";

  if (DEBUG) {
    $_log->warn($str);
  }
  else {
    print STDERR __PACKAGE__, " WARNING: $str\n";
  }
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # set error message
  $response->setError($request->uri()->path(),
    HTTP_SERVICE_UNAVAILABLE,
    "Handler <b>" . ref($self) . "</b> doesn't implement method <b>processRequest()</b>.");

  # we're done
  return $self->requestFinish($response);
}

sub authRequired {
  my ($self) = @_;
  return (defined $self->{auth_realm} && length($self->{auth_realm}) > 0) ? 1 : 0;
}

sub authUser {
  my ($self, $str) = @_;
  $self->{_auth_user} = $str if (defined $str);
  return $self->{_auth_user};
}

sub authRealm {
  my ($self, $str) = @_;
  $self->{auth_realm} = $str if (defined $str);
  return $self->{auth_realm};
}

sub authType {
  my ($self, $str) = @_;
  $self->{_auth_type} = $str if (defined $str);
  return $self->{_auth_type};
}

sub _getCGIEnv {
  my ($self)   = @_;
  my $request  = $self->{_request};
  my $response = $self->{_response};
  my $e        = {};
  my $server   = $self->getServer();
  my $hostname = hostname();

  $e->{GATEWAY_INTERFACE} = "CGI/1.1";
  $e->{SERVER_PROTOCOL}   = $request->protocol();
  $e->{SERVER_SOFTWARE}   = $server->getServerString();
  $e->{SERVER_NAME}       = $hostname;
  $e->{SERVER_PORT}       = $server->getListenPortByClient($response->wheel());
  $e->{SERVER_ADDR}       = $server->getListenIpByClient($response->wheel());

  $e->{REMOTE_PORT} = $response->remote_port();
  $e->{REMOTE_ADDR} = $response->remote_ip();

  $e->{HTTP_HOST}   = (($request->header("Host")) ? $request->header("Host") : $hostname);
  $e->{SCRIPT_NAME} = $request->uri()->path();
  $e->{REQUEST_URI} = $request->uri()->path();
  my $q = $request->uri()->query();
  $e->{QUERY_STRING} = (($q) ? $q : "");
  $e->{REQUEST_METHOD} = $request->method();

  my $x = undef;

  $x = $request->header("User-Agent");
  $e->{HTTP_USER_AGENT} = ($x) ? $x : "";

  $x = $request->header("Referer");
  $e->{HTTP_REFERER} = ($x) ? $x : "";

  $x = $request->header("Cookie");
  $e->{HTTP_COOKIE} = ($x) ? $x : "";

  $x = $request->header("Connection");
  $e->{HTTP_CONNECTION} = ($x) ? $x : "";

  $x = $request->header("Accept-Language");
  $e->{HTTP_ACCEPT_LANGUAGE} = ($x) ? $x : "";

  $x = $request->header("Accept-Encoding");
  $e->{HTTP_ACCEPT_ENCODING} = ($x) ? $x : "";

  $x = $request->header("Accept-Charset");
  $e->{HTTP_ACCEPT_CHARSET} = ($x) ? $x : "";

  $x = $request->header("Accept");
  $e->{HTTP_ACCEPT} = ($x) ? $x : "";

  $x = $request->header("Range");
  $e->{HTTP_RANGE} = ($x) ? $x : "";

  $x = $request->header("Content-Length");
  $e->{HTTP_CONTENT_LENGTH} = ($x) ? $x : "";

  $x = $request->header("Content-Type");
  $e->{HTTP_CONTENT_TYPE} = ($x) ? $x : "";

  # SSL stuff...
  if ($response->ssl()) {
    $e->{HTTPS}      = "on";
    $e->{SSL_CIPHER} = $response->sslcipher();
  }

=pod
	# auth stuff...
	if ($self->authenticated()) {
		$e->{REMOTE_USER} = $self->authUser();
		$e->{AUTH_TYPE} = $self->authType();
	}
=cut

  # TODO: is this right?
  $e->{REDIRECT_STATUS} = 200;

  return $e;
}

=item addRawOutput ($data)

=cut

sub addRawOutput {
  my ($self, $data) = @_;

  # don't bother with zero-length data...
  return 0 unless (defined $data && length($data) > 0);

  if (DEBUG) {
    my $len = length($data);
    $_log->debug("Got $len bytes of data.");

    # $_log->debug("DATA: $data");
  }

  if (!$self->{__got_headers}) {
    $self->{__content} .= $data;

    # do we have now enough data to parse http headers?
    #
    # this could be implemented much better (and faster!)...
    if ($self->{__content} =~ m/\r\n\r\n/m || $self->{__content} =~ m/\n\n/m) {
      my $fd_len = length($self->{__content});
      $_log->debug("Trying to parse headers from $fd_len bytes of data.") if (DEBUG);
      my $fd = IO::Scalar->new(\$self->{__content}, 'r');
      my $code = undef;
      while (<$fd>) {
        $_ =~ s/^\s+//g;
        $_ =~ s/\s+$//g;
        last unless (length($_) > 0);

        # HTTP status line and we don't have return code yet?
        if (!defined $code && $_ =~ m/^http\/\d+\.\d+\s+(\d+)/i) {
          $code = $1;
          if (DEBUG) {
            $_log->debug("Parsed HTTP status line with response code: $code");
          }
          next;
        }

        # try to parse line as standard HTTP header...
        my ($k, $v) = split(/\s*:\s*/, $_);
        if (defined $v) {

          # Status: 200 OK
          if (!defined $code && lc($k) eq 'status') {
            if ($v =~ m/^(\d+)/) {
              $code = $1;
              $_log->debug("Parsed CGI status line with response code: $code") if (DEBUG);
            }
          }

          # normal http header...
          else {
            $self->{_response}->header($k, $v);
          }
        }
        else {
          $_log->warn("Malformed HTTP header line: $_") if (DEBUG);
        }
      }

      # do we have response code?
      unless (defined $code && int($code) > 0) {
        $code = HTTP_OK;
        $_log->debug("No Status: header, setting default status code: " . HTTP_OK) if (DEBUG);
      }
      $_log->debug("Setting response status code: $code") if (DEBUG);
      $self->{_response}->code($code);

      # add content if there is any...
      my $pos = $fd->getpos();
      $_log->debug("Headers parsed on fd position: $pos/$fd_len") if (DEBUG);
      if ($pos < $fd_len) {
        my $d = substr($self->{__content}, $pos);
        $_log->debug("Adding left content as response body: ", length($d), " bytes.") if (DEBUG);
        $self->{_response}->content($d);
        $_log->debug("Posting HTTPEngine STREAM event.") if (DEBUG);
        $poe_kernel->post($self->{_server_poe_session}, "STREAM", $self->{_response});
      }

      $self->{__got_headers} = 1;
      $self->{__content}     = "";
      $_log->debug("Response headers were parsed, from now on will only add content to response object.")
        if (DEBUG);

      # $poe_kernel->post($self->{_server_poe_session}, "STREAM", $self->{_response});
      return 1;
    }
    else {
      $_log->debug(
        "Still not enough data to parse headers: Currently we've got ",
        length($self->{__content}),
        " bytes of accumulated data."
      ) if (DEBUG);
    }
  }
  else {
    $_log->debug("Adding data to content...") if (DEBUG);

    # just add the content data...
    if (length($self->{__content}) > 0) {
      $self->{_response}->content($self->{__content});
      $self->{__content} = "";
      $self->{_response}->add_content($data);
    }
    else {
      $self->{_response}->content($data);
    }

    # put response to server's output queue
    $_log->debug("Posting HTTPEngine STREAM event.") if (DEBUG);
    $poe_kernel->post($self->{_server_poe_session}, "STREAM", $self->{_response});
  }

  return 1;
}

sub requestFinish {
  my ($self, $response) = @_;
  $response = $self->{_response} unless (defined $response);

  # $_log->debug("Sending done event ($self->{_server_poe_session} => DONE): $response") if (DEBUG);

  $self->{_finished} = 1;
  return $poe_kernel->post($self->{_server_poe_session}, "DONE", $response,);
}

sub requestFinishSync {
  my ($self, $response) = @_;
  $response = $self->{_response} unless (defined $response);

  # $_log->debug("Sending done event ($self->{_server_poe_session} => DONE): $response") if (DEBUG);

  $self->{_finished} = 1;
  return $poe_kernel->call($self->{_server_poe_session}, "DONE", $response,);
}

sub requestClose {
  my ($self, $response) = @_;
  $response = $self->{_response} unless (defined $response);
  $self->{_finished} = 1;
  return $poe_kernel->post($self->{_server_poe_session}, "CLOSE", $response,);
}

sub logError {
  my $self = shift;

  # TODO: this message should be sent to http server loggers...
  $_log->error(@_) if (DEBUG);
}

sub errNotFound {
  my ($self, $response, $msg) = @_;
  $response->setError($self->getRequest()->uri()->path(),
    HTTP_NOT_FOUND, ($msg) ? $msg : "The requested URL was not found on this server.");
  return $self->requestFinish($response);
}

sub errForbidden {
  my ($self, $response, $msg) = @_;
  $response->setError($self->getRequest()->uri()->path(),
    HTTP_FORBIDDEN, ($msg) ? $msg : "The requested URL was not found on this server.");
  return $self->requestFinish($response);
}

sub sendError {
  my ($self, $response, $uri, $code, $msg) = @_;

  # set content...
  $response->setError($uri, $code, $msg);

  # push this one to server...
  return $poe_kernel->post($self->getServer->getSessionId(), "DONE", $response,);
}

sub renderDir {
  my ($self, $dir, $uri) = @_;
  $uri = "<undefined_uri>" unless (defined $uri);
  my $str = "";

  # list directory
  my @dirs  = ();
  my @files = ();

  # really list dirs...
  return undef unless ($self->_listDir($dir, \@dirs, \@files));

  my $srv_sig = "&nbsp;";
  $srv_sig = $self->getServer()->getServerSignature();

  # add header...
  $str .= <<END_HEADER;
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
<title>Index of $uri</title>
<style type="text/css">
a, a:active {text-decoration: none; color: blue;}
a:visited {color: #48468F;}
a:hover, a:focus {text-decoration: underline; color: red;}
body {background-color: #F5F5F5;}
h2 {margin-bottom: 12px;}
table {margin-left: 12px;}
th, td { font: 90% monospace; text-align: left;}
th { font-weight: bold; padding-right: 14px; padding-bottom: 3px;}
td {padding-right: 14px;}
td.s, th.s {text-align: right;}
div.list { background-color: white; border-top: 1px solid #646464; border-bottom: 1px solid #646464; padding-top: 10px; padding-bottom: 14px;}
div.foot { font: 90% monospace; color: #787878; padding-top: 4px;}
</style>
</head>
<body>
<h2>Index of $uri</h2>
<div class="list">
<table summary="Directory Listing" cellpadding="0" cellspacing="0">
<thead><tr><th class="n">Name</th><th class="m">Last Modified</th><th class="s">Size</th><th class="t">Type</th></tr></thead>
<tbody>
END_HEADER

  # link to parent directory...
  $str
    .= '<tr><td class="n"><a href="../">Parent Directory</a>/</td><td class="m">&nbsp;</td><td class="s">- &nbsp;</td><td class="t">Directory</td></tr>';

  # generate html table
  map {
    $str
      .= '<tr>'
      . '<td class="n"><a href="'
      . $uri
      . $_->{name}
      . (($_->{is_dir}) ? "/" : "") . '">'
      . $_->{name} . '</a>'
      . (($_->{is_dir}) ? "/" : "") . '</td>'
      . '<td class="m">'
      . strftime("%Y-%b-%d %H:%M:%S", localtime($_->{mtime})) . '</td>'
      . '<td class="s">'
      . $_->{size} . '</td>'
      . '<td class="t">'
      . $_->{type} . '</td>' . '</tr>';
  } @dirs, @files;

  # add footer...
  $str .= <<END_FOOTER
</tbody>
</table>
</div>
<div class="foot">$srv_sig</div>
</body>
</html>
END_FOOTER
    ;

  # return result...
  return $str;
}

sub shutdown {
  my $self = shift;
  $_log->warn("Forcing URL handler session shutdown: " . $poe_kernel->get_active_session()->ID()) if (DEBUG);

  # cleanup io wheels
  delete($self->{_io});

  return 1;
}

sub sendFile {
  my ($self, $file, $position) = @_;
  my $response = $self->{_response};
  $_log->debug("Sending file: '$file'.") if (DEBUG);

  # is this file?
  if (!-f $file) {
    $response->setError($self->getRequest()->uri()->path(),
      HTTP_SERVICE_UNAVAILABLE, "Requested resource is not a file.");
    return $self->requestFinish($response);
  }

  # readable?
  elsif (!-r $file) {
    return $self->errForbidden($response, "Permission denied.");
  }

  # stat the file
  my @s = stat($file);
  if (@s) {
    $response->header("Etag",           $s[9] . "-" . $s[7]);
    $response->header("Content-Length", $s[7]);
    $response->header("Last-Modified",  time2str($s[9]));
  }

  # if-modified-since header?
  # See: http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.25
  my $h = $self->{_request}->header("If-Modified-Since");
  if (defined $h) {
    my $t = str2time($h);
    if (defined $t && $t >= $s[7]) {
      $response->code(HTTP_NOT_MODIFIED);
      return $self->requestFinish($response);
    }
  }

  # if-unmodified-since header?
  # See: http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.28
  $h = $self->{_request}->header("If-Unmodified-Since");
  if (defined $h) {
    my $t = str2time($h);
    if (defined $t && $t <= $s[7]) {
      $response->code(HTTP_PRECONDITION_FAILED);
      return $self->requestFinish($response);
    }
  }

  # open file...
  my $fd = IO::File->new($file, 'r');
  unless ($fd) {
    $response->setError($self->getRequest()->uri()->path(),
      HTTP_INTERNAL_SERVER_ERROR, "Error while opening: $!.");
    return $self->requestFinish($response);
  }

  # guess media type...
  guess_media_type($file, $response);

  # yupee...
  $response->code(HTTP_OK);

  # TODO: handle partial content requests...
  my $num_bytes = -1;
  $h = $self->{_request}->header("Range");
  if (defined $h) {
    my ($start_byte, $num_bytes) = $self->_parseRange($h, $s[7]);

    # print "parse range result: '$start_byte', '$num_bytes'\n";

    # try to set position...
    if (defined($start_byte)) {

      # seek the file...
      if ($fd->seek($start_byte, 0)) {
        $response->code(HTTP_PARTIAL_CONTENT);

        # add required content-range header...
        # See: http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.16
        $response->header("Content-Range", $start_byte . "-" . ($start_byte + $num_bytes - 1) . "/" . $s[7]);

        # fix content-length header...
        $response->header("Content-Length", $num_bytes);

        #print "Set content-range: ", $response->header("Content-Range"), "\n";
        #print "Set content-length: ", $response->header("Content-Length"), "\n";
      }
      else {
        $response->setErr($self->{_request}->uri()->path(),
          HTTP_SERVICE_UNAVAILABLE, "Unable to seek the file to requested position.");
        return $self->requestFinish($response);
      }
    }
  }
  else {
    $response->code(HTTP_OK);
  }

  return $self->sendFd($fd, $num_bytes);
}

# Range HTTP header parser method...
# See: http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.35.1
sub _parseRange {
  my ($self, $str, $total_bytes) = @_;
  my ($start, $num) = (undef, undef);
  return (undef, undef) unless (defined $str);
  $_log->debug("PARSE_RANGE: '$str'; '$total_bytes'.") if (DEBUG);

  # remove bytes=
  $str =~ s/^\s*bytes=//g;
  $str =~ s/\s+//g;

  # The first 500 bytes (byte offsets 0-499, inclusive):
  # bytes=0-499
  #
  # The second 500 bytes (byte offsets 500-999, inclusive):
  # bytes=500-999
  if ($str =~ m/^(\d+)-(\d+)/) {
    $start = int($1);
    $num   = int($2) - $start + 1;
  }

  # The final 500 bytes (byte offsets 9500-9999, inclusive):
  # bytes=-500
  elsif ($str =~ m/^\-(\d+)$/) {
    $num   = int($1);
    $start = $total_bytes - $num;
  }

  # bytes=9500-
  elsif ($str =~ m/^(\d+)-$/) {
    $start = int($1);
    $num   = $total_bytes - $start;
  }

  # UNSUPPORTED:
  #	The first and last bytes only (bytes 0 and 9999):  bytes=0-0,-1
  # UNSUPPORTED:
  #	Several legal but not canonical specifications of the second 500
  #	bytes (byte offsets 500-999, inclusive):
  #
  #	bytes=500-600,601-999
  #	bytes=500-700,601-999

  # is start byte bigger than size?
  if ($start > $total_bytes) {
    return (undef, undef);
  }

  return ($start, $num);
}

sub sendFd {
  my ($self, $fd, $howmany) = @_;
  $howmany = -1 unless (defined $howmany);
  $_log->debug("Sending FD '$fd'; how many bytes: $howmany.") if (DEBUG);

  unless (defined $fd && fileno($fd) > 0) {
    $_log->error("bad filedescriptor.") if (DEBUG);

    # TODO: what to do now?
    return 0;
  }

  # create rw wheel...
  $self->{_io} = POE::Wheel::ReadWrite->new(
    Handle => $fd,

    # Driver => POE::Driver::SysRW->new(),
    Driver     => POE::Driver::SysRW->new(BlockSize => $self->{buffer_size}),
    Filter     => POE::Filter::Stream->new(),
    InputEvent => "__handleInput",
    ErrorEvent => "__handleError",
  );

  # how many bytes to read...
  $self->{_io_howmany} = $howmany;

  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub __handleInput {
  my ($self, $kernel, $data, $wheel_id) = @_[OBJECT, KERNEL, ARG0, ARG1];

  # check if client is still alive...
  my $client_wheel = $self->{_response}->wheel();
  unless ($self->{_server}->clientIsValid($client_wheel)) {
    $_log->warn("Our client disappered! Shutting down the wheel!") if (DEBUG);
    $self->requestFinish($self->{_response});
    delete($self->{_io});
    return 0;
  }

  my $len = 0;
  { use bytes; $len = length($data); }
  $_log->debug("Wheel $wheel_id read " . $len . " bytes.") if (DEBUG);

  # handling partial content?
  if ($self->{_io_howmany} >= 0) {

    # nuff read?
    if ($self->{_io_read} >= $self->{_io_howmany}) {
      return $self->requestFinish($self->{_response});
    }

    # how many bytes more?
    my $leftover = $self->{_io_howmany} - $self->{_io_read};

    if ($leftover < $len) {

      # TODO: usage of substr() is suspicious...
      $data = substr($data, 0, $leftover);
      $len = $leftover;
    }
  }

  # icrement counters...
  $self->{_io_read} += $len;

  # add data to response
  $self->{_response}->content($data);

  # enqueue for sending...
  $kernel->post($self->{_server_poe_session}, "STREAM", $self->{_response});

  return 1;
}

sub __handleError {
  my ($self, $operation, $errnum, $errstr, $wheel_id) = @_[OBJECT, ARG0 .. ARG3];

  # EOF on filehandle?
  if ($errnum == 0) {
    $_log->debug("EOF on wheel $wheel_id.") if (DEBUG);
  }
  else {
    $_log->error("I/O error $errnum occoured on wheel $wheel_id: $errstr") if (DEBUG);
  }

  # destroy the wheel
  delete($self->{_io});

  # finish the request...
  $self->requestFinish($self->{_response});

  return 1;
}

sub _listDir {
  my $self = shift;
  my $dir  = shift;
  my $dirh = undef;

  unless (opendir($dirh, $dir)) {
    $self->{_error} = "Unable to open directory '$dir': $!";
    return 0;
  }

  # read directory
  while (defined(my $e = readdir($dirh))) {

    # skip current and parent directory
    next unless ($e ne '.' && $e ne '..');

    # .dotfile? ;)
    next if (!$self->{show_dotfiles} && $e =~ m/^\./);

    # we are interested only in files and directories...
    my $p = File::Spec->catfile($dir, $e);
    next unless (-d $p || -f $p);
    my $is_dir = (-d $p);

    # stat it...
    my @s = stat($p);
    next unless (@s);

    my $d = {is_dir => $is_dir, type => (($is_dir) ? "Directory" : "File"), name => $e, mtime => $s[9],};

    # compute size...
    if ($s[7] < KB) {
      $d->{size} = $s[7] . "B";
    }
    elsif ($s[7] < MB) {
      $d->{size} = sprintf("%-.2fK", ($s[7] / KB));
    }
    elsif ($s[7] < GB) {
      $d->{size} = sprintf("%-.2fM", ($s[7] / MB));
    }
    else {
      $d->{size} = sprintf("%-.2fG", ($s[7] / GB));
    }

    if ($is_dir) {
      push(@{$_[0]}, $d);
    }
    else {
      push(@{$_[1]}, $d);
    }
  }
  closedir($dirh);

  # sort listing...
  @{$_[0]} = sort { $a->{name} cmp $b->{name} } @{$_[0]};
  @{$_[1]} = sort { $a->{name} cmp $b->{name} } @{$_[1]};

  return 1;
}

sub _parseMimeTypes {

  # my ($self) = @_;
  #if (DEBUG) {
  #	if (ref($self) && defined $_log) {
  #		$_log->debug("Parsing built-in mime-types.");
  #	}
  #}

  my $i    = 0;
  my $read = 0;
  while (<DATA>) {
    $read++;
    $_ =~ s/^\s+//g;
    $_ =~ s/\s+$//g;
    next unless (length($_));
    next if ($_ =~ m/^#/);
    next if ($_ !~ m/^[a-z]/);

    # parse line...
    my @tmp = split(/\s+/, $_);

    # there must be at least one extension for one media type...
    next if ($#tmp < 1);

    # inform LWP!
    add_type(@tmp);

    $i++;
  }
  close(DATA);

  # $_log->debug("Done parsing mime-types. Read $read lines, successfully parsed $i types.");
  return $i;

  $_mime_types_parsed = 1;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO
L<HTTP::Request>
L<HTTP::Response>
L<POE::Component::Server::HTTPEngine::Response>
L<POE::Component::Server::HTTPEngine>

=cut

1;

#
# MIME-Type data (taken from <apache>/conf/mime.types)...
#
__DATA__
# MIME type                     Extension
application/andrew-inset ez
application/chemtool cht
application/dicom dcm
application/docbook+xml docbook
application/ecmascript es
application/flash-video flv
application/illustrator ai
application/javascript js
application/mac-binhex40
application/mathematica nb
application/msword doc
application/octet-stream bin
application/oda oda
application/ogg ogg
application/pdf pdf
application/pgp pgp
application/pgp-encrypted
application/pgp-encrypted pgp gpg
application/pgp-keys
application/pgp-keys skr pkr
application/pgp-signature
application/pgp-signature sig
application/pkcs7-mime
application/pkcs7-signature p7s
application/postscript ps
application/rtf rtf
application/sdp sdp
application/smil smil smi sml
application/stuffit sit
application/vnd.corel-draw cdr
application/vnd.hp-hpgl hpgl
application/vnd.hp-pcl pcl
application/vnd.lotus-1-2-3 123 wk1 wk3 wk4 wks
application/vnd.mozilla.xul+xml xul
application/vnd.ms-excel xls xlc xll xlm xlw xla xlt xld
application/vnd.ms-powerpoint ppz ppt pps pot
application/vnd.oasis.opendocument.chart odc
application/vnd.oasis.opendocument.database odb
application/vnd.oasis.opendocument.formula odf
application/vnd.oasis.opendocument.graphics odg
application/vnd.oasis.opendocument.graphics-template otg
application/vnd.oasis.opendocument.image odi
application/vnd.oasis.opendocument.presentation odp
application/vnd.oasis.opendocument.presentation-template otp
application/vnd.oasis.opendocument.spreadsheet ods
application/vnd.oasis.opendocument.spreadsheet-template ots
application/vnd.oasis.opendocument.text odt
application/vnd.oasis.opendocument.text-master odm
application/vnd.oasis.opendocument.text-template ott
application/vnd.oasis.opendocument.text-web oth
application/vnd.palm pdb
application/vnd.rn-realmedia
application/vnd.rn-realmedia rm
application/vnd.rn-realmedia-secure rms
application/vnd.rn-realmedia-vbr rmvb
application/vnd.stardivision.calc sdc
application/vnd.stardivision.chart sds
application/vnd.stardivision.draw sda
application/vnd.stardivision.impress sdd sdp
application/vnd.stardivision.mail smd
application/vnd.stardivision.math smf
application/vnd.stardivision.writer sdw vor sgl
application/vnd.sun.xml.calc sxc
application/vnd.sun.xml.calc.template stc
application/vnd.sun.xml.draw sxd
application/vnd.sun.xml.draw.template std
application/vnd.sun.xml.impress sxi
application/vnd.sun.xml.impress.template sti
application/vnd.sun.xml.math sxm
application/vnd.sun.xml.writer sxw
application/vnd.sun.xml.writer.global sxg
application/vnd.sun.xml.writer.template stw
application/vnd.wordperfect wpd
application/x-abiword abw abw.CRASHED abw.gz zabw
application/x-amipro sam
application/x-anjuta-project prj
application/x-applix-spreadsheet as
application/x-applix-word aw
application/x-arc
application/x-archive a
application/x-arj arj
application/x-asax asax
application/x-ascx ascx
application/x-ashx ashx
application/x-asix asix
application/x-asmx asmx
application/x-asp asp
application/x-awk
application/x-axd axd
application/x-bcpio bcpio
application/x-bittorrent torrent
application/x-blender blender blend BLEND
application/x-bzip bz bz2
application/x-bzip bz2 bz
application/x-bzip-compressed-tar tar.bz tar.bz2
application/x-bzip-compressed-tar tar.bz tar.bz2 tbz tbz2
application/x-cd-image iso
application/x-cgi cgi
application/x-chess-pgn pgn
application/x-chm chm
application/x-class-file
application/x-cmbx cmbx
application/x-compress Z
application/x-compressed-tar tar.gz tar.Z tgz taz
application/x-compressed-tar tar.gz tgz
application/x-config config
application/x-core
application/x-cpio cpio
application/x-cpio-compressed cpio.gz
application/x-csh csh
application/x-cue cue
application/x-dbase dbf
application/x-dbm
application/x-dc-rom dc
application/x-deb deb
application/x-designer ui
application/x-desktop desktop kdelnk
application/x-devhelp devhelp
application/x-dia-diagram dia
application/x-disco disco
application/x-dvi dvi
application/x-e-theme etheme
application/x-egon egon
application/x-executable exe
application/x-font-afm afm
application/x-font-bdf bdf
application/x-font-dos
application/x-font-framemaker
application/x-font-libgrx
application/x-font-linux-psf psf
application/x-font-otf
application/x-font-pcf pcf
application/x-font-pcf pcf.gz
application/x-font-speedo spd
application/x-font-sunos-news
application/x-font-tex
application/x-font-tex-tfm
application/x-font-ttf ttc TTC
application/x-font-ttf ttf
application/x-font-type1 pfa pfb gsf pcf.Z
application/x-font-vfont
application/x-frame
application/x-frontline aop
application/x-gameboy-rom gb
application/x-gdbm
application/x-gdesklets-display display
application/x-genesis-rom gen md
application/x-gettext-translation gmo
application/x-glabels glabels
application/x-glade glade
application/x-gmc-link
application/x-gnome-db-connection connection
application/x-gnome-db-database database
application/x-gnome-stones caves
application/x-gnucash gnucash gnc xac
application/x-gnumeric gnumeric
application/x-graphite gra
application/x-gtar gtar
application/x-gtktalog
application/x-gzip gz
application/x-gzpostscript ps.gz
application/x-hdf hdf
application/x-ica ica
application/x-ipod-firmware
application/x-jamin jam
application/x-jar jar
application/x-java class
application/x-java-archive jar ear war

application/x-jbuilder-project jpr jpx
application/x-karbon karbon
application/x-kchart chrt
application/x-kformula kfo
application/x-killustrator kil
application/x-kivio flw
application/x-kontour kon
application/x-kpovmodeler kpm
application/x-kpresenter kpr kpt
application/x-krita kra
application/x-kspread ksp
application/x-kspread-crypt
application/x-ksysv-package
application/x-kugar kud
application/x-kword kwd kwt
application/x-kword-crypt
application/x-lha lha lzh
application/x-lha lzh
application/x-lhz lhz
application/x-linguist ts
application/x-lyx lyx
application/x-lzop lzo
application/x-lzop-compressed-tar tar.lzo tzo
application/x-macbinary
application/x-machine-config
application/x-magicpoint mgp
application/x-master-page master
application/x-matroska mkv
application/x-mdp mdp
application/x-mds mds
application/x-mdsx mdsx
application/x-mergeant mergeant
application/x-mif mif
application/x-mozilla-bookmarks
application/x-mps mps
application/x-ms-dos-executable exe
application/x-mswinurl
application/x-mswrite wri
application/x-msx-rom msx
application/x-n64-rom n64
application/x-nautilus-link
application/x-nes-rom nes
application/x-netcdf cdf nc
application/x-netscape-bookmarks
application/x-object o
application/x-ole-storage
application/x-oleo oleo
application/x-palm-database
application/x-palm-database pdb prc
application/x-par2 PAR2 par2
application/x-pef-executable
application/x-perl pl pm al perl
application/x-php php php3 php4
application/x-pkcs12 p12 pfx
application/x-planner planner mrproject
application/x-planperfect pln
application/x-prjx prjx
application/x-profile
application/x-ptoptimizer-script pto
application/x-pw pw
application/x-python-bytecode pyc pyo
application/x-quattro-pro wb1 wb2 wb3
application/x-quattropro wb1 wb2 wb3
application/x-qw qif
application/x-rar rar
application/x-rar-compressed rar
application/x-rdp rdp
application/x-reject rej
application/x-remoting rem
application/x-resources resources
application/x-resourcesx resx
application/x-rpm rpm
application/x-ruby
application/x-sc
application/x-sc sc
application/x-scribus sla sla.gz scd scd.gz
application/x-shar shar
application/x-shared-library-la la
application/x-sharedlib so
application/x-shellscript sh
application/x-shockwave-flash swf
application/x-siag siag
application/x-slp
application/x-smil kino
application/x-smil smi smil
application/x-sms-rom sms gg
application/x-soap-remoting soap
application/x-streamingmedia ssm
application/x-stuffit
application/x-stuffit bin sit
application/x-sv4cpio sv4cpio
application/x-sv4crc sv4crc
application/x-tar tar
application/x-tarz tar.Z
application/x-tex-gf gf
application/x-tex-pk k
application/x-tgif obj
application/x-theme theme
application/x-toc toc
application/x-toutdoux
application/x-trash   bak old sik
application/x-troff tr roff t
application/x-troff-man man
application/x-troff-man-compressed
application/x-tzo tar.lzo tzo
application/x-ustar ustar
application/x-wais-source src
application/x-web-config
application/x-wpg wpg
application/x-wsdl wsdl
application/x-x509-ca-cert der cer crt cert pem
application/x-xbel xbel
application/x-zerosize
application/x-zoo zoo
application/xhtml+xml xhtml
application/zip zip
audio/ac3 ac3
audio/basic au snd
audio/midi mid midi
audio/mpeg mp3
audio/prs.sid sid psid
audio/vnd.rn-realaudio ra
audio/x-aac aac
audio/x-adpcm
audio/x-aifc
audio/x-aiff aif aiff
audio/x-aiff aiff aif aifc
audio/x-aiffc
audio/x-flac flac
audio/x-it it
audio/x-m4a m4a
audio/x-mod mod ult uni XM m15 mtm 669
audio/x-mp3-playlist
audio/x-mpeg
audio/x-mpegurl m3u
audio/x-ms-asx
audio/x-pn-realaudio ra ram rm
audio/x-pn-realaudio ram rmm
audio/x-riff
audio/x-s3m s3m
audio/x-scpls pls
audio/x-scpls pls xpl
audio/x-stm stm
audio/x-voc voc
audio/x-wav wav
audio/x-xi xi
audio/x-xm xm
image/bmp bmp
image/cgm cgm
image/dpx
image/fax-g3 g3
image/g3fax
image/gif gif
image/ief ief
image/jpeg jpeg jpg jpe
image/jpeg2000 jp2
image/png png
image/rle rle
image/svg+xml svg
image/tiff tif tiff
image/vnd.djvu djvu djv
image/vnd.dwg dwg
image/vnd.dxf dxf
image/x-3ds 3ds
image/x-applix-graphics ag
image/x-cmu-raster ras
image/x-compressed-xcf xcf.gz xcf.bz2
image/x-dcraw bay BAY bmq BMQ cr2 CR2 crw CRW cs1 CS1 dc2 DC2 dcr DCR fff FFF k25 K25 kdc KDC mos MOS mrw MRW nef NEF orf ORF pef PEF raf RAF rdc RDC srf SRF x3f X3F
image/x-dib
image/x-eps eps epsi epsf
image/x-fits fits
image/x-fpx
image/x-icb icb
image/x-ico ico
image/x-iff iff
image/x-ilbm ilbm
image/x-jng jng
image/x-lwo lwo lwob
image/x-lws lws
image/x-msod msod
image/x-niff
image/x-pcx
image/x-photo-cd pcd
image/x-pict pict pict1 pict2
image/x-portable-anymap pnm
image/x-portable-bitmap pbm
image/x-portable-graymap pgm
image/x-portable-pixmap ppm
image/x-psd psd
image/x-rgb rgb
image/x-sgi sgi
image/x-sun-raster sun
image/x-tga tga
image/x-win-bitmap cur
image/x-wmf wmf
image/x-xbitmap xbm
image/x-xcf xcf
image/x-xfig fig
image/x-xpixmap xpm
image/x-xwindowdump xwd
inode/blockdevice
inode/chardevice
inode/directory
inode/fifo
inode/mount-point
inode/socket
inode/symlink
message/delivery-status
message/disposition-notification
message/external-body
message/news
message/partial
message/rfc822
message/x-gnu-rmail
model/vrml wrl
multipart/alternative
multipart/appledouble
multipart/digest
multipart/encrypted
multipart/mixed
multipart/related
multipart/report
multipart/signed
multipart/x-mixed-replace
text/calendar vcs ics
text/css css CSSL
text/directory vcf vct gcrd
text/enriched
text/html html htm
text/htmlh
text/mathml mml
text/plain txt asc
text/rdf rdf
text/rfc822-headers
text/richtext rtx
text/rss rss
text/sgml sgml sgm
text/spreadsheet sylk slk
text/tab-separated-values tsv
text/vnd.rn-realtext rt
text/vnd.wap.wml wml
text/x-adasrc adb ads
text/x-authors
text/x-bibtex bib
text/x-boo boo
text/x-c++hdr hh
text/x-c++src cpp cxx cc C c++
text/x-chdr h h++ hp
text/x-comma-separated-values csv
text/x-copying
text/x-credits
text/x-csharp cs
text/x-csrc c
text/x-dcl dcl
text/x-dsl dsl
text/x-dsrc d
text/x-dtd dtd
text/x-emacs-lisp el
text/x-fortran f
text/x-gettext-translation po
text/x-gettext-translation-template pot
text/x-gtkrc
text/x-haskell hs
text/x-idl idl
text/x-install
text/x-java java
text/x-js js
text/x-ksysv-log
text/x-literate-haskell lhs
text/x-log log
text/x-makefile
text/x-moc moc
text/x-msil il
text/x-nemerle n
text/x-objcsrc m
text/x-pascal p pas
text/x-patch diff patch
text/x-python py
text/x-readme
text/x-rng rng
text/x-scheme scm
text/x-setext etx
text/x-speech
text/x-sql sql
text/x-suse-ymp ymp
text/x-suse-ymu ymu
text/x-tcl tcl tk
text/x-tex tex ltx sty cls
text/x-texinfo texi texinfo
text/x-texmacs tm ts
text/x-troff-me me
text/x-troff-mm mm
text/x-troff-ms ms
text/x-uil uil
text/x-uri uri url
text/x-vb vb
text/x-xds xds
text/x-xmi xmi
text/x-xsl xsl
text/x-xslfo fo xslfo
text/x-xslt xslt xsl
text/xmcd
text/xml xml
video/3gpp 3gp
video/dv dv dif
video/isivideo
video/mpeg mpeg mpg mp2 mpe vob dat
video/quicktime qt mov moov qtvr
video/vivo
video/vnd.rn-realvideo rv
video/wavelet
video/x-3gpp2 3g2
video/x-anim anim[1-9j]
video/x-avi
video/x-flic fli flc
video/x-mng mng
video/x-ms-asf asf asx
video/x-ms-wmv wmv
video/x-msvideo avi
video/x-nsv nsv NSV
video/x-real-video
video/x-sgi-movie movie
application/x-java-jnlp-file      jnlp

# this is a comment..
__END__
