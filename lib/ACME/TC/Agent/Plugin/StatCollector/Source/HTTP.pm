package ACME::TC::Agent::Plugin::StatCollector::Source::HTTP;


use strict;
use warnings;

use POE;
use URI;
use bytes;
use Log::Log4perl;
use MIME::Base64 qw(encode_base64);

use ACME::TC::Agent::Plugin::StatCollector::Source;
use ACME::TC::Agent::Plugin::StatCollector::Source::_Socket;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Source::_Socket);

use constant HTTP_PROXY_PORT_DEFAULT => 8888;

our $VERSION = 0.04;

# try to load compressed response support
my $_has_compress = 0;
eval {
  require IO::Uncompress::AnyInflate;
  IO::Uncompress::AnyInflate->import(qw(anyinflate));
  $_has_compress = 1;
};

# logging object
my $_log = Log::Log4perl->get_logger(__PACKAGE__);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Source::HTTP

Very simple HTTP statistics source implementation with SSL and compression support...

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts all named parameters supported by 
L<ACME::TC::Agent::Plugin::StatCollector::Source>,
L<ACME::TC::Agent::Plugin::StatCollector::Source::_Socket>
and the following ones:

=over

=item B<url> (string, "http://localhost/")

Try to load specified http URL.

=item B<compression> (boolean, 1)

Request compressed response body. This option is only efective
if perl module L<IO::Uncompress::AnyInflate> can be loaded, otherwise
is ignored.

=item B<userAgent> (string, "StatCollector::Source::HTTP/<version>")

Sets user-agent request header.

=item B<headerHost> (string, undef)

Sets custom HTTP Host: header. If omitted hostname from URL
address will be used.

=item B<username> (string, undef)

Sets HTTP request username. Requires valid B<password> parameter.

=item B<password> (string, undef)

Sets HTTP request password. Requires valid B<username> parameter.

=item B<httpProxy> (string, undef)

Send HTTP request using specified HTTP proxy server. This propery
must be set in form B<HOSTNAME[:PORT]>. Default HTTP proxy port
is B<8888>.

=back

=cut

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{url}         = "http://localhost/";          # HTTP URL
  $self->{compression} = 1;                            # HTTP compression
  $self->{userAgent}   = $self->_getDefaultUaStr();    # User-Agent
  $self->{headerHost}  = undef;                        # forced Host: request header
  $self->{username}    = undef;                        # http auth username
  $self->{password}    = undef;                        # http auth password
  $self->{httpProxy}   = undef;                        # http proxy

  delete($self->{useSSL});

  # clear buffers...
  $self->_clearBuf();

  # we have additional event handlers...
  $self->registerEvent(
    qw(
      validateHTTPResponse
      )
  );

  # must return 1 on success
  return 1;
}

sub _getDefaultUaStr {
  my @tmp = split(/::/, __PACKAGE__);
  my $str = pop(@tmp);
  $str = pop(@tmp) . "::" . $str;
  $str = pop(@tmp) . "::" . $str;
  $str .= "/" . sprintf("%-.2f", $VERSION);
  return $str;
}

sub getFetchUrl {
  my ($self) = @_;
  return $self->{url};
}

sub getHostname {
  my ($self) = @_;
  $self->{_uri}->host();
}

sub getPort {
  my ($self) = @_;
  return $self->{_uri}->port();
}

