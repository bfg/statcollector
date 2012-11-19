package ACME::TC::Agent::Plugin::StatCollector::ParsedData;


use strict;
use warnings;

use bytes;
use Scalar::Util qw(blessed);

use ACME::TC::Agent::Plugin::StatCollector::RawData;

use vars qw(@ISA);
@ISA = qw(ACME::TC::Agent::Plugin::StatCollector::RawData);

our $VERSION = 0.01;
our $Error   = "";

=head1 NAME ACME::TC::Agent::Plugin::StatCollector::ParsedData

Parsed data container for single ACME::TC::Agent::Plugin::StatCollector::Source
fetch.

=head1 SYNOPSIS
 
 # create raw data harness object...
 my $data = ACME::TC::Agent::Plugin::StatCollector::ParsedData->new();
 
 my $parsed_data = {
 	key => "value",
 	key2 => "value",
 };

 # add content and other data...
 $data->setContent($parsed_data);
 $data->setFetchStartTime($time_fetch_started);
 $data->setFetchDoneTime($time_fetch_done);
 $data->setUrl($fetch_url);
 $data->setId($fetch_id);
 $data->setDriver($fetch_driver);
 $data->setParser($parser_name);
 
 # add custom key
 $data->setKey('someKeyName', 10);
 
 # post parsed data object to stat collector
 # to store it in it's storage backends...
 unless ($_[KERNEL]->post($stat_collector_session, "storeData", $data)) {
 	$_log->error("Error posting data to StatCollector POE session id $stat_collector_session: $!");
 }

=head1 DESCRIPTION

This class stores parsed data as key => value pairs. It inherits all methods
from L<ACME::TC::Agent::Plugin::StatCollector::RawData> class.

See L<ACME::TC::Agent::Plugin::StatCollector::RawData> for description
of all supported method and further details.

=cut

##################################################
#                PUBLIC METHODS                  #
##################################################

=head1 METHODS

=head2 newFromRaw ($raw_data_obj)

Construct new ParsedData object, just like new(), but takes RawData object as an reference
and copies id, driver, timing stuff to new ParsedData object and returns it, B<without> setting
content. You'll basically get ParsedData object which holds the same data as your RawData object,
but without rawcontent - You just need to set content and you'll have valid object, ready for storage.

Returns initialized object on success, otherwise undef.

B<EXAMPLE>:

 sub got_raw {
 	my ($self, $raw) = @_;
 	my $parsed_data_obj = ACME::TC::Agent::Plugin::StatCollector::ParsedData->newFromRaw($raw);
 	unless (defined $parsed_data_obj) {
 		die "Error: ", "ACME::TC::Agent::Plugin::StatCollector::ParsedData->getError(); 
 	}
 	
 	my $parsed_content = $parser_object->parse($raw->getContent());
 
 	$parsed_data_obj->setContent($parsed_content);
 
 	$storage->store($parsed_data_obj);
 }

=cut

sub newFromRaw {
  shift if (ref($_[0]) eq '' && $_[0] eq __PACKAGE__);
  my $self = undef;
  $self = shift if (ref($_[0]) && blessed($_[0]) && $_[0]->isa(__PACKAGE__));
  my $raw = shift;
  unless (defined $raw && blessed($raw) && $raw->isa("ACME::TC::Agent::Plugin::StatCollector::RawData")) {
    my $err = "Invalid raw data object.";
    if (blessed $self) {
      $self->{_error} = $err;
    }
    else {
      $Error = $err;
    }
    return undef;
  }

  # check validity of an raw object...
  unless ($raw->isValid()) {
    my $err = "Invalid raw object: " . $raw->getError();
    if (blessed $self) {
      $self->{_error} = $err;
    }
    else {
      $Error = $err;
    }
    return undef;
  }

  my $obj = __PACKAGE__->new();

  # copy everything except real content...
  $obj->_setMetaData($raw->_getMetaData());

  # return the object...
  return $obj;
}

=head2 getContent ()

Returns parsed content as hash reference containing key => value pairs.

=cut

sub getContent {
  my ($self) = @_;
  unless (defined $self->{_content}) {
    $self->{_error} = "Undefined content.";
    return undef;
  }

  # copy content structure
  my $data = {};
  %{$data} = %{$self->{_content}};

  return $data;
}

=head2 setContent ($data)

Sets parsed content from anonymous hash reference. Returns 1 on success, otherwise 0. 

B<EXAMPLE:>
 my $data = {
 	key => "value",
 	key2 => "value2",	
 };
 $obj->setContent($data);

=cut

sub setContent {
  my ($self, $data) = @_;
  unless (defined $data) {
    $self->{_error} = "Undefined content.";
    return 0;
  }
  unless (ref($data) && ref($data) eq 'HASH') {
    $self->{_error} = "Invalid content data: Argument is not a hash reference.";
    return 0;
  }

  # copy data
  %{$self->{_content}} = %{$data};

  return 1;
}

=head2 getKey ($name)

Returns stored data key identified by $name on success, otherwise undef.

=cut

sub getKey {
  my ($self, $name) = @_;
  return undef unless (exists($self->{_content}->{$name}));
  return $self->{_content}->{$name};
}

=head2 setKey ($name, $value)

Sets data key. Returns 1 on success, otherwise 0.

=cut

sub setKey {
  my ($self, $name, $val) = @_;
  return 0 unless (defined $name && defined $val);
  $self->{_content}->{$name} = $val;
  return 1;
}

=head2 resetData ()

Removes B<ALL> statistics keys from stored data.

=cut

sub resetData {
  my ($self) = @_;
  $self->{_content} = {};
}

sub size {
  my ($self) = @_;
  return 0 unless (defined $self->{_content});
  my $sum = 0;
  foreach (keys %{$self->{_content}}) {
    $sum += length($_);
    $sum += length($self->{_content}->{$_});
  }

  return $sum;
}

=head2 numKeys ()

Returns number of keys.

=cut

sub numKeys {
  my ($self) = @_;
  return 0 unless (defined $self->{_content});
  return scalar(keys %{$self->{_content}});
}

=head2 getDeferCount ()

Returns number of failed storage requests for this object.

=cut

sub getDeferCount {
  my ($self) = @_;
  return $self->{_deferCount};
}

=head2 incDeferCount ()

Increments internal count of failed storage requests for this object.
Returns number of failed storage requests.

=cut

sub incDeferCount {
  my $self = shift;
  $self->{_deferCount}++;
  return $self->{_deferCount};
}

##################################################
#               PRIVATE METHODS                  #
##################################################

sub _init {
  my $self = shift;
  $self->{_deferCount} = 0;
}


=head1 AUTHOR

Brane F. Gracnar

=head1 SEE ALSO

L<ACME::TC::Agent::Plugin::StatCollector::RawData>

=cut

1;

# vim:shiftwidth=2 softtabstop=2 expandtab
# EOF
