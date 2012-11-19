package ACME::TC::Agent::Plugin::StatCollector::Parser::Haproxy;


use strict;
use warnings;

use Log::Log4perl;
use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

our $VERSION = 0.10;

# logging object
# my $_log = Log::Log4perl->get_logger(__PACKAGE__);

# For field explanation, see:
#
# http://code.google.com/p/haproxy-docs/wiki/StatisticsMonitoring#CSV_format
#

# haproxy CSV stats item order...
my @_order = qw(
  pxname svname qcur qmax scur smax slim stot bin bout dreq dresp ereq
  econ eresp wretr wredis status weight act bck chkfail chkdown lastchg
  downtime qlimit pid iid sid throttle lbtot tracked type rate rate_lim
  rate_max check_status check_code check_duration hrsp_1xx hrsp_2xx hrsp_3xx
  hrsp_4xx hrsp_5xx hrsp_other hanafail req_rate req_rate_max req_tot cli_abrt srv_abrt
);

# items that really matter...
my @_items = qw(
  qcur qmax scur smax stot
  bin bout
  req_rate_max req_tot
  hrsp_1xx hrsp_2xx hrsp_3xx hrsp_4xx hrsp_5xx hrsp_other
  req_rate req_tot cli_abrt srv_abrt
);

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::Haproxy

Parses L<HAProxy|http://haproxy.wt1.eu/> statistics (CSV style) interface output

Parser initialization

 my %opt = (
 );
 
 my $parsed = ACME::TC::Agent::Plugin::StatCollector::Parser->factory(
 	"Haproxy",
 );

=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor doesn't accept any arguments.

=over

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _parse {
  my ($self, $str) = @_;

  # get tree structure
  my $tree = $self->_parseHaproxy($str);
  return undef unless (defined $tree);

  # todo: flatten tree structure
  return $self->_hashFlattenZbx($tree);

  return $tree;
}

sub _parseHaproxy {
  my ($self, $str) = @_;
  unless (defined $str && ref($str) eq 'SCALAR') {
    $self->{_error} = "Data argument must be scalar reference.";
    return undef;
  }

  # result structure
  my $res = {};

  my $last_fe = undef;
  my $last_be = undef;


  # split into line chunks and reverse order
  #
  # it's easier to parse haproxy stats output
  # in reverse order
  foreach (reverse(split(/[\r\n]+/, $$str))) {
    $_ =~ s/^\s+//g;
    $_ =~ s/\s+$//g;
    next if ($_ =~ m/^#/);
    next unless (length $_ > 0);

    #print "Line: $_\n";

    # split line
    my @tmp = split(/\s*,\s*/, $_);

    # build hash...
    my $tdata = {};
    map {
      my $i = shift(@tmp);
      $tdata->{$_} = lc($i) if (defined $i && length($i) > 0);
    } @_order;

    # svname and pxname must be defined
    my $svname = delete($tdata->{svname});
    my $pxname = delete($tdata->{pxname});
    next unless (defined $svname && length($svname) > 0);
    next unless (defined $pxname && length($pxname) > 0);

    my $is_backend_member = 0;

    if ($svname eq 'backend') {
      $last_fe = undef;
      $last_be = $pxname;
    }
    elsif ($svname eq 'frontend') {
      $last_fe = $pxname;
    }
    else {
      $is_backend_member = 1;
      %{$res->{backend}->{$last_be}->{nodes}->{$svname}} = %{$tdata};
    }

    unless ($is_backend_member) {
      %{$res->{$svname}->{$pxname}->{total}} = %{$tdata};
    }
  }

  return $res;
}

sub _hashFlattenZbx {
  my ($self, $tree) = @_;
  unless (defined $tree && ref($tree) eq 'HASH') {
    $self->{_error} = "Invalid haproxy stats tree structure.";
    return undef;
  }

  my $res = {};

  # types (backend, frontend)
  foreach my $type (keys %{$tree}) {
    my $d = $tree->{$type};
    print "TYPE: $type\n";

    my $totals = {};

    # proxy names
    foreach my $name (keys %{$d}) {
      my $e = $d->{$name};

      # totals...
      foreach my $item (keys %{$e->{total}}) {
        next unless (grep { $_ eq $item } @_items);
        my $k = 'haproxy.' . $type;
        $k .= "\[total,$name,$item\]";
        $res->{$k} = $e->{total}->{$item};

        # increase totals...
        $totals->{$item} += $e->{total}->{$item};
      }

      # nodes
      foreach my $node (keys %{$e->{nodes}}) {
        foreach my $item (keys %{$e->{total}}) {
          next unless (grep { $_ eq $item } @_items);
          my $k = 'haproxy.' . $type;
          $k .= "\[$name,$node,$item\]";
          $res->{$k} = $e->{total}->{$item};
        }
      }
    }

    # add totals
    foreach (keys %{$totals}) {
      my $k = 'haproxy.' . $type . '.' . $_ . '[total]';
      $res->{$k} = $totals->{$_};
    }
  }

  return $res;
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Parser>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
