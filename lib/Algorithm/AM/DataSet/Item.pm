#
# This file is part of Algorithm-AM
#
# This software is copyright (c) 2013 by Royal Skousen.
#
# This is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
#
package Algorithm::AM::DataSet::Item;
use strict;
use warnings;
use Carp;
our @CARP_NOT = qw(Algorithm::AM::DataSet);
use Class::Tiny qw(
    features
    class
    comment
), {
    comment => sub {
        # by default, the comment is just the data in a string, with
        # empty strings for unknown values
        join ',', @{ $_[0]->{features} }
    },
};
use Exporter::Easy (
    OK => ['new_item']
);
# ABSTRACT: A single data item for classification
our $VERSION = '3.00'; # VERSION;

sub BUILD {
    my ($self, $args) = @_;
    if(!exists $args->{features} ||
        'ARRAY' ne ref $args->{features}){
        croak q[Must provide 'features' parameter of type array ref];
    }
    return;
}

sub new_item {
    # unpack here so that warnings about odd numbers of elements are
    # reported for this function, not for the new method
    my %args = @_;
    return __PACKAGE__->new(%args);
}

sub cardinality {
    my ($self) = @_;
    return scalar @{$self->features};
}
1;

__END__

=pod

=head1 NAME

Algorithm::AM::DataSet::Item - A single data item for classification

=head1 VERSION

version 3.00

=head1 SYNOPSIS

  use Algorithm::AM::DataSet::Item 'new_item';

  my $item = new_item(
    features => ['a', 'b', 'c'],
    class => 'x',
    comment => 'a sample, meaningless item'
  );

=head1 DESCRIPTION

This class represents a single item contained in a data set. Each
item has a feature vector and possibly a class label and comment
string.

=head1 METHODS

=for Pod::Coverage BUILD

=head2 C<new>

Creates a new Item object. The only required argument is
'features', which should be an array ref containing the feature
vector. Each element of this array should be a string indicating the
value of the feature at the given index. 'class' and 'comment'
arguments are also accepted, where 'class' is the classification
label and 'comment' can be any string to be associated with the item.
A missing or undefined 'class' value is assumed to mean that the item
classification is unknown. For the feature vector, empty strings are
taken to indicate null values.

=head2 C<new_item>

This is an exportable shortcut for the new method. If exported, then
instead of calling C<<Algorithm::AM::DataSet::Item->new>>, you may
simply call C<new_item>.

=head2 C<class>

Returns the classification label for this item, or undef if the class
is unknown.

=head2 C<features>

Returns the feature vector for this item. This is an arrayref
containing the string value for each feature. An empty string
indicates that the feature value is null (meaning that it has
no value).

=head2 C<comment>

Returns the comment for this item.

=head2 C<cardinality>

Returns the length of the feature vector for this item.

=head1 AUTHOR

Theron Stanford <shixilun@yahoo.com>, Nathan Glenn <garfieldnate@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Royal Skousen.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut