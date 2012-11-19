package ACME::TC::Agent::Plugin::StatCollector::Parser::Apache;


use strict;
use warnings;

use IO::Scalar;

use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

our $VERSION = 0.11;

use constant MAX_LINES => 100;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::Apache

Apache/Lighttpd server-status statistics parser.

=head1 DESCRIPTION

This parser parses output of apache server-status output. Warning: Source must query
Apache server-status url with query parameter ?auto, becouse this parser is able to parse
only machine-readable mod_status output. For more info, see
L<http://httpd.apache.org/docs/2.2/mod/mod_status.html#machinereadable>.

This parses is also able to parse lighttpd's machine readable server-status
output.

B<SOURCE:>
 Total Accesses: 15407604
 Total kBytes: 398495390
 CPULoad: .00174067
 Uptime: 2674832
 ReqPerSec: 5.76021
 BytesPerSec: 152555
 BytesPerReq: 26484.3
 BusyWorkers: 20
 IdleWorkers: 480
 Scoreboard: ......WKCR....

B<RESULT:>
 $VAR = {
 	totalAccesses => 15407604,
 	totalkBytes => 398495390,
 	cpuLoad => 0.00174067,
 	uptime => 2674832,
 	reqPerSec => 5.76021,
 	bytesPerSec => 152555,
 	bytesPerReq => 26484.3,
 	busyWorkers => 20,
 	idleWorkers => 480,
 	reading => 1,
 	writing => 1,
 	waiting => 1,
 }

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor accepts all arguments supported by
parent's L<ACME::TC::Agent::Plugin::StatCollector::Parser>
constructor.

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _parse {
  my ($self, $str) = @_;
  my $fd = $self->getDataFd($str);
  return undef unless (defined $fd);

  # parsed data
  my $data = {
    total_accesses   => 0,
    total_traffic    => 0,
    requests_sec     => 0,
    bytes_sec        => 0,
    bytes_req        => 0,
    cur_reqs         => 0,
    cur_idle_workers => 0,
    reading          => 0,
    writing          => 0,
    waiting          => 0,
  };

  # read and parse filedescriptor...
  my $i      = 0;
  my $parsed = 0;
  while ($i < MAX_LINES && (my $l = <$fd>)) {
    $i++;

    # 5 lines and nothing parsed?
    # we have wrong raw data...
    if ($parsed == 0 && $i >= 5) {
      $self->{_error} = "Nothing parsed after 5 lines of raw data.";
      return undef;
    }

    # cleanup stuff...
    $l =~ s/^\s+//g;
    $l =~ s/\s+$//g;

    if ($l =~ m/^([\w\ ]+):\s*([\d\.]+)/) {

      # do key!
      my $key = $1;
      $key =~ s/\s+//g;
      next unless (length($key) > 0);
      $key = lcfirst($key);
      $key = 'cpuLoad' if (lc($key) eq 'cpuload');

      # do value :)
      no warnings;
      my $val = $2 + 0;

      $data->{$key} = $val;
      $parsed++;
    }
    elsif ($l =~ m/^Scoreboard:/i) {
      my ($undef, $str) = split(/:/, $l);
      my @tmp = split(//, $str);
      map {
        my $c = lc($_);
        if ($c eq 'r') {

          # reading request
          $data->{reading}++;
        }
        elsif ($c eq 'w') {

          # sending reply
          $data->{writing}++;
        }
        elsif ($c eq 'k') {

          # keepalive read
          $data->{waiting}++;
        }
      } @tmp;
      $parsed++;
      last;
    }
  }

  unless ($parsed > 2) {
    $self->{_error} = "To few keys parsed from raw output.";
    return undef;
  }

  return $data;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Parser>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
