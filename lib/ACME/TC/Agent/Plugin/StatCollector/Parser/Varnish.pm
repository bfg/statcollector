package ACME::TC::Agent::Plugin::StatCollector::Parser::Varnish;


use strict;
use warnings;

use IO::Scalar;

use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

our $VERSION = 0.12;

use constant MAX_LINES => 100;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::Varnish

varnishstat(1) output statistics parser.

=head1 DESCRIPTION

This parser parses output of "varnishstat -1" output. Output can be obtained using Exec or
ExecSSH sources. Result structure looks like this (just an example):

B<RESULT:>
 $VAR = {
{
  'backend_busy.avg' => '0.00',
  'backend_busy.total' => '0',
  'backend_conn.avg' => '12.46',
  'backend_conn.total' => '22854846',
  'backend_fail.avg' => '0.00',
  'backend_fail.total' => '6195',
  'backend_recycle.avg' => '12.40',
  'backend_recycle.total' => '22753791',
  'backend_req.avg' => '12.46',
  'backend_req.total' => '22855072',
  'backend_reuse.avg' => '11.77',
  'backend_reuse.total' => '21585025',
  'backend_unhealthy.avg' => '0.00',
  'backend_unhealthy.total' => '0',
  'backend_unused.avg' => '0.00',
  'backend_unused.total' => '0',
  'cache_hit.avg' => '5.43',
  'cache_hit.total' => '9967428',
  'cache_hitpass.avg' => '0.00',
  'cache_hitpass.total' => '476',
  'cache_miss.avg' => '2.32',
  'cache_miss.total' => '4251028',
  'client_conn.avg' => '0.37',
  'client_conn.total' => '672738',
  'client_req.avg' => '17.89',
  'client_req.total' => '32821191',
  'esi_errors.avg' => '0.00',
  'esi_errors.total' => '0',
  'esi_parse.avg' => '0.00',
  'esi_parse.total' => '0',
  'hcb_insert.avg' => '0.00',
  'hcb_insert.total' => '0',
  'hcb_lock.avg' => '0.00',
  'hcb_lock.total' => '0',
  'hcb_nolock.avg' => '0.00',
  'hcb_nolock.total' => '0',
  'losthdr.avg' => '0.00',
  'losthdr.total' => '0',
  'n_backend.total' => '13',
  'n_bereq.total' => '110',
  'n_deathrow.total' => '0',
  'n_expired.total' => '4249369',
  'n_lru_moved.total' => '5854532',
  'n_lru_nuked.total' => '0',
  'n_lru_saved.total' => '0',
  'n_object.total' => '6651',
  'n_objecthead.total' => '14183',
  'n_objoverflow.avg' => '0.00',
  'n_objoverflow.total' => '0',
  'n_objsendfile.avg' => '0.00',
  'n_objsendfile.total' => '0',
  'n_objwrite.avg' => '17.90',
  'n_objwrite.total' => '32831102',
  'n_purge.total' => '1',
  'n_purge_add.avg' => '0.00',
  'n_purge_add.total' => '1',
  'n_purge_dups.avg' => '0.00',
  'n_purge_dups.total' => '0',
  'n_purge_obj_test.avg' => '0.00',
  'n_purge_obj_test.total' => '0',
  'n_purge_re_test.avg' => '0.00',
  'n_purge_retire.total' => '0',
  'n_sess.total' => '7',
  'n_sess_mem.total' => '147',
  'n_smf.total' => '3162',
  'n_smf_frag.total' => '45',
  'n_smf_large.total' => '79',
  'n_srcaddr.total' => '2',
  'n_srcaddr_act.total' => '1',
  'n_vbe_conn.total' => '18446744073709551601',
  'n_vcl.avg' => '0.00',
  'n_vcl.total' => '1',
  'n_vcl_avail.avg' => '0.00',
  'n_vcl_avail.total' => '1',
  'n_vcl_discard.avg' => '0.00',
  'n_vcl_discard.total' => '0',
  'n_wrk.total' => '11',
  'n_wrk_create.avg' => '0.01',
  'n_wrk_create.total' => '15851',
  'n_wrk_drop.avg' => '0.00',
  'n_wrk_drop.total' => '0',
  'n_wrk_failed.avg' => '0.00',
  'n_wrk_failed.total' => '0',
  'n_wrk_max.avg' => '0.00',
  'n_wrk_max.total' => '0',
  'n_wrk_overflow.avg' => '0.04',
  'n_wrk_overflow.total' => '68205',
  'n_wrk_queue.avg' => '0.00',
  'n_wrk_queue.total' => '0',
  's_bodybytes.avg' => '120517.06',
  's_bodybytes.total' => '221059743804',
  's_fetch.avg' => '12.46',
  's_fetch.total' => '22853835',
  's_hdrbytes.avg' => '6773.07',
  's_hdrbytes.total' => '12423569827',
  's_pass.avg' => '10.14',
  's_pass.total' => '18606308',
  's_pipe.avg' => '0.00',
  's_pipe.total' => '0',
  's_req.avg' => '17.90',
  's_req.total' => '32825389',
  's_sess.avg' => '0.37',
  's_sess.total' => '672738',
  'sess_closed.avg' => '0.01',
  'sess_closed.total' => '9680',
  'sess_herd.avg' => '17.89',
  'sess_herd.total' => '32815431',
  'sess_linger.avg' => '0.00',
  'sess_linger.total' => '0',
  'sess_pipeline.avg' => '0.00',
  'sess_pipeline.total' => '0',
  'sess_readahead.avg' => '0.00',
  'sess_readahead.total' => '0',
  'shm_cont.avg' => '0.05',
  'shm_cont.total' => '83610',
  'shm_cycles.avg' => '0.00',
  'shm_cycles.total' => '916',
  'shm_flushes.avg' => '0.11',
  'shm_flushes.total' => '204882',
  'shm_records.avg' => '1080.49',
  'shm_records.total' => '1981896686',
  'shm_writes.avg' => '52.10',
  'shm_writes.total' => '95558845',
  'sm_balloc.total' => '25694208',
  'sm_bfree.total' => '26567806976',
  'sm_nobj.total' => '3038',
  'sm_nreq.avg' => '24.93',
  'sm_nreq.total' => '45727186',
  'sma_balloc.total' => '0',
  'sma_bfree.total' => '0',
  'sma_nbytes.total' => '0',
  'sma_nobj.total' => '0',
  'sma_nreq.avg' => '0.00',
  'sma_nreq.total' => '0',
  'sms_balloc.total' => '1121600',
  'sms_bfree.total' => '1121600',
  'sms_nbytes.total' => '0',
  'sms_nobj.total' => '0',
  'sms_nreq.avg' => '0.00',
  'sms_nreq.total' => '3505',
  'uptime.total' => '1834261'
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
  my $data = {};

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

    # from varnistat(1):
    #
    #    When using the -1 option, the columns in the output are, from left to right:
    #     1.   Symbolic entry name
    #     2.   Value
    #     3.   Per-second average over process lifetime, or a period if the value can not be averaged
    #     4.   Descriptive text

    # cleanup stuff...
    $l =~ s/^\s+//g;
    $l =~ s/\s+$//g;

    my ($key, $total, $avg) = split(/\s+/, $l);
    next unless (defined $key   && length($key) > 0);
    next unless (defined $total && length($total) > 0);

    # assign the key
    $data->{$key . ".total"} = $total;

    # average values are not always available
    if ($avg ne '.' && $avg !~ m/[^\d\.]+/) {
      $data->{$key . ".avg"} = $avg;
    }

    $parsed++;
  }

  unless ($parsed > 40) {
    $self->{_error} = "To few keys parsed (only $parsed parsed) from raw output.";
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
