package ACME::TC::Agent::Plugin::ConnectorWebHandler::DataInfo;

use strict;
use warnings;

use POE;
use HTTP::Status qw(:constants);
use POE::Component::Server::HTTPEngine::Handler;

use base 'POE::Component::Server::HTTPEngine::Handler';

our $VERSION = 0.02;

my $has_json = eval 'use JSON; 1';

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
      )
  );

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

  # vmstat session
  $self->{session} = "session_name";

  # prefix...
  $self->{prefix} = "datafetch";
}

sub getDescription {
  return "Generic purpose agent plugin info fetching module.";
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0 .. ARG2];

  # get some stuff...
  my $session = $request->uri()->query_param("session");
  $session = $self->{session} unless (defined $session);

  my $prefix = $request->uri()->query_param("prefix");
  $prefix = $self->{prefix} unless (defined $prefix);

  # get data...
  my $data = $kernel->call($session, "dataGet");
  unless (defined $data) {
    $response->setError($request->uri()->path(),
      HTTP_SERVICE_UNAVAILABLE, "Error fetching statistical data from session '$session': $!");
    return $self->requestFinish();
  }

  # reset plugin gathered data?
  my $reset = $request->uri()->query_param("reset");
  $reset = lc($reset) if (defined $reset);
  if (defined $reset && ($reset eq '1' || $reset eq 'true' || $reset eq 'y' || $reset eq 'yes')) {
    $kernel->call($session, "dataReset");
  }

  my $json = 0;
  if ($has_json) {
    my $json_s = $request->uri->query_param("json");
    my $accept = $request->header('Accept');
    if ( (defined $json_s && ($json_s eq '1' || $json_s eq 'true' || $json_s eq 'y' || $json_s eq 'yes'))
      || (defined $accept && $accept =~ m/\/json/i))
    {
      $json = 1;
    }
  }

  # fill the response object
  $response->code(HTTP_OK);
  if ($json) {
    $response->header("Content-Type", "application/json; charset=utf-8");
  }
  else {
    $response->header("Content-Type", "text/plain; charset=utf-8");
  }

  if (exists($data->{__queue_len}) && defined $data->{__queue_len} && length($data->{__queue_len}) > 0) {
    $response->add_content("qsize=" . $data->{__queue_len} . "\n\n") unless ($json);
    delete($data->{__queue_len});
  }

  # add data...
  if ($json) {
    $response->add_content(encode_json($data));
  }
  else {
    foreach (sort keys %{$data}) {
      next if ($_ =~ m/^_/);
      my $content = "$_=" . sprintf("%-.2f", $data->{$_}) . "\n";
      $content = $prefix . $content if (defined $prefix && length $prefix > 0);
      $response->add_content($content);
    }
  }

  # truncate data...
  $data = undef;

  # add the search ok stuff...
  unless ($json) {
    $response->add_content("\n");
    $response->add_content("<!--SEARCH OK-->\n");
  }

  # we're done!
  return $self->requestFinish($response);
}

##################################################
#               PRIVATE METHODS                  #
##################################################

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
