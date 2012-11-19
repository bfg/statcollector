package POE::Component::Server::HTTPEngine::Handler::ContextList;


use strict;
use warnings;

use POE;
use HTTP::Status qw(:constants);
use POE::Component::Server::HTTPEngine::Handler;

# inherit everything from base class
use base 'POE::Component::Server::HTTPEngine::Handler';

BEGIN {

  # check if our server is in debug mode...
  no strict;
  POE::Component::Server::HTTPEngine->import;
  use constant DEBUG => POE::Component::Server::HTTPEngine::DEBUG;
}

our $VERSION = 0.02;

my $_log = undef;

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

  # logging object
  if (DEBUG && !defined $_log) {
    $_log = Log::Log4perl->get_logger(__PACKAGE__);
  }

  bless($self, $class);
  $self->clearParams();
  $self->setParams(@_);
  return $self;
}

##################################################
#                PUBLIC METHODS                  #
##################################################

sub getDescription {
  return "Server context listing module.";
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0, ARG1];
  my $server  = $self->getServer();
  my $srv_sig = $server->getServerSignature();
  $response->code(HTTP_OK);
  $response->header('Content-Type', 'text/html');
  $response->add_content(<<END_HEADER);
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
<title>Server context listing</title>
<style type="text/css">
a, a:active {text-decoration: none; color: blue;}
a:visited {color: #48468F;}
a:hover, a:focus {text-decoration: underline; color: red;}
body {background-color: #F5F5F5;}
h2 {margin-bottom: 12px;}
table {margin-left: 12px;}
th, td { font: 90% monospace; text-align: left;}
th { font-weight: bold; padding-right: 14px; padding-bottom: 3px;}
td {padding-right: 14px;}
td.s, th.s {text-align: left;}
div.list { background-color: white; border-top: 1px solid #646464; border-bottom: 1px solid #646464; padding-top: 10px; padding-bottom: 14px;}
div.foot { font: 90% monospace; color: #787878; padding-top: 4px;}
</style>
</head>
<body>
<h2>Mounted contexts</h2>
<div class="list">
<table summary="Server context listing" cellpadding="0" cellspacing="0">
<thead>
	<tr>
		<th class="n">Context</th>
		<th class="s">Handler</th>
		<th class="s">Version</th>
		<th class="s">Description</th>
	</tr>
</thead>
<tbody>
END_HEADER

  # generate html table
  foreach (sort keys %{$server->{_ctx}->{default}}) {
    next unless (defined $_);
    my $handler = $server->{_ctx}->{default}->{$_}->{handler};
    my $class   = $server->{_ctx}->{default}->{$_}->{class};
    next unless (defined $class);
    $response->add_content("\t<tr>\n" . "\t\t"
        . '<td class="n"><a href="'
        . $_ . '">'
        . $_
        . "</a></td>\n" . "\t\t"
        . '<td class="m">'
        . $class
        . "</td>\n" . "\t\t"
        . '<td class="m">'
        . sprintf("%-.2f", $class->VERSION())
        . "</td>\n" . "\t\t"
        . '<td class="s">'
        . $class->getDescription()
        . "</td>\n"
        . "\t</tr>\n");
  }

  # add footer...
  $response->add_content(<<END_FOOTER);
</tbody>
</table>
</div>
<div class="foot">$srv_sig</div>
</body>
</html>
END_FOOTER
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO
L<HTTP::Request>
L<HTTP::Response>
L<POE::Component::Server::HTTPEngine::Handler>
L<POE::Component::Server::HTTPEngine::Response>

=cut

1;
