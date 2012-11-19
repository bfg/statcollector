package ACME::TC::Agent::Plugin::StatCollector::Filter::Simple;


use strict;
use warnings;

use ACME::TC::Agent::Plugin::StatCollector::Filter;
use vars qw(@ISA);

@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::Filter);

our $VERSION = 0.02;

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::Filter::Simple

Simple statistics filter; can be used to rename statistics keys. This is B<content-only> filter.

=head1 OBJECT CONSTRUCTOR

Constructor accepts all arguments of L<ACME::TC::Agent::StatCollector::Filter> and the following ones:

=over

=item B<prefix> (string, ""):

Every key is prefixed by specified prefix string.

B<NOTE>: prefix can contain B<%{name}> magic cookies. B<name>
is replaced with data key B<name>. There are also special cookies:

B<%{HOSTNAME}>: replaced by fetch hostname

B<%{PORT}>: replaced by fetch port number if it can be determined.

=item B<suffix> (string, ""):

Every key is suffixed by specified suffix string.

B<NOTE>: suffix can contain B<%{name}> magic cookies. B<name>
is replaced with data key B<name>. There are also special cookies:

B<%{HOSTNAME}>: replaced by fetch hostname

B<%{PORT}>: replaced by fetch port number if it can be determined.

=back

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

sub clearParams {
  my ($self) = @_;
  return 0 unless ($self->SUPER::clearParams());

  $self->{prefix} = "";
  $self->{suffix} = "";
  return 1;
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _filterContent {
  my ($self, $data, $obj) = @_;

  my $prefix = $self->{prefix};
  $prefix =~ s/%{([^}]+)}/$self->_getValue($1, $data, $obj)/gem;
  my $suffix = $self->{suffix};
  $suffix =~ s/%{([^}]+)}/$self->_getValue($1, $data, $obj)/gem;

  # iterate trough keys...
  map {
    my $k = $prefix . $_ . $suffix;
    my $v = $data->{$_};

    # remove old key
    delete($data->{$_});

    # install new one :)
    $data->{$k} = $v;
  } keys %{$data};

  return $data;
}

sub _getValue {
  my ($self, $key, $data, $obj) = @_;
  if ($key eq 'HOSTNAME') {
    return $obj->getHost() if (defined $obj);
    return '';
  }
  elsif ($key eq 'PORT') {
    return $obj->getPort() if (defined $obj);
    return 0;
  }

  if (exists($data->{$key}) && defined $data->{$key}) {
    return $data->{$key};
  }

  return '';
}

=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::Filter>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
