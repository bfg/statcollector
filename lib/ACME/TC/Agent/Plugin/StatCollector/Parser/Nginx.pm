package ACME::TC::Agent::Plugin::StatCollector::Parser::Nginx;


use strict;
use warnings;

use IO::Scalar;

use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

use constant MAX_LINES => 100;

our $VERSION = 0.01;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::Nginx

Nginx server-status statistics parser

=head1 DESCRIPTION

This parser parses output of nginx's server-status output.

B<SOURCE:>
 Active connections: 133 
 server accepts handled requests
  2169310 2169310 3205505 
 Reading: 10 Writing: 66 Waiting: 57 

B<RESULT:>
 $VAR = {
    connections => 133,
    accepts => 2169310,
    handled => 2169310,
    requests => 3205505,
    reading => 10,
    writing => 66,
    waiting => 57,
 }

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor doesn't accept any additional parameters.

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
  my $data
    = {connections => 0, accepts => 0, handled => 0, requests => 0, reading => 0, writing => 0, waiting => 0,
    };

  # read and parse filedescriptor...
  my $i              = 0;
  my $server_accepts = 0;
  my $parsed         = 0;
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

    # skip empty lines
    next unless (length($l) > 0);

    if ($l =~ m/^Active connections:\s*(\d+)/i) {
      $data->{connections} = $1;
      $parsed++;
    }
    elsif ($l =~ m/^server\s+accepts/i) {
      $server_accepts = 1;
      $parsed++;
    }
    elsif ($server_accepts) {
      my ($accepts, $handled, $requests) = split(/\s+/, $l);
      $data->{accepts}  = $accepts;
      $data->{handled}  = $handled;
      $data->{requests} = $requests;
      $server_accepts   = 0;
      $parsed += 3;
    }
    elsif ($l =~ m/^Reading:\s*(\d+)\s*Writing:\s*(\d+)\s*Waiting:\s*(\d+)/i) {
      $data->{reading} = $1;
      $data->{writing} = $2;
      $data->{waiting} = $3;

      $parsed += 3;

      # this is last one...
      last;
    }
  }

  unless ($parsed > 6) {
    $self->{_error} = "Incomplete Nginx server-status data; only $i keys parsed.";
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
