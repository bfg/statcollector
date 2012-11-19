package ACME::TC::Agent::Plugin::Vmstat::WebHandler;


use strict;
use warnings;

use POE;
use HTTP::Status qw(:constants);
use POE::Component::Server::HTTPEngine::Handler;

use vars qw(@ISA);
@ISA = qw(POE::Component::Server::HTTPEngine::Handler);

our $VERSION = 0.13;

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;

  # vmstat session
  $self->{session} = "vmstat";
}

sub getDescription {
  return "VMstat agent plugin info fetching module.";
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0 .. ARG2];

  # maybe our client wants instructions how to use this module
  my $h = $request->uri()->query_param("help");
  if (defined $h) {
    $self->usage($response);
    return $self->requestFinish($response);
  }

  # get data...
  my $data = $kernel->call($self->{session}, "dataGet");
  unless (defined $data) {
    $response->setError($request->uri()->path(),
      HTTP_SERVICE_UNAVAILABLE, "Error calling vmstat session '$self->{session}': $!");
    return $self->requestFinish();
  }

  # reset plugin gathered data?
  my $reset = $request->uri()->query_param("reset");
  $reset = lc($reset) if (defined $reset);
  if (defined $reset && ($reset eq '1' || $reset eq 'true' || $reset eq 'y' || $reset eq 'yes')) {
    $kernel->call($self->{session}, "dataReset");
  }

  # fill the response object
  $response->code(HTTP_OK);
  $response->header("Content-Type", "text/plain");

  # how were we called?
  my $method = "getAvg";
  my $mode   = $request->uri()->query_param("mode");
  if (defined $mode && length($mode)) {
    $mode = lc($mode);
    if ($mode eq 'max') {
      $method = "getMax";
    }
    elsif ($mode eq 'min') {
      $method = "getMin";
    }
    elsif ($mode eq 'med') {
      $method = "getMedian";
    }
  }

  $response->add_content("qsize=" . $data->{cpu_us}->size() . "\n\n");

  # add data...
  $response->add_content("vmstat us=" . sprintf("%-.2f", $data->{cpu_us}->$method()) . "\n");
  $response->add_content("vmstat sys=" . sprintf("%-.2f", $data->{cpu_sy}->$method()) . "\n");
  $response->add_content("vmstat wa=" . sprintf("%-.2f", $data->{cpu_wa}->$method()) . "\n");
  $response->add_content("vmstat bi=" . sprintf("%-.2f", $data->{io_bi}->$method()) . "\n");
  $response->add_content("vmstat bo=" . sprintf("%-.2f", $data->{io_bo}->$method()) . "\n");
  $response->add_content("vmstat cache=" . sprintf("%-.2f", $data->{mem_cache}->$method()) . "\n");
  $response->add_content("vmstat free=" . sprintf("%-.2f", $data->{mem_free}->$method()) . "\n");
  $response->add_content("vmstat buff=" . sprintf("%-.2f", $data->{mem_buff}->$method()) . "\n");
  $response->add_content("vmstat swpd=" . sprintf("%-.2f", $data->{mem_swpd}->$method()) . "\n");

  $response->add_content("\n");
  foreach (sort keys %{$data}) {
    next if ($_ =~ m/^_/);
    $response->add_content("vmstat $_=" . sprintf("%-.2f", $data->{$_}->$method()) . "\n");
  }

  #
  $data = undef;

  # add the search ok stuff...
  $response->add_content("\n");
  $response->add_content("<!--SEARCH OK-->\n");

  # we're done!
  return $self->requestFinish($response);
}

sub usage {
  my ($self, $response) = @_;
  $response->code(HTTP_OK);
  $response->add_content(
    qq(
This handler can be called with several query parameters:

* reset={0|1} (default: "0")                :: resets internal vmstat counters
* mode={avg|max|min|med} (default: "avg")   :: returns average, maximum, minimum or median values of stored vmstat output
* help                                      :: this message
)
  );
}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Plugin>
L<POE::Component::Server::HTTPEngine>
L<POE::Component::Server::HTTPEngine::Handler>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