sub validateHTTPResponse {
  my ($self) = @_;
  return 0 if ($self->{_isEmpty});

  # nothing usable was read?
  unless (defined $self->{_httpStatus} && $self->{_httpStatusCode} > 0) {
    $poe_kernel->yield(FETCH_ERR, "Invalid (zero-length) HTTP status response.");
    $poe_kernel->yield("disconnect");
    $self->_clearBuf();
    return 0;
  }

  my $code = $self->{_httpStatusCode};
  my $str  = $self->{_httpStatus};

  # $_log->debug("Got code: $code, status: $str");

  if ($code == 200) {

    # http compression?
    if ($self->{_responseCompressed} && $_has_compress) {
      my $uncompressed = "";

      # try to uncompress
      my $len_a = 0;
      if ($_log->is_debug()) {
        $len_a = length($self->{_responseBody});
      }
      unless (anyinflate(\$self->{_responseBody}, \$uncompressed)) {
        no warnings;
        my $err = "Error uncompressing http response body: " . $IO::Uncompress::AnyInflate::AnyInflateError;
        $poe_kernel->yield(FETCH_ERR, $err);
        $self->_clearBuf();
        return $poe_kernel->yield("disconnect");
      }
      $self->{_responseBody} = $uncompressed;
      undef $uncompressed;
      if ($_log->is_debug()) {
        my $len_b = length($self->{_responseBody});
        $_log->debug($self->getFetchSignature(),
          " Uncompressed $len_b bytes from $len_a bytes of compressed HTTP response.");
      }
    }

    $poe_kernel->yield(FETCH_OK, $self->{_responseBody});
  }
  else {
    $poe_kernel->yield(FETCH_ERR, $self->{_httpStatus});
  }

  # clear buffers...
  $self->_clearBuf();

  # disconnect...
  $poe_kernel->yield("disconnect");
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _run {
  my ($self) = @_;

  # check URL...
  unless (defined $self->{url} && length($self->{url})) {
    $self->{_error} = "Invalid URL address.";
    return 0;
  }

  # check http proxy...
  if (defined $self->{httpProxy}) {
    $self->{httpProxy} =~ s/\s+//g;
    unless (length($self->{httpProxy}) > 0) {
      $_log->warn("Invalid HTTP proxy specification, disabling HTTP proxy feature.");

      # just undefine it...
      $self->{httpProxy} = undef;
    }
  }

  # check username
  if (defined $self->{username}) {
    $self->{username} =~ s/\s+//g;
    unless (length($self->{username}) > 0) {

      # just undefine it...
      $self->{username} = undef;
    }

    if (defined $self->{username} && !defined $self->{password}) {
      $self->{_error} = "Username property is defined while password property isn't.";
      return 0;
    }
  }

  my $uri = URI->new($self->{url});
  unless (defined $uri && (ref($uri) eq 'URI::http' || ref($uri) eq 'URI::https')) {
    $self->{_error} = "Invalid URL: $self->{url}";
    return 0;
  }

  # SSL stuff?
  $self->{useSSL} = ($uri->scheme() eq 'https') ? 1 : 0;

  $self->{_uri} = $uri;

  # everything is ok, start fetching data...
  return 1;
}

sub _fetchStart {
  my ($self) = @_;

  $self->_clearBuf();

  my $host = undef;
  my $port = undef;

  # should we connect trough http proxy?
  if (defined $self->{httpProxy}) {
    my @tmp = split(/:/, $self->{httpProxy});

    # <host>:<port> declaration?
    if ($#tmp > 0) {
      $port = pop(@tmp);
      $host = join(":", @tmp);
    }
    else {
      $host = $self->{httpProxy};
      $port = HTTP_PROXY_PORT_DEFAULT;
    }
  }
  else {
    $host = $self->{_uri}->host();
    $port = $self->{_uri}->port();
  }

  $_log->debug($self->getFetchSignature(), " Will connect to host: '$host', port '$port'.");

  # connect
  $poe_kernel->yield("connect", $host, $port);

  return 1;
}

sub _fetchCancel {
  my ($self) = @_;
  $poe_kernel->yield("disconnect");
  $self->_clearBuf();
  return 1;
}

sub _connOk {
  my ($self) = @_;

  # get connection rw wheel
  my $wheel = $self->getWheel();
  unless (defined $wheel) {
    $poe_kernel->yield(FETCH_ERR, "Unable to get connection wheel: " . $self->getError());
    return 0;
  }

  # apply custom filters on connection wheel
  $wheel->set_output_filter(POE::Filter::Stream->new());
  $wheel->set_input_filter(POE::Filter::Line->new());


  # now prepare HTTP request...
  # HTTP Host: header
  my $host_header = '';
  if (defined $self->{headerHost} && length($self->{headerHost}) > 0) {
    $host_header = $self->{headerHost};
  }
  else {
    $host_header = $self->{_uri}->host();

    my $scheme = $self->{_uri}->scheme();
    my $port   = $self->{_uri}->port();
    if ($scheme eq 'http' && $port != 80) {
      $host_header .= ":" . $port;
    }
    elsif ($scheme eq 'https' && $port != 443) {
      $host_header .= ":" . $port;
    }
  }

  my $path = undef;
  if (defined $self->{httpProxy}) {
    $path = $self->{url};
  }
  else {
    $path = $self->{_uri}->path_query();
  }
  $path = "/" unless (defined $path && length($path) > 0);
  my $req = "GET " . $path;
  $req .= " HTTP/1.1\r\n";
  $req .= "Host: " . $host_header . "\r\n";
  $req .= "User-Agent: " . $self->{userAgent} . "\r\n";

  # are we requesting compressed response?
  if ($self->{compression}) {
    if ($_has_compress) {
      $req .= "Accept-Encoding: gzip,deflate\r\n";
    }
    else {
      $_log->warn($self->getFetchSignature(),
        " Requested HTTP response compression, but perl module IO::Uncompress::AnyInflate is not available on this system; ignoring."
      );
    }
  }

  # http credentials...
  if (defined $self->{username} && defined $self->{password}) {
    my $str = "Basic ";
    $str .= encode_base64($self->{username} . ":" . $self->{password}, "");
    $_log->trace($self->getFetchSignature(), " Setting Authorization header to: '$str'.");
    $req .= "Authorization: " . $str . "\r\n";
  }

  # $req .= "Connection: close\r\n";
  $req .= "\r\n";

  if ($_log->is_trace()) {
    $_log->trace($self->getFetchSignature(), " --- BEGIN HTTP REQUEST ---\n" . $req);
    $_log->trace($self->getFetchSignature(), " --- END HTTP REQUEST ---");
  }

  # clear buffers
  $self->_clearBuf();

  # send data to wheel...
  #$poe_kernel->yield("sendData", $req);
  return $self->sendData($req);

  return 1;
}

sub rwInput {
  my ($self, $kernel, $data, $wid) = @_[OBJECT, KERNEL, ARG0, ARG1];

  $self->{_isEmpty} = 0;

  if ($self->{_gotHeaders} == 0) {
    $self->_addHeaderData($data);
  }
  else {
    if ($self->{_stopReading}) {
      $kernel->yield("validateHTTPResponse");
      return 1;
    }
    $self->_addBodyData($data);
  }

  return 1;
}

sub rwError {
  my ($self, $kernel, $operation, $errno, $errstr, $id) = @_[OBJECT, KERNEL, ARG0 .. $#_];

  # $_log->debug("EEEEEEEEEEEEEEEV error, ERRNO: $errno, operation: $operation...");

  # errno == 0; this is usually EOF...
  if ($errno == 0 && $operation eq 'read') {

    # validate and send what we've got so far...
    # $_log->debug("bomo validiral http response...");
    $kernel->yield('validateHTTPResponse');
  }
  else {
    $kernel->yield(FETCH_ERR,
      "Error $errno accoured while performing operation $operation on wheel $id: $errstr");

    $self->_clearBuf();
    $kernel->yield("disconnect");

  }
}

sub _clearBuf() {
  my ($self) = @_;

  $self->{_isEmpty}               = 1;        # nothing was read yet.
  $self->{_headers}               = [];       # headers array
  $self->{_httpStatus}            = undef;    # HTTP response status line
  $self->{_httpStatusCode}        = 0;        # HTTP response error code
  $self->{_gotHeaders}            = 0;        # flag; headers have been read
  $self->{_responseBody}          = '';       # HTTP response body content
  $self->{_responseBodyRead}      = 0;        # number of bytes read...
  $self->{_responseContentLength} = -1;       # HTTP response content-length header (if any)
  $self->{_responseCompressed}    = 0;        # flag; response is compressed somehow
  $self->{_responseChunked}       = 0;        # flag; response is sent in chunked transfer encoding
  $self->{_stopReading}           = 0;        # stop reading HTTP response body

  $self->{_chunkedGotChunk}  = 0;
  $self->{_chunkedRemaining} = 0;

  $self->{_host} = undef;
  $self->{_port} = undef;
}

sub _addHeaderData {
  my ($self, $data) = @_;
  return 0 unless (defined $data);

  $data =~ s/\s+$//g;
  if ($_log->is_trace()) {
    $_log->trace($self->getFetchSignature(), " HTTP response header (" . length($data) . " bytes): '$data'");
  }

  # empty line? this means end of headers...
  if (length($data) == 0) {

    # http body can't start before http response status is
    # read.
    unless (defined $self->{_httpStatus}) {
      $poe_kernel->yield(FETCH_ERR, "Got end-of-headers, but HTTP response status line hasn't been read.");
      $self->_clearBuf();
      return 0;
    }

    $self->{_gotHeaders} = 1;

    # we have read headers,
    # now we want unspoiled and
    # unfiltered body; change input filter.
    my $wheel = $self->getWheel();
    unless (defined $wheel) {
      $poe_kernel->yield(FETCH_ERR, "Unable to get connection RW wheel: " . $self->getError());
      return 0;
    }
    $wheel->set_input_filter(POE::Filter::Stream->new());
    $_log->trace($self->getFetchSignature(), " HTTP headers read, now reading HTTP response body.");
  }
  else {

    # HTTP response status line?
    if (!defined $self->{_httpStatus}) {

      # HTTP/1.1 200 OK
      if ($data =~ m/^HTTP\/\d+\.\d+\s+(\d+)\s+(.+)/) {
        $self->{_httpStatus}     = $1 . " " . $2;
        $self->{_httpStatusCode} = $1;

        # HTTP redirects are not supported
        if ($self->{_httpStatusCode} > 300 && $self->{_httpStatusCode} < 303) {

          # http redirects should not contain http body
          $self->{_stopReading} = 1;
        }
      }
      else {

        # something is wrong...
        $poe_kernel->yield(FETCH_ERR, "Invalid HTTP response status line: $data");
        $self->_clearBuf();
        return 0;
      }
      return 1;
    }

    # HTTP response headers...
    # is this Content-Encoding header (is response body compressed)?
    elsif (!$self->{_responseCompressed} && $data =~ m/^content-encoding:\s+(.*)/i) {
      my $tmp = $1;
      if ($tmp =~ m/(gzip|deflate)/i) {
        $self->{_responseCompressed} = 1;
        $_log->debug($self->getFetchSignature(), " HTTP response is compressed using $tmp.");
      }
    }

    # chunked transfer encoding?
    elsif (!$self->{_responseChunked} && $data =~ m/^transfer-encoding:\s+chunked/i) {
      $self->{_responseChunked} = 1;
      $_log->debug($self->getFetchSignature(), " HTTP response is using chunked transfer encoding.");
    }

    # content-length?
    elsif ($self->{_responseContentLength} < 0 && $data =~ m/^content-length:\s+(\d+)/i) {
      $self->{_responseContentLength} = $1;
    }

    # save header (maybe we'll need them one fine day)
    push(@{$self->{_headers}}, $data);
  }

  return 1;
}

sub _addBodyData {
  my ($self, $data) = @_;

  # is response chunked?
  if ($self->{_responseChunked}) {
    $self->_addBodyDataChunked(\$data);
  }
  else {

    # nope, it's not...
    $self->{_responseBody} .= $data;
    $self->{_responseBodyRead} += length($data);

    # do we have enough?
    if ($self->{_responseContentLength} >= 0 && $self->{_responseBodyRead} >= $self->{_responseContentLength})
    {
      $poe_kernel->yield("validateHTTPResponse");
    }
  }
}

# parses some rand piece of http-chunked data...
sub _addBodyDataChunked {
  my ($self, $data) = @_;
  return 0 unless (defined $data);

  if ($_log->is_trace()) {
    my $len = length($$data);
    $_log->trace($self->getFetchSignature(), " Trying to parse $len bytes of raw chunked data.");
  }

  while (1) {

    # try to parse some data from what we got.
    my $chunk = $self->_parseChunk($data);

    # nothing parsed?
    last if (!defined $chunk);
    my $clen = length($chunk);

    $self->{_responseBody} .= $chunk;
    $self->{_responseBodyRead} += $clen;

    if ($_log->is_trace()) {
      $_log->trace($self->getFetchSignature(),
        " Parsed ", $clen,
        " bytes of chunked data; " . length($$data) . " bytes of raw chunk still remaining.");
      $_log->trace($self->getFetchSignature(), " --- BEGIN PARSED CHUNK---\n$chunk");
      $_log->trace($self->getFetchSignature(), " --- END PARSED CHUNK---\n");
    }
  }

  return 1;
}

# tries to weed out part of http chunk...
sub _parseChunk {
  my ($self, $d) = @_;
  return undef unless (defined $d && defined $$d);

  my $len = length($$d);
  return undef unless ($len > 0);

  # got chunk metadata?
  if ($self->{_chunkedGotChunk}) {
    $_log->trace($self->getFetchSignature(), " We have chunk metadata.");

    # yup... let's try to read this chunk only...
    if ($len >= $self->{_chunkedRemaining}) {
      $_log->trace($self->getFetchSignature(), " len $len >= chunked remaining $self->{_chunkedRemaining}.");

      # weed out the rest of chunk
      my $chunk = substr($$d, 0, ($self->{_chunkedRemaining} - 2));

      # shrink original data
      $$d = substr($$d, $self->{_chunkedRemaining});

      # we don't have chunk anymore; chunk read successfully
      $self->{_chunkedGotChunk}  = 0;
      $self->{_chunkedRemaining} = 0;

      return $chunk;
    }
    else {
      $_log->trace($self->getFetchSignature(), " len $len < chunked remaining $self->{_chunkedRemaining}.");

      # imamo manj, kot bi radi...
      my $chunk = $$d;
      $$d = '';

      $self->{_chunkedRemaining} -= $len;
      return $chunk;
    }

  }
  else {
    $_log->trace($self->getFetchSignature(), "We don't have chunk metadata.");

    # nope, we need to parse this data
    # for http chunk metadata...
    if ($$d =~ m/^([0-9a-f]+)/mi) {

      # yep, it is...
      # how many bytes does this chunk hold?
      my $metadata     = $1;
      my $metadata_len = length($metadata) + 2;
      my $chunk_len    = hex($metadata);

      # remove metadata string from original data
      $$d = substr($$d, $metadata_len);

      $self->{_chunkedGotChunk}  = 1;
      $self->{_chunkedRemaining} = $chunk_len + 2;
      $_log->trace($self->getFetchSignature(),
        " Parsed chunk metadata. Chunk len = $chunk_len (hex: $metadata); remaining data including footer: $self->{_chunkedRemaining}."
      );

      # zero-length chunk?
      # this means end of response!
      if ($chunk_len == 0) {
        $self->_stopReading();
      }

      return '';
    }
    else {
      $_log->error($self->getFetchSignature(),
        "Unable to parse http chunk metadata; discarding entire buffer.");
      my $chunk = $$d;
      $$d = "";
      return undef;
    }
  }
}

sub _stopReading {
  my ($self) = @_;

  # we don't want to read anymore from connection handle
  $self->{_stopReading} = 1;

  # shutdown input
  my $wheel = $self->getWheel();
  if (defined $wheel) {

    #$wheel->shutdown_input();
  }

  # we read everything we wanted, it's time
  # to validate what we've got
  $poe_kernel->yield("validateHTTPResponse");
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent::Plugin::StatCollector::Source::_Socket>
L<ACME::TC::Agent::Plugin::StatCollector::Source>
L<ACME::TC::Agent::Plugin::StatCollector>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
