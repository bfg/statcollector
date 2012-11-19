package ACME::TC::Agent::Plugin::StatCollector::Parser::ArsoXML;


use strict;
use warnings;

use XML::Parser;
use XML::Simple;

use ACME::TC::Agent::Plugin::StatCollector::Parser;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser);

our $VERSION = 0.02;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::ArsoXML

Republic of Slovenia's enviromental agency wheater data parser.

=head1 DESCRIPTION

This parser can be used to graph wheater data for several places in Slovenia.

=head1 USAGE:

Create HTTP source and point it to valid ARSO xml service URL:

ARSO list of exported data: L<http://meteo.arso.gov.si/met/sl/service/>

ARSO XML service docs: L<http://www.meteo.si/uploads/meteo/help/sl/xml_service.html>

Sample URL (Ljubljana, Bezigrad): L<http://meteo.arso.gov.si/uploads/probase/www/observ/surface/text/sl/observation_LJUBL-ANA_BEZIGRAD_latest.xml>

This parser parses output of tomcat's server-status output.

=head1 RETURNED DATA

Sample output:

 $VAR = {         
  'nn_icon-wwsyn_icon' => 'mostClear', 
  'tsUpdated_day' => 'Ponedeljek CET', 
  'domain_lon' => '14.5172',           
  'domain_longTitle' => 'Ljubljana',   
  'wwsyn_icon' => {},                  
  'valid' => '15.03.2010 20:00 CET',   
  't_var_unit' => "\x{b0}C",           
  'ff_unit' => 'm/s',
  'nn_icon' => 'mostClear',
  'td_degreesC' => {},
  'rh' => {},
  'tsValid_issued_RFC822' => '15 Mar 2010 19:00:00 +0000',
  'nn_shortText' => "prete\x{17e}no jasno",
  'vis_value' => '30',
  'domain_meteosiId' => 'LJUBL-ANA_BEZIGRAD_',
  'domain_parentId' => 'SI_OSREDNJESLOVENSKA_',
  'tsValid_issued_UTC' => '15.03.2010 19:00 UTC',
  'vis_unit' => 'km',
  'dd_icon' => 'ENE',
  'title' => 'AAXX',
  'msl' => {},
  'tsUpdated_UTC' => '15.03.2010 19:13 UTC',
  'tsValid_issued' => '15.03.2010 20:00 CET',
  't_var_desc' => 'Temperatura',
  'valid_day' => 'Ponedeljek CET',
  'ff_val' => '1',
  'msl_mb' => {},
  'sunset' => {},
  'td_var_desc' => "Temperatura rosi\x{161}\x{10d}a",
  'ffmax_val' => {},
  'domain_title' => 'LJUBLJANA/BEZIGRAD',
  'ffmax_unit' => 'm/s',
  'rh_var_unit' => '%',
  'tsUpdated' => '15.03.2010 20:13 CET',
  'dd_longText' => 'vzhodno-severovzhodni veter',
  'domain_lat' => '46.0658',
  'tsValid_issued_day' => 'Ponedeljek CET',
  'ddff_icon' => {},
  'ff_minimum' => '0',
  'domain_countryIsoCode2' => 'SI',
  'sunrise' => {},
  't' => '4',
  'dd_shortText' => 'VSV',
  'ff_maximum' => '2',
  'wwsyn_shortText' => {},
  'dd_decodeText' => 'ENE',
  'td' => {},
  'valid_UTC' => '15.03.2010 19:00 UTC',
  'dd_var_desc' => 'Smer vetra',
  'msl_var_unit' => 'hPa',
  'ff_value' => '1',
  'rh_var_desc' => 'Vlaga',
  'tsUpdated_RFC822' => '15 Mar 2010 19:13:00 +0000',
  'td_var_unit' => "\x{b0}C",
  'domain_altitude' => '299',
  'pa_shortText' => {},
  'windchill' => {},
  'dd_var_unit' => {},
  't_degreesC' => '4',
  'nn_decodeText' => '1/8 .. 2/8',
  'wwsyn_longText' => {},
  'note' => '14015 42980 20701 10042 82031',
  'ff_icon' => {},
  'msl_var_desc' => 'Pritisk',
  'domain_shortTitle' => "LJUBLJANA - BE\x{17d}IGRAD"
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
  my $parser = XML::Simple->new(

    # ForceArray => 1,
  );

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

  unless (exists($dom->{metData})) {
    $self->{_error} = "XML doesn't contain <metData> element.";
    return undef;
  }

  # copy meteo data...
  my $data = {};
  %{$data} = %{$dom->{metData}};

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
