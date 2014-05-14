#
# This file is part of Algorithm-AM
#
# This software is copyright (c) 2013 by Royal Skousen.
#
# This is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
#
# encapsulate information about a single classification result
package Algorithm::AM::Result;
use strict;
use warnings;
use Text::Table;
# ABSTRACT: Store results of an AM classification
our $VERSION = '3.00'; # VERSION;


## TODO: variables consider exporting someday
## @itemcontextchain
## %itemcontextchainhead
## @datatocontext
## %context_to_outcome
## %contextsize
use Class::Tiny qw(
    exclude_nulls
    given_excluded
    cardinality
    test_in_data
    test_item
    count_method

    start_time
    end_time

    training_set

    scores
    high_score
    total_points
    winners
    is_tie
    result
);
use Carp 'croak';
use Algorithm::AM::BigInt 'bigcmp';

# For printing percentages in reports
my $percentage_format = '%7.3f%%';

sub config_info {
    my ($self) = @_;
    my @headers = ('Option', 'Setting');
    my @rows = (
        [ "Given context", (join ' ', @{$self->test_item->features}) .
            ', ' . $self->test_item->comment],
        [ "Nulls", ($self->{exclude_nulls} ? 'exclude' : 'include')],
        [ "Gang",  $self->{count_method}],
        [ "Test item in data", ($self->{test_in_data} ? 'yes' : 'no')],
        [ "Test item excluded", ($self->{given_excluded} ? 'yes' : 'no')],
        # [ "Total excluded items", scalar @{$self->excluded_data} +
        #     ($self->{given_excluded} ? 1 : 0)],
        [ "Number of data items", $self->training_set->size ],
        [ "Number of active variables", $self->{cardinality} ],
    );
    my @table = _make_table(\@headers, \@rows);
    my $info = join '', @table;
    return \$info;
}

# input several variables from AM's guts (grandtotal, sum,
# expected outcome integer, pointers, itemcontextchainhead and
# itemcontextchain). Calculate the prediction statistics, and
# store information needed for computing analogical sets.
# Set result to tie/correct/incorrect if expected outcome is
# provided, and set is_tie, high_score, scores, winners, and
# total_pointers.
sub _process_stats {
    my ($self, $sum, $pointers,
        $itemcontextchainhead, $itemcontextchain, $context_to_outcome,
        $gang, $active_vars, $contextsize) = @_;
    my $total_pointers = $pointers->{grandtotal};
    my $max = '';
    my @winners;
    my %scores;

    # iterate all possible outcomes and store the ones that have a
    # non-zero score. Store the high-scorers, as well.
    # 1) find which one(s) has the highest score (the prediction) and
    # 2) print out the ones with scores (probability of prediction)
    for my $outcome_index (1 .. $self->training_set->num_classes) {
        my $outcome_pointers;
        # skip outcomes with no score
        next unless $outcome_pointers = $sum->[$outcome_index];

        my $outcome = $self->training_set->_class_for_index($outcome_index);
        $scores{$outcome} = $outcome_pointers;

        # check if the outcome has the highest score, or ties for it
        do {
            my $cmp = bigcmp($outcome_pointers, $max);
            if ($cmp > 0){
                @winners = ($outcome);
                $max = $outcome_pointers;
            }elsif($cmp == 0){
                push @winners, $outcome;
            }
        };
    }

    # set result to tie/correct/incorrect after comparing
    # expected/actual outcomes. Only do this if the expected
    # class label is known.
    if(my $expected = $self->test_item->class){
        if(exists $scores{$expected} &&
                bigcmp($scores{$expected}, $max) == 0){
            if(@winners > 1){
                $self->result('tie');
            }else{
                $self->result('correct');
            }
        }else{
            $self->result('incorrect');
        }
    }
    if(@winners > 1){
        $self->is_tie(1);
    }
    $self->high_score($max);
    $self->scores(\%scores);
    $self->winners(\@winners);
    $self->total_points($total_pointers);
    $self->{pointers} = $pointers;
    $self->{itemcontextchainhead} = $itemcontextchainhead;
    $self->{itemcontextchain} = $itemcontextchain;
    $self->{context_to_outcome} = $context_to_outcome;
    $self->{gang} = $gang;
    $self->{active_vars} = $active_vars;
    $self->{contextsize} = $contextsize;
    return;
}

