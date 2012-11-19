package ACME::TC::Agent::Plugin::StatCollector::Parser::Tomcat;


use strict;
use warnings;

use XML::Parser;
use XML::Simple;

use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

our $VERSION = 0.03;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::Tomcat

Tomcat XML server-status statistics parser

=head1 DESCRIPTION

This parser parses output of tomcat's server-status output.

B<WARNING>: Data must be from similar URL: http://host.example.org:8080/manager/status?XML=true

Sample output:

 $VAR = {
    'connector.http-8080.requestInfo.bytesReceived' => '102609224',
    'connector.http-8080.requestInfo.bytesSent' => '200966345442',
    'connector.http-8080.requestInfo.errorCount' => '19461',
    'connector.http-8080.requestInfo.maxTime' => '235404',
    'connector.http-8080.requestInfo.processingTime' => '592988977',
    'connector.http-8080.requestInfo.requestCount' => '15342818',
    'connector.http-8080.threadInfo.currentThreadCount' => '0',
    'connector.http-8080.threadInfo.currentThreadsBusy' => '0',
    'connector.http-8080.threadInfo.maxThreads' => '200',
 
    'connector.jk-8009.requestInfo.bytesReceived' => '0',
    'connector.jk-8009.requestInfo.bytesSent' => '0'
    'connector.jk-8009.requestInfo.errorCount' => '0',
    'connector.jk-8009.requestInfo.maxTime' => '0',
    'connector.jk-8009.requestInfo.processingTime' => '0',
    'connector.jk-8009.requestInfo.requestCount' => '0',
    'connector.jk-8009.threadInfo.currentThreadCount' => '4',
    'connector.jk-8009.threadInfo.currentThreadsBusy' => '1',
    'connector.jk-8009.threadInfo.maxThreads' => '200',
 
    'jvm.memory.free' => '3976036040',
    'jvm.memory.max' => '6287392768',
    'jvm.memory.total' => '6287392768',
 }
=cut

##################################################
#             OBJECT CONSTRUCTOR                 #
##################################################

=head1 OBJECT CONSTRUCTOR

Object constructor doesn't accepts any additional parameters.

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _parse {
  my ($self, $str) = @_;

  # we want XML::Parser! It's really fast when XML::LibXML
  # is available
  local $XML::Simple::PREFERRED_PARSER = 'XML::Parser';

  # create parser object...
  my $parser = XML::Simple->new(ForceArray => 1);

  # try to parse
  my $dom = undef;
  eval { $dom = $parser->parse_string($str); };
  if ($@) {
    $self->{_error} = "Error parsing XML: $@";
    return undef;
  }
  elsif (!defined $dom) {
    $self->{_error} = "XML parser returned undefined structure.";
    return undef;
  }

  my $data = {};

  # connector data...
  my $has_connector = 0;
  unless (ref($dom) eq 'HASH' && exists($dom->{connector}) && ref($dom->{connector}) eq 'HASH') {
    $self->{_error} = "XML doesn't contain connector data.";
    return undef;
  }
  foreach my $conn (keys %{$dom->{connector}}) {
    for my $section ('requestInfo', 'threadInfo') {
      next unless (ref($dom->{connector}->{$conn}) eq 'HASH');
      my $s = $dom->{connector}->{$conn}->{$section};
      foreach my $k (keys %{$s->[0]}) {
        my $key = "connector.${conn}.${section}.${k}";
        $data->{$key} = $s->[0]->{$k};
        $has_connector++;
      }
    }
  }
  if ($has_connector < 8) {
    $self->{_error} = "Incomplete connector data.";
    return undef;
  }

  # jvm memory
  my $has_memory = 0;
  unless (exists($dom->{jvm}->[0]->{memory}->[0]) && ref($dom->{jvm}->[0]->{memory}->[0]) eq 'HASH') {
    $self->{_error} = "XML doesn't contain jvm/memory data.";
    return undef;
  }
  foreach my $k (keys %{$dom->{jvm}->[0]->{memory}->[0]}) {
    my $key = "jvm.memory." . $k;
    $data->{$key} = $dom->{jvm}->[0]->{memory}->[0]->{$k};
    $has_memory++;
  }
  if ($has_memory < 3) {
    $self->{_error} = "Incomplete memory data.";
    return undef;
  }

  # this is it!
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
