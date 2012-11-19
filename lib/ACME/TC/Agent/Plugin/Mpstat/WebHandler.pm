package ACME::TC::Agent::Plugin::Mpstat::WebHandler;


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

  # mpstat session
  $self->{session} = "mpstat";
}

sub getDescription {
  return "MPstat agent plugin info fetching module.";
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
      HTTP_SERVICE_UNAVAILABLE, "Error calling mpstat session '$self->{session}': $!");
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

  #$response->add_content("qsize=" . $data->{cpu_us}->size() . "\n\n");

  # add data...
  #$response->add_content("mpstat cpu=" . sprintf("%-.2f", $data->{"cpu"}->$method()) . "\n");
  #$response->add_content("mpstat usr=" . sprintf("%-.2f", $data->{"usr"}->$method()) . "\n");
  #$response->add_content("mpstat nice=" . sprintf("%-.2f", $data->{"nice"}->$method()) . "\n");
  #$response->add_content("mpstat sys=" . sprintf("%-.2f", $data->{"sys"}->$method()) . "\n");
  #$response->add_content("mpstat iowait=" . sprintf("%-.2f", $data->{"iowait"}->$method()) . "\n");
  #$response->add_content("mpstat irq=" . sprintf("%-.2f", $data->{"irq"}->$method()) . "\n");
  #$response->add_content("mpstat soft=" . sprintf("%-.2f", $data->{"soft"}->$method()) . "\n");
  #$response->add_content("mpstat steal=" . sprintf("%-.2f", $data->{"steal"}->$method()) . "\n");
  #$response->add_content("mpstat guest=" . sprintf("%-.2f", $data->{"guest"}->$method()) . "\n");
  #$response->add_content("mpstat idle=" . sprintf("%-.2f", $data->{"idle"}->$method()) . "\n");

  #$response->add_content("\n");
  foreach (sort keys %{$data}) {
    next if ($_ =~ m/^_/);
    $response->add_content("mpstat $_=" . sprintf("%-.2f", $data->{$_}->$method()) . "\n");
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

* reset={0|1} (default: "0")                :: resets internal mpstat counters
* mode={avg|max|min|med} (default: "avg")   :: returns average, maximum, minimum or median values of stored mpstat output
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