sub statistical_summary {
    my ($self) = @_;
    my %scores = %{$self->scores};
    my $grand_total = $self->total_points;

    # Make a table with information about predictions for different
    # outcomes. Each row contains an outcome name, the score,
    # and the percentage predicted.
    my @rows;
    for my $outcome(sort keys %scores){
        push @rows, [ $outcome, $scores{$outcome},
            sprintf($percentage_format,
                100 * $scores{$outcome} / $grand_total) ];
    }
    # add a Total row
    push @rows, [ 'Total', $grand_total ];

    my @table = _make_table(['Outcome', 'Score', 'Percentage'],
        \@rows);
    # copy the rule from the first row into the second to last row
    # to separate the Total row
    splice(@table, $#table - 1, 0, $table[0]);

    my $info = "Statistical Summary\n";
    $info .= join '', @table;
    # the predicted outcome (the one with the highest score)
    # and the result (correct/incorrect/tie).
    if ( defined (my $outcome = $self->test_item->class) ) {
        $info .= "Expected outcome: $outcome\n";
        my $result = $self->result;
        if ( $result eq 'correct') {
            $info .= "Correct outcome predicted.\n";
        }elsif($result eq 'tie'){
            $info .= "Outcome is a tie.\n";
        }else {
            $info .= "Incorrect outcome predicted.\n";
        }
    }else{
        $info .= "Expected outcome unknown\n";
    }
    return \$info;
}

sub analogical_set {
    my ($self) = @_;
    if(!exists $self->{_analogical_set}){
        $self->_calculate_analogical_set;
    }
    # make a safe copy
    my %set = %{$self->{_analogical_set}};
    return \%set;
}

sub analogical_set_summary {
    my ($self) = @_;
    my $set = $self->analogical_set;
    my $train = $self->training_set;
    my $total_pointers = $self->total_points;

    # Make a table for the analogical set. Each row contains an
    # exemplar with its outcome, spec, score, and the percentage
    # of total score contributed.
    my @rows;
    foreach my $data_index (sort keys %$set){
        my $score = $set->{$data_index};
        push @rows, [
            $train->get_item($data_index)->class,
            $train->get_item($data_index)->comment,
            $score,
            sprintf($percentage_format, 100 * $score / $total_pointers)
        ];
    }
    my @table = _make_table(
        ['Outcome', 'Exemplar', 'Score', 'Percentage'], \@rows);
    my $info = "Analogical Set\nTotal Frequency = $total_pointers\n";
    $info .= join '', @table;
    return \$info;
}

# calculate and store analogical effects in $self->{_analogical_set}
sub _calculate_analogical_set {
    my ($self) = @_;
    my %set;
    foreach my $context ( keys %{$self->{pointers}} ) {
        next unless
            exists $self->{itemcontextchainhead}->{$context};
        for (
            my $data_index = $self->{itemcontextchainhead}->{$context};
            defined $data_index;
            $data_index = $self->{itemcontextchain}->[$data_index]
        )
        {
            $set{$data_index} = $self->{pointers}->{$context};
        }
    }
    $self->{_analogical_set} = \%set;
    return;
}

sub gang_effects {
    my ($self) = @_;
    if(!$self->{_gang_effects}){
        $self->_calculate_gangs;
    }
    return $self->{_gang_effects};
}

sub gang_summary {
    my ($self, $print_list) = @_;
    my $train = $self->training_set;
    my $test_item = $self->test_item;

    my $gangs = $self->gang_effects;

    # Make a table for the gangs with these rows:
    #   Percentage
    #   Score
    #   Num
    #   Outcome
    #   Features
    #   (if $print_list is true) Data comment
    my @rows;
    # first row is a header with test item for easy reference
    push @rows, [
        'Context',
        undef,
        undef,
        undef,
        @{$test_item->features},
    ];

    # store the number of rows added for each gang
    # will help with printing later
    my @gang_rows;
    my $current_row = -1;
    # add information for each gang; sort by order of highest to
    # lowest effect
    foreach my $gang (
            sort {bigcmp($b->{score}, $a->{score})} values $gangs){
        $current_row++;
        $gang_rows[$current_row]++;
        my $variables = $gang->{vars};
        # add the gang supracontext, effect and score
        push @rows, [
            sprintf($percentage_format, 100 * $gang->{effect}),
            $gang->{score},
            undef,
            undef,
            # print undefined variable slots as asterisks
            map {$_ || '*'} @$variables
        ];
        # add each outcome in the gang, along with the total number
        # and effect of the gang items supporting it
        for my $outcome (keys %{ $gang->{outcome} }){
            $gang_rows[$current_row]++;
            push @rows, [
                sprintf($percentage_format,
                    100 * $gang->{outcome}->{$outcome}->{effect}),
                $gang->{outcome}->{$outcome}->{score},
                scalar @{ $gang->{data}->{$outcome} },
                $outcome,
                undef
            ];
            if($print_list){
                # add the list of items in the given context
                for my $data_index (@{ $gang->{data}->{$outcome} }){
                    $gang_rows[$current_row]++;
                    push @rows, [
                        undef,
                        undef,
                        undef,
                        undef,
                        @{ $train->get_item($data_index)->features },
                        $train->get_item($data_index)->comment,
                    ];
                }
            }
        }
    }

    # construct the table from the rows
    my @headers = (
        \'| ',
        'Percentage' => \' | ',
        'Score' => \' | ',
        'Num Items' => \' | ',
        'Outcome' => \' | ',
        ('' => \' ') x @{$test_item->features}
    );
    pop @headers;
    if($print_list){
        push @headers, \' | ', 'Item Comment';
    }
    push @headers, \' |';
    my @rule = qw(- +);
    my $table = Text::Table->new(@headers);
    $table->load(@rows);
    # main header
    $current_row = 0;
    my $return = $table->rule(@rule) .
        $table->title .
        $table->body($current_row) .
        $table->rule(@rule);
    $current_row++;
    # add info with a header for each gang
    for my $num (@gang_rows){
        # a row of '*' separates each gang
        $return .= $table->rule('*','*') .
            $table->body($current_row) .
            $table->rule(@rule);
        $current_row++;
        for(1 .. $num - 1){
            $return .= $table->body($current_row);
            $current_row++;
        }
    }
    $return .= $table->rule(@rule);
    return \$return;
}

sub _calculate_gangs {
    my ($self) = @_;
    my $train = $self->training_set;
    my $total_pointers = $self->total_points;
    my $raw_gang = $self->{gang};
    my $gangs = {};

    foreach my $context (keys %{$raw_gang})
    {
        my @variables = $self->_unpack_supracontext($context);
        # for now, store gangs by the supracontext printout
        my $key = join ' ', map {$_ || '-'} @variables;
        $gangs->{$key}->{score} = $raw_gang->{$context};
        $gangs->{$key}->{effect} = $raw_gang->{$context} / $total_pointers;
        $gangs->{$key}->{vars} = \@variables;

        my $p = $self->{pointers}->{$context};
        # if the supracontext is homogenous
        if ( my $outcome_index = $self->{context_to_outcome}->{$context} ) {
            # store a 'homogenous' key that indicates this, besides
            # indicating the unanimous outcome.
            my $outcome = $train->_class_for_index($outcome_index);
            $gangs->{$key}->{homogenous} = $outcome;
            my @data;
            for (
                my $i = $self->{itemcontextchainhead}->{$context};
                defined $i;
                $i = $self->{itemcontextchain}->[$i]
              )
            {
                push @data, $i;
            }
            $gangs->{$key}->{data}->{$outcome} = \@data;
            $gangs->{$key}->{size} = scalar @data;
            $gangs->{$key}->{outcome}->{$outcome}->{score} = $p;
            $gangs->{$key}->{outcome}->{$outcome}->{effect} =
                $gangs->{$key}->{effect};
        }
        # for heterogenous supracontexts we have to store data for
        # each outcome
        else {
            $gangs->{$key}->{homogenous} = 0;
            # first loop through the data and sort by outcome, also
            # finding the total gang size
            my $size = 0;
            my %data;
            for (
                my $i = $self->{itemcontextchainhead}->{$context};
                defined $i;
                $i = $self->{itemcontextchain}->[$i]
              )
            {
                push @{ $data{$train->get_item($i)->class} }, $i;
                $size++;
            }
            $gangs->{$key}->{data} = \%data;
            $gangs->{$key}->{size} = $size;

            # then store aggregate statistics for each outcome
            for my $outcome (keys %data){
                $gangs->{$key}->{outcome}->{$outcome}->{score} = $p;
                $gangs->{$key}->{outcome}->{$outcome}->{effect} =
                    # score*num_data/total
                    @{ $data{$outcome} } * $p / $total_pointers;
            }
        }
    }
    $self->{_gang_effects} = $gangs;
    return;
}

# Unpack and return the supracontext variables.
# Blank entries mean the variable may be anything, e.g.
# ('a' 'b' '') means a supracontext containing items
# wich have ('a' 'b' whatever) as variable values.
sub _unpack_supracontext {
    my ($self, $context) = @_;
    my (@variables) = @{ $self->test_item->features };
    my @context_list   = unpack "S!4", $context;
    my @alist   = @{$self->{active_vars}};
    my $j       = 1;
    foreach my $a (reverse @alist) {
        my $partial_context = pop @context_list;
        for ( ; $a ; --$a ) {
            if($self->{exclude_nulls}){
                ++$j while !defined $variables[ -$j ];
            }
            $variables[ -$j ] = '' if $partial_context & 1;
            $partial_context >>= 1;
            ++$j;
        }
    }
    return @variables;
}

# mostly by Ovid:
# http://use.perl.org/use.perl.org/_Ovid/journal/36762.html
# Return table rows with a nice header and column separators
sub _make_table {
    my ( $headers, $rows ) = @_;

    my @rule      = qw(- +);
    my @headers   = \'| ';
    push @headers => map { $_ => \' | ' } @$headers;
    pop  @headers;
    push @headers => \' |';

    unless ('ARRAY' eq ref $rows
        && 'ARRAY' eq ref $rows->[0]
        && @$headers == @{ $rows->[0] }) {
        croak(
            "make_table() rows must be an AoA with rows being same size as headers"
        );
    }
    my $table = Text::Table->new(@headers);
    $table->rule(@rule);
    $table->body_rule(@rule);
    $table->load(@$rows);

    return $table->rule(@rule),
        $table->title,
        $table->rule(@rule),
        map({ $table->body($_) } 0 .. @$rows),
        $table->rule(@rule);
}

1;

__END__

=pod

=head1 NAME

Algorithm::AM::Result - Store results of an AM classification

=head1 VERSION

version 3.00

=head2 SYNOPSIS

  use Algorithm::AM;

  my $am = Algorithm::AM->new('finnverb', -commas => 'no');
  my ($result) = $am->classify;
  print @{ $result->winners };
  print $result->statistical_summary;

=head2 DESCRIPTION

This package encapsulates all of the classification information
generated by L<Algorithm::AM/classify>, including the assigned class,
score to each class, gang effects, analogical sets,
and timing information. It also provides several methods for
generating printable reports with this information.

Note that the words 'score' and 'point' are used here to represent
whatever count is assigned by analogical modeling during
classification. This can be either pointers or occurrences. For an
explanation of this, see L<Algorithm::AM::algorithm>.

All of the scores returned by the methods here are scalars with
special PV and NV values. You should excercise caution when doing
calculations with them. See L<Algorithm::AM::BigInt> for more
information.

=head2 C<config_info>

Returns a scalar (string) ref containing information about the
configuration at the time of classification. Information from the
following accessors is included:

    exclude_nulls
    given_excluded
    cardinality
    test_in_data
    test_item
    count_method

=head2 C<statistical_summary>

Returns a scalar reference (string) containing a statistical summary
of the classification results. The summary includes all possible
predicted outcomes with their scores and percentage scores and the
total score for all outcomes. Whether the predicted outcome
is correct/incorrect/a tie of some sort is also included, if the
expected outcome has been provided.

=head2 C<analogical_set>

Returns the analogical set in the form of a hash ref mapping exemplar
indices to score contributed by the item towards
the final classification outcome. Further information about each
exemplar can be retrieved from the project object using
C<get_exemplar_(data|spec|outcome)> methods.

=head2 C<analogical_set_summary>

Returns a scalar reference (string) containing the analogical set,
meaning all items that contributed to the predicted outcome, along
with the amount contributed by each item (score and
percentage overall). Items are ordered by appearance in the data
set.

=head2 C<gang_effects>

Return a hash describing gang effects.
TODO: details, details! Maybe make a gang class to hold these.

=head2 C<gang_summary>

Returns a scalar reference (string) containing the gang effects on the
final outcome. Gang effects are basically the same as analogical sets,
but the total effects of entire subcontexts and supracontexts
are also calculated and printed.

A single boolean parameter can be provided to turn on list printing,
meaning gang items items are printed. This is false (off) by default.

=head1 CONFIGURATION INFORMATION

The following methods provide information about the configuration
of AM at the time of classification.

=head2 C<exclude_nulls>

Set to the value given by the same method of
L<Algorithm::AM|Algorithm::AM/exclude_nulls> at the time of
classification.

=head2 C<given_excluded>

Set to the value given by the same method of
L<Algorithm::AM|Algorithm::AM/exclude_nulls> at the time of
classification.

=head2 C<cardinality>

The number of features used during classification. If there
were null feature values and L</exclude_nulls> was set to true,
then this number will be lower than the cardinality of the utilized
data sets.

=head2 C<test_in_data>

True if the test item was present among the data items.

=head2 C<test_item>

Returns the L<item|Algorithm::AM::DataSet::Item> which was classified.

=head2 C<count_method>

Returns either "linear" or "squared", indicating the setting used
for computing analogical sets. See L<Algorithm::AM/linear>.

=head2 C<training_set>

Returns the L<data set|Algorithm::AM::DataSet> which was the
source of classification data.

=head1 CLASSIFICATION INFORMATION

The following methods provide information about the results of
the classification.

=head2 C<result>

If the class of the test item was known before classification, this
returns "tie", "correct", or "incorrect", depending on the outcome of
the classification. Otherwise this returns C<undef>.

=head2 C<high_score>

Returns the highest score assigned to any of the class labels.

=head2 C<scores>

Returns a hash mapping all predicted classes to their scores.

=head2 C<winners>

Returns an array ref containing the classes which had the highest
score. There is more than one only if there is a tie for the highest
score.

=head2 C<is_tie>

Returns true if more than one class was assigned the high score.

=head2 C<total_points>

The sum total number of points assigned as a score to any contexts.

=head2 C<start_time>

Returns the start time of the classification.

=head2 C<end_time>

Returns the end time of the classification.

=head1 AUTHOR

Theron Stanford <shixilun@yahoo.com>, Nathan Glenn <garfieldnate@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Royal Skousen.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
