package ACME::TC::Agent::Plugin::StatCollector::WebHandler;

use strict;
use warnings;

use POE;
use POSIX qw(strftime);
use HTTP::Status qw(:constants);
use POE::Component::Server::HTTPEngine::Handler;

use vars qw(@ISA);
@ISA = qw(POE::Component::Server::HTTPEngine::Handler);

our $VERSION = 0.02;

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  $self->SUPER::clearParams();

  # stat collector plugin poe session...
  $self->{poeSession} = 0;
}

sub getDescription {
  return "Statistics Collector plugin statistics module.";
}

sub processRequest {
  my ($self, $kernel, $request, $response) = @_[OBJECT, KERNEL, ARG0 .. ARG2];
  my $ok = 1;

  my $p = $kernel->call($self->{poeSession}, "getObject");

  if (defined $p && $p->isa("ACME::TC::Agent::Plugin::StatCollector")) {
    $response->code(HTTP_OK);
  }
  else {
    $response->code(HTTP_SERVICE_UNAVAILABLE);
  }
  $response->content_type("text/html; charset=utf-8");

  # add content
  $response->add_content(
    q(<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
<title>StatCollector statistics</title>
<style type="text/css">
a, a:active {text-decoration: none; color: blue;}
a:visited {color: #48468F;}
a:hover, a:focus {text-decoration: underline; color: red;}
body {background-color: #F5F5F5;}
h2 {margin-bottom: 12px;}
table {margin-left: 12px;}
tr:hover { background-color: #ACFA58; }
th, td { font: 90% monospace; text-align: left;}
th { font-weight: bold; padding-right: 14px; padding-bottom: 3px;}
td {padding-right: 14px;}
td.s, th.s {text-align: left;}
div.list { background-color: white; border-top: 1px solid #646464; border-bottom: 1px solid #646464; padding-top: 10px; padding-bottom: 14px;}
div.foot { font: 90% monospace; color: #787878; padding-top: 4px;}
</style>
</head>
<body>
<script language="javascript"> 
<!--
function flipflop(cDel) {
cKateri = eval("document.getElementById(cDel)")
if (cKateri.style.display == "none") {
 cKateri.style.display = "";
 document.cookie="sg_display_" + cDel + "=1";
}
else {
 cKateri.style.display = "none";
 document.cookie="sg_display_" + cDel + "=0";
}
}
//-->
</script> 
)
  );

  if ($ok) {

    # parser stats...
    $response->add_content(
      q(
		<h2>Parsers</h2>
<div class="list">
<table summary="parser listing" cellpadding="0" cellspacing="0">
<thead>
	<tr>
		<th class="s">Name</th>
		<th class="n">Driver</th>
		<th class="s"># parses Total</th>
		<th class="s"># parses Ok</th>
		<th class="s"># parses Err</th>
		<th class="s">Success %</th>
		<th class="s">Avg parse time Total</th>
		<th class="s">Avg parse time Ok</th>
		<th class="s">Avg parse time Err</th>
	</tr>
</thead>
<tbody>
)
    );

    # iterate trough parser objects...
    foreach my $id (sort keys %{$p->{_parser}}) {
      my $s = $p->{_parser}->{$id};
      next unless (defined $s && ref($s));

      my $stat = $s->getStatistics();
      next unless (defined $stat);

      $response->add_content("<tr>");
      $response->add_content(q(<td class="n">) . $self->htmlEncode($id) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($s->getDriver()) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numParsesTotal}) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numParsesOk}) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numParsesErr}) . q(</td>));
      $response->add_content(
        q(<td class="n">) . $self->htmlEncode(sprintf("%-.2f%%", $stat->{successRatio})) . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", $stat->{timeParsesTotalAvg} * 1000))
          . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", $stat->{timeParsesOkAvg} * 1000))
          . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", $stat->{timeParsesErrAvg} * 1000))
          . q(</td>));
      $response->add_content("</tr>\n");
    }
    $response->add_content(
      q(</tbody>
</table>
</div>)
    );

    # filter stats...
    $response->add_content(
      q(
		<h2>Filters</h2>
<div class="list">
<table summary="parser listing" cellpadding="0" cellspacing="0">
<thead>
	<tr>
		<th class="s">Name</th>
		<th class="n">Driver</th>
		<th class="s"># filterings Total</th>
		<th class="s"># filterings Ok</th>
		<th class="s"># filterings Err</th>
		<th class="s">Success %</th>
		<th class="s">Avg filtering time Total</th>
		<th class="s">Avg filtering time Ok</th>
		<th class="s">Avg filtering time Err</th>
	</tr>
</thead>
<tbody>
)
    );

    # iterate trough filter objects...
    foreach my $id (sort keys %{$p->{_filter}}) {
      my $s = $p->{_filter}->{$id};
      next unless (defined $s && ref($s));

      my $stat = $s->getStatistics();
      next unless (defined $stat);

      $response->add_content("<tr>");
      $response->add_content(q(<td class="n">) . $self->htmlEncode($id) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($s->getDriver()) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numFilteringsTotal}) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numFilteringsOk}) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numFilteringsErr}) . q(</td>));
      $response->add_content(
        q(<td class="n">) . $self->htmlEncode(sprintf("%-.2f%%", $stat->{successRatio})) . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", $stat->{timeFilteringsTotalAvg} * 1000))
          . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", $stat->{timeFilteringsOkAvg} * 1000))
          . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", $stat->{timeFilteringsErrAvg} * 1000))
          . q(</td>));
      $response->add_content("</tr>\n");
    }
    $response->add_content(
      q(</tbody>
</table>
</div>)
    );

    # storage stats...
    $response->add_content(
      q(
		<h2>Storage</h2>
<div class="list">
<table summary="Stat storage listing" cellpadding="0" cellspacing="0">
<thead>
	<tr>
		<th class="s">Id</th>
		<th class="n">Name</th>
		<th class="n">Driver</th>
		<th class="s">Num stores Total</th>
		<th class="s">Num stores Ok</th>
		<th class="s">Num stores Err</th>
		<th class="s">Success %</th>
		<th class="s">Avg Time store Total</th>
		<th class="s">Avg Time store Ok</th>
		<th class="s">Avg Time store Err</th>
		<th class="s">Stores/sec</th>
		<th class="s">Keys/sec</th>
	</tr>
</thead>
<tbody>
)
    );

    # iterate trough storage objects...
    foreach my $id (sort keys %{$p->{_storage}}) {
      my $s = $p->{_storage}->{$id};
      next unless (defined $s);

      my $stat = $s->getStatistics();
      next unless (defined $stat && ref($stat));

      $response->add_content("<tr>");
      $response->add_content(q(<td class="n">) . $self->htmlEncode($id) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($s->getName()) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($s->getDriver()) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numStoreTotal}) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numStoreOk}) . q(</td>));
      $response->add_content(q(<td class="n">) . $self->htmlEncode($stat->{numStoreErr}) . q(</td>));
      $response->add_content(
        q(<td class="n">) . $self->htmlEncode(sprintf("%-.2f%%", $stat->{successRatio})) . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", ($stat->{timeStoreTotalAvg} * 1000)))
          . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", ($stat->{timeStoreOkAvg} * 1000)))
          . q(</td>));
      $response->add_content(q(<td class="n">)
          . $self->htmlEncode(sprintf("%-.3f msec", ($stat->{timeStoreErrAvg} * 1000)))
          . q(</td>));
      $response->add_content(
        q(<td class="n">) . $self->htmlEncode(sprintf("%-.3f", $stat->{storesPerSecond})) . q(</td>));
      $response->add_content(
        q(<td class="n">) . $self->htmlEncode(sprintf("%-.3f", $stat->{keysPerSecond})) . q(</td>));
      $response->add_content("</tr>\n");
    }

    # end of table footer
    $response->add_content(
      q(</tbody>
</table>
</div>)
    );

    # collector/source stats
    # prepare data...
    my $collectors = {};

    $collectors->{_total}   = 0;
    $collectors->{_running} = 0;
    $collectors->{_paused}  = 0;
    foreach my $id (keys %{$p->{_source}}) {
      my $s = $p->{_source}->{$id};
      next unless (defined $s && ref($s));

      my $stat = $s->getStatistics();
      next unless (defined $stat && ref($stat));

      $stat->{started} = 0 unless (exists($stat->{started}) && defined $stat->{started});

      my $group = $s->getSourceGroup();
      $group = "No group" unless (defined $group && length($group) > 0);

      $collectors->{$group}->{$id}->{driver} = $s->getDriver();
      $collectors->{$group}->{$id}->{url}    = $s->getFetchUrl();


      $collectors->{$group}->{_total}   = 0 unless (exists($collectors->{$group}->{_total}));
      $collectors->{$group}->{_paused}  = 0 unless (exists($collectors->{$group}->{_paused}));
      $collectors->{$group}->{_running} = 0 unless (exists($collectors->{$group}->{_running}));

      $collectors->{$group}->{_total}++;
      $collectors->{_total}++;
      if ($s->isRunning()) {
        $collectors->{$group}->{$id}->{status} = "running";
        $collectors->{$group}->{_running}++;
        $collectors->{_running}++;
      }
      else {
        $collectors->{$group}->{$id}->{status} = "paused";
        $collectors->{$group}->{_paused}++;
        $collectors->{_paused}++;
      }

      $collectors->{$group}->{$id}->{checkInterval} = $s->getParam("checkInterval");
      $collectors->{$group}->{$id}->{started} = strftime("%Y/%m/%d %H:%M:%S", localtime($stat->{started}));
      $collectors->{$group}->{$id}->{numFetchTotal} = $stat->{numFetchTotal};
      $collectors->{$group}->{$id}->{numFetchOk}    = $stat->{numFetchOk};
      $collectors->{$group}->{$id}->{numFetchErr}   = $stat->{numFetchErr};
      $collectors->{$group}->{$id}->{timeFetchTotalAvg}
        = sprintf("%-.3f msec", ($stat->{timeFetchTotalAvg} * 1000));
      $collectors->{$group}->{$id}->{timeFetchOkAvg}
        = sprintf("%-.3f msec", ($stat->{timeFetchOkAvg} * 1000));
      $collectors->{$group}->{$id}->{timeFetchErrAvg}
        = sprintf("%-.3f msec", ($stat->{timeFetchErrAvg} * 1000));
      $collectors->{$group}->{$id}->{successRatio} = sprintf("%-.2f%%", $stat->{successRatio});
    }

    # add prepared data
    $response->add_content("<h2>Sources [");
    $response->add_content("$collectors->{_total} total, ");
    $response->add_content("<font color='green'>$collectors->{_running}</font> running, ");
    $response->add_content("<font color='red'>$collectors->{_paused}</font> paused]");
    $response->add_content("</h2>");
    my $div_id        = 0;
    my $cookie_header = $request->header("Cookie");
    foreach my $group (sort keys %{$collectors}) {
      next if ($group =~ m/^_/);
      $div_id++;

      my $sg_display = 0;
      if (defined $cookie_header) {
        if ($cookie_header =~ m/sg_display_${div_id}=1/) {
          $sg_display = 1;
        }
      }

      $response->add_content(
            "<table><tr>"
          . "<td width='600'>"
          . "<a href=\"javascript:flipflop('$div_id')\">"
          . $self->htmlEncode($group)
          . "</a></td>"
          . "<td>[$collectors->{$group}->{_total} total, <font color='green'>$collectors->{$group}->{_running} running</font>, "
          . "<font color='red'>$collectors->{$group}->{_paused} paused</font>]"
          . "</td></tr></table>"
          . "<div class=\"list\" id=\"$div_id\" style=\"display:"
          . (($sg_display) ? "" : "none") . "\">" . q(
<table summary="Stat collector source listing for group $group" cellpadding="0" cellspacing="0">
<thead>
	<tr>
		<th class="s">Id</th>
		<th class="n">Driver</th>
		<th class="s">Url</th>
		<th class="s">Status</th>
		<th class="s">Interval</th>
		<th class="s">Started</th>
		<th class="s"># fetches Total</th>
		<th class="s"># fetches Ok</th>
		<th class="s"># fetches Err</th>
		<th class="s">Success %</th>
		<th class="s">Avg time Total</th>
		<th class="s">Avg time Ok</th>
		<th class="s">Avg time Err</th>
	</tr>
</thead>
<tbody>
)
      );

      foreach my $id (sort keys %{$collectors->{$group}}) {
        my $s = $collectors->{$group}->{$id};
        next unless (defined $s && ref($s) eq 'HASH');

        # compute url and url-friendly string...
        my $url     = $s->{url};
        my $url_str = "";
        if (length($url) > 50) {
          $url_str = substr($url, 0, 50) . " ...";
        }
        else {
          $url_str = $url;
        }

        # start table row
        $response->add_content("<tr>");

        $response->add_content(q(<td class="n">) . $id . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{driver}) . q(</td>));
        $response->add_content(q(<td class="n"><a href=")
            . $self->htmlEncode($url) . q(">)
            . $self->htmlEncode($url_str)
            . q(</a></td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{status}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{checkInterval}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{started}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{numFetchTotal}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{numFetchOk}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{numFetchErr}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{successRatio}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{timeFetchTotalAvg}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{timeFetchOkAvg}) . q(</td>));
        $response->add_content(q(<td class="n">) . $self->htmlEncode($s->{timeFetchErrAvg}) . q(</td>));

        # end table row...
        $response->add_content("</tr>\n");

      }

      # end of table footer
      $response->add_content(
        q(</tbody>
	</table>
</div>)
      );
    }

  }
  else {
    $response->add_content("<h3>Error: unable to obtain StatCollector object.</h3>");
  }

  # footer
  $response->add_content(q(<hr/>));
  $response->add_content(q(<div class="foot">));
  $response->add_content($self->getServer()->getServerSignature());
  $response->add_content(q(</div>));
  $response->add_content(
    q(
</body>
</html>
</body>
</html>
	)
  );

  return $self->requestFinish();
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<POE>
L<ACME::TC::Agent>
L<ACME::TC::Agent::Plugin>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
