package SL::TransNumber;

use strict;

use parent qw(Rose::Object);

use Carp;
use List::MoreUtils qw(any none);
use Readonly;
use SL::DBUtils;

use Rose::Object::MakeMethods::Generic
(
 scalar => [ qw(type id number save dbh dbh_provided) ],
);

# has 'type'         => ( is => 'rw', required => 1 );
# has 'id'           => ( is => 'rw' );
# has 'number'       => ( is => 'rw' );
# has 'save'         => ( is => 'rw', default  => 1 );
# has 'dbh'          => ( is => 'rw' );
# has 'dbh_provided' => ( is => 'rw' );

Readonly my @SUPPORTED_TYPES => qw(invoice credit_note customer vendor sales_delivery_order purchase_delivery_order sales_order purchase_order sales_quotation request_quotation);

sub new {
  my $class = shift;
  my $self  = $class->SUPER::new(@_);

  croak "Invalid type " . $self->type if none { $_ eq $self->type } @SUPPORTED_TYPES;

  $self->dbh_provided($self->dbh);
  $self->dbh($::form->get_standard_dbh) if !$self->dbh;
  $self->save(1) unless defined $self->save;

  return $self;
}

sub _get_filters {
  my $self    = shift;

  my $type    = $self->type;
  my %filters = ( where => '' );

  if (any { $_ eq $type } qw(invoice credit_note)) {
    $filters{trans_number}  = "invnumber";
    $filters{numberfield}   = $type eq 'credit_note' ? "cnnumber" : "invnumber";
    $filters{table}         = "ar";

  } elsif (any { $_ eq $type } qw(customer vendor)) {
    $filters{trans_number}  = "${type}number";
    $filters{numberfield}   = "${type}number";
    $filters{table}         = $type;

  } elsif ($type =~ /_delivery_order$/) {
    $filters{trans_number}  = "donumber";
    $filters{numberfield}   = $type eq 'sales_delivery_order' ? "sdonumber" : "pdonumber";
    $filters{table}         = "delivery_orders";
    $filters{where}         = $type =~ /^sales/ ? '(customer_id IS NOT NULL)' : '(vendor_id IS NOT NULL)';

  } elsif ($type =~ /_order$/) {
    $filters{trans_number}  = "ordnumber";
    $filters{numberfield}   = $type eq 'sales_order' ? "sonumber" : "ponumber";
    $filters{table}         = "oe";
    $filters{where}         = 'NOT COALESCE(quotation, FALSE)';
    $filters{where}        .= $type =~ /^sales/ ? ' AND (customer_id IS NOT NULL)' : ' AND (vendor_id IS NOT NULL)';

  } else {
    $filters{trans_number}  = "quonumber";
    $filters{numberfield}   = $type eq 'sales_quotation' ? "sqnumber" : "rfqnumber";
    $filters{table}         = "oe";
    $filters{where}         = 'COALESCE(quotation, FALSE)';
    $filters{where}        .= $type =~ /^sales/ ? ' AND (customer_id IS NOT NULL)' : ' AND (vendor_id IS NOT NULL)';
  }

  return %filters;
}

sub is_unique {
  my $self = shift;

  return undef if !$self->number;

  my %filters = $self->_get_filters();

  my @where;
  my @values = ($self->number);

  push @where, $filters{where} if $filters{where};

  if ($self->id) {
    push @where,  qq|id <> ?|;
    push @values, conv_i($self->id);
  }

  my $where_str = @where ? join(' AND ', map { "($_)" } @where) : '';
  my $query     = <<SQL;
    SELECT $filters{trans_number}
    FROM $filters{table}
    WHERE ($filters{trans_number} = ?)
      $where_str
    LIMIT 1
SQL
  my ($existing_number) = selectfirst_array_query($main::form, $self->dbh, $query, @values);

  return $existing_number ? 0 : 1;
}

sub create_unique {
  my $self    = shift;

  my $form    = $main::form;
  my %filters = $self->_get_filters();

  do_query($form, $self->dbh, qq|LOCK TABLE defaults|);

  my $where = $filters{where} ? ' WHERE ' . $filters{where} : '';
  my $query = <<SQL;
    SELECT DISTINCT $filters{trans_number}, 1 AS in_use
    FROM $filters{table}
    $where
SQL

  my %numbers_in_use = selectall_as_map($form, $self->dbh, $query, $filters{trans_number}, 'in_use');

  my ($number)   = selectfirst_array_query($form, $self->dbh, qq|SELECT $filters{numberfield} FROM defaults|);
  $number      ||= '';

  do {
    if ($number =~ m/\d+$/) {
      my $new_number = substr($number, $-[0]) * 1 + 1;
      my $len_diff   = length($number) - $-[0] - length($new_number);
      $number        = substr($number, 0, $-[0]) . ($len_diff > 0 ? '0' x $len_diff : '') . $new_number;

    } else {
      $number = $number . '1';
    }
  } while ($numbers_in_use{$number});

  if ($self->save) {
    do_query($form, $self->dbh, qq|UPDATE defaults SET $filters{numberfield} = ?|, $number);
    $self->dbh->commit if !$self->dbh_provided;
  }

  return $number;
}

1;