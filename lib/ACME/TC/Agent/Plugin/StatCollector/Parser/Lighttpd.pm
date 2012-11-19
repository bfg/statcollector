package ACME::TC::Agent::Plugin::StatCollector::Parser::Lighttpd;


use strict;
use warnings;

use ACME::TC::Agent::Plugin::StatCollector::Parser::Apache;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Parser::Apache);

our $VERSION = 0.10;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Parser::Lighttpd

Lighttpd server-status statistics parser.

=head1 DESCRIPTION

This is just subclassed Apache's server-status parser. See
L<ACME::TC::Agent::Plugin::StatCollector::Parser::Apache> for
more info.

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Parser::Apache>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
