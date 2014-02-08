#
# This file is part of Algorithm-AM
#
# This software is copyright (c) 2013 by Royal Skousen.
#
# This is free software; you can redistribute it and/or modify it under
# the same terms as the Perl 5 programming language system itself.
#
package Algorithm::AM;
use strict;
use warnings;
# ABSTRACT: Perl extension for Analogical Modeling using a parallel algorithm
our $VERSION = '2.36'; # TRIAL VERSION;
use feature 'state';
use Path::Tiny;
use Exporter::Easy (
    OK => ['bigcmp']
);
use Carp;
our @CARP_NOT = qw(Algorithm::AM);
use IO::Handle;
use Data::Dumper;
use Algorithm::AM::Project;

require XSLoader;
XSLoader::load();

use Log::Dispatch;
use Log::Dispatch::File;
my $logger = Log::Dispatch->new(
    outputs => [
        [ 'Screen', min_level => 'info', newline => 1 ],
    ],
);

my $subsource;
{
    local $/;
    $subsource = <DATA>;
}
$subsource =~ s/__END__.*//s;

my %import;

## TODO: variables to be exported some day
## @itemcontextchain
## @datatocontext
## %itemcontextchainhead
## %subtooutcome
## %contextsize
## %pointers
## %gang

sub new {
    my ($proto, $project_path, %opts) = @_;

    #TODO: what is the purpose of these two statements?
    my $class = ref($proto) || $proto;
    #TODO: this is not a legal path anyway...
    $project_path = ''
        if $proto =~ /^-/;

    if(!$project_path){
        croak 'Must specify project';
    }

    # all of the options except commas are for the Project object,
    # but creating the Project first could use a lot of time, and
    # incorrect classification options is a fatal error. So put this
    # aside for the Project constructor.
    my $commas = $opts{commas};
    delete $opts{commas};

    my $opts = _check_classify_opts(
        #classification defaults
        exclude_nulls     => 1,
        exclude_given    => 1,
        linear      => 0,
        probability => undef,
        repeat      => 1,
        skipset     => 1,
        gangs       => 'no',
        %opts
    );
    my $self = bless $opts, $class;

    $logger->info("Initializing project $project_path");

    # read project files
    my $project = Algorithm::AM::Project->new(
        $project_path, commas => $commas);
    # TODO: these lines are necessary for now because each of these variables
    # is assumed to be provided to the hook methods through $self. Once we
    # have data objects, and we can provide proper accessors (and remove
    # the need for outcometonum, outcomelist, and outcome).
    $self->{outcometonum} = $project->_outcome_to_num;
    $self->{outcomelist} = $project->_outcome_list;
    $self->{outcome} = $project->_outcomes;
    $self->{spec} = $project->_specs;
    $self->{data} = $project->_data;

    $self->{project} = $project;

    # compute activeVars here so that lattice space can be allocated in the
    # _initialize method
    $self->{activeVars} = _compute_lattice_sizes($project->num_variables);

    # sum is intitialized to a list of zeros the same length as outcomelist
    @{$self->{sum}} = (0.0) x ($project->num_outcomes + 1);

    # preemptively allocate memory
    @{$self->{itemcontextchain}} = (0) x $project->num_exemplars;
    @{$self->{datatocontext}} = ( pack "S!4", 0, 0, 0, 0 ) x $project->num_exemplars;

    $self->{$_} = {} for (
        qw(
            itemcontextchainhead
            subtooutcome
            contextsize
            pointers
            gang
        )
    );

    $self->{_classify_sub} = _create_classify_sub()
        or die "didn't work out";
    # calls XS code
    $self->_initialize(
        $self->{activeVars},
        $project->_outcomes,
        $self->{itemcontextchain},
        $self->{itemcontextchainhead},
        $self->{subtooutcome},
        $self->{contextsize},
        $self->{pointers},
        $self->{gang},
        $self->{sum}
    );
    return $self;
}

sub classify {
    my ($self, @args) = @_;
    return $self->{_classify_sub}->($self, @args);
}

sub _check_classify_opts {
    my %opts = @_;

    state $valid_args =
    [qw(
        exclude_nulls
        exclude_given
        linear
        probability
        repeat
        skipset
        gangs

        beginhook
        beginrepeathook
        begintesthook
        datahook
        endtesthook
        endrepeathook
        endhook
    )];

    for my $option (keys %opts){
        if(!grep {$_ eq $option} @$valid_args){
            croak "Unknown option $option";
        }
    }

    # TODO: should change into two separate booleans;
    # print_gangs, and print_gang_summaries (or something)
    if ( $opts{gangs} && $opts{gangs} !~ /^(?:yes|summary|no)$/ ) {
        carp "Failed to specify option 'gangs' correctly";
        $logger->warn(q{(must be 'yes', 'summary', or 'no')});
        $logger->warn(q{Will use default value of 'no'});
        $opts{gangs} = 'no';
    }

    #todo: properly check types of parameters; hooks should be subs, etc.

    return \%opts;
}

# since we split the lattice in four, we have to decide which variables
# go where. Given the number of variables being used, return an arrayref
# containing the number of variables to be used in each of the the four
# lattices.
sub _compute_lattice_sizes {
    my ($num_feats) = @_;

    use integer;
    my @active_vars;
    my $half = $num_feats / 2;
    $active_vars[0] = $half / 2;
    $active_vars[1] = $half - $active_vars[0];
    $half         = $num_feats - $half;
    $active_vars[2] = $half / 2;
    $active_vars[3] = $half - $active_vars[2];
    return \@active_vars;
}

#create the classification subroutine
sub _create_classify_sub {
    return sub {
        my $self = shift;

        # don't buffer messages; remember the caller's autoflush setting
        my $autoflush = *STDOUT->autoflush(1);

        #check all input parameters and then save them in $self
        my $opts = _check_classify_opts(@_);
        for my $opt_name(keys $opts){
            $self->{$opt_name} = $opts->{$opt_name};
        }

        my $project = $self->{project};

        # TODO: neat/ugly hack starts here...
        local $_ = $subsource;
        if(!$self->{exclude_nulls}){
            s/## begin exclude nulls.*?## end exclude nulls//sg;
        }

        if ( $self->{exclude_given} ) {
            s/## begin include given.*?## end include given//sg;
        }
        else {
            s/## begin exclude given.*?## end exclude given//sg;
        }

        if ( $self->{linear} ) {
            s/_fillandcount\(X\)/_fillandcount(0)/;
        }
        else {
            s/_fillandcount\(X\)/_fillandcount(1)/;
        }

        if ( not defined $self->{probability} ) {
            s/## begin probability.*?## end probability//sg;
        }

        if ( $self->{skipset} ) {
            s/## begin analogical set.*?## end analogical set//sg;
        }

        if ( $self->{gangs} ne 'yes' ) {
            if ( $self->{gangs} eq 'summary' ) {
                s/## begin skip gang list.*?## end skip gang list//sg;
            }
            else {
                s/## begin gang.*?## end gang//sg;
            }
        }

        if (!exists $self->{beginhook} ) {
            s/\$self->{beginhook}->.*//;
        }
        if (!exists $self->{begintesthook} ) {
            s/\$self->{begintesthook}->.*//;
        }
        if (!exists $self->{beginrepeathook} ) {
            s/\$self->{beginrepeathook}->.*//;
        }
        if (!exists $self->{datahook} ) {
            s/next unless \$self->{datahook}->\([^)]+\)//;
        }
        if (!exists $self->{endrepeathook} ) {
            s/\$self->{endrepeathook}->.*//;
        }
        if (!exists $self->{endtesthook} ) {
            s/\$self->{endtesthook}->.*//;
        }
        if (!exists $self->{endhook} ) {
            s/\$self->{endhook}->.*//;
        }

## stuff to be exported
        my ($curTestOutcome);
        my $data;
        my $pass;
        my $grandtotal;

        #beginning vars
        $data->{datacap} = $project->num_exemplars;

        #item vars
        #TODO: stop using scalar pointers here. Should
        #have some sort of an CurrentIteration object instead.
        $data->{curTestOutcome} = \$curTestOutcome;

        #iter vars
        $data->{pass} = \$pass;

        #end vars
        $data->{pointertotal} = \$grandtotal;

        eval $_; ## no critic (ProhibitStringyEval)
        $logger->warn($@)
          if $@;

        # return autoflush setting to what the caller was using
        *STDOUT->autoflush($autoflush);
    };
}

sub bigcmp {
    my($a,$b) = @_;
    return (length($a) <=> length($b)) || ($a cmp $b);
}

# TODO: should probably be separate methods:
# print_config and print_data_stats
sub print_summary {
    my ($self, $data) = @_;

    $logger->info(
        "Given Context:  @{ $data->{curTestItem} }, $data->{curTestSpec}");
    $logger->info('If context is in data file then exclude')
        if $self->{exclude_given};
    $logger->info('Include context even if it is in the data file')
        unless $self->{exclude_given};
    $logger->info("Number of data items: @{[$data->{datacap}]}");
    $logger->info('Probability of including any one data item: ' .
        $self->{probability})
        if defined $self->{probability};
    $logger->info("Total Excluded: $self->{excludedData} " .
        qq!@{[ $self->{eg} ? " + test item" : "" ]}!);
    $logger->info('Nulls: ' . ($self->{exclude_nulls} ? 'exclude' : 'include') );
    $logger->info($self->{linear} ?
        'Gang: linear' : 'Gang: squared');
    $logger->info("Number of active variables: $self->{activeVar}");
    return;
}

1;

=pod

=head1 NAME

Algorithm::AM - Perl extension for Analogical Modeling using a parallel algorithm

=head1 VERSION

version 2.36

=head1 AUTHOR

Theron Stanford <shixilun@yahoo.com>, Nathan Glenn <garfieldnate@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Royal Skousen.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

__DATA__

# line 1000 "start eval"

#print to amcpresults file instead of to the screen
#TODO: move file choice to different module, and use Log::Any in this one.
$logger->remove('Screen');
$logger->add(
    Log::Dispatch::File->new(
        name      => 'amcpresults',
        min_level => 'debug',
        filename  => $project->results_path,
        newline => 1
    )
);

my ( $sec, $min, $hour );

$self->{beginhook}->($self, $data);

my $left = scalar $project->num_test_items;
foreach my $item_number (0 .. $project->num_test_items - 1) {
# line 1100 "loop items"
    $logger->debug("Test items left: $left");
    --$left;
    my $t = $project->get_test_item($item_number);
    ( $curTestOutcome, $data->{curTestItem}, $data->{curTestSpec} ) =
        @$t;
    # activeVar is the number of active variables; if we exclude nulls,
    # then we need to minus the number of '=' found in this test item;
    # otherwise, it's just the number of columns in a single item vector
    $self->{activeVar} = $project->num_variables;

## begin exclude nulls
    $self->{activeVar} -= grep {$_ eq '='} @{ $data->{curTestItem} };
## end exclude nulls

    $self->{begintesthook}->($self, $data);

    # recalculate the lattice sizes with new number of active variables;
    # must edit activeVars instead of assigning it a new arrayref because
    # the XS code only has the existing arrayref and will not be given
    # a new one. This must be done for every test item because activeVars
    # is a global that could have been edited during classification of the
    # last test item.
    # TODO: pass activeVars into fill_and_count instead of doing this
    my $lattice_sizes = _compute_lattice_sizes($self->{activeVar});
    for(0 .. $#$lattice_sizes){
        $self->{activeVars}->[$_] = $lattice_sizes->[$_];
    }
##  $activeContexts = 1 << $activeVar;

    my $nullcontext = pack "b64", '0' x 64;

    ( $sec, $min, $hour ) = localtime();
    $logger->info( sprintf( "Time: %2s:%02s:%02s", $hour, $min, $sec ) );
    $logger->info("@{ $data->{curTestItem} }");
    $logger->info( sprintf( "0/$self->{repeat}  %2s:%02s:%02s", $hour, $min, $sec ) );

    $pass = 0;
    while ( $pass < $self->{repeat} ) {
# line 1200 "repeat"
        $self->{beginrepeathook}->($self, $data);
        $data->{datacap} = int($data->{datacap});

        $self->{excludedData} = 0;
        my $testindata   = 0;
        $self->{eg}      = 0;

        %{$self->{contextsize}}             = ();
        %{$self->{itemcontextchainhead}}    = ();
        %{$self->{subtooutcome}}            = ();
        %{$self->{pointers}}                = ();
        %{$self->{gang}}                    = ();
        foreach (@{$self->{sum}}) {
            $_ = pack "L!8", 0, 0, 0, 0, 0, 0, 0, 0;
        }

        for ( my $i = $data->{datacap} ; $i ; ) {
# line 1300 "data hook"
            --$i;
            # skip this data item if the datahook returns false
            # TODO: this and the next one below would be better in an if
            # block, but this code text is searched and replaced in
            # _create_classify_sub
            ++$self->{excludedData}, next unless $self->{datahook}->($self, $data, $i);
## begin probability
            # skip this data item with probability $self->{probability}
            ++$self->{excludedData}, next
                if rand() > $self->{probability};
## end probability
            my @dataItem = @{ $project->get_exemplar_data($i) };
            my @alist    = @{$self->{activeVars}};
            my $j        = 0;
            my @clist    = ();
            while (@alist) {
                my $a = shift @alist;
                my $c = 0;
                for ( ; $a ; --$a ) {
## begin exclude nulls
                    ++$j while ${ $data->{curTestItem} }[$j] eq '=';
## end exclude nulls
                    $c = ( $c << 1 ) | ( ${ $data->{curTestItem} }[$j] ne $dataItem[$j] );
                    ++$j;
                }
                push @clist, $c;
            }
            my $context = pack "S!4", @clist;
            $self->{datatocontext}->[$i]              = $context;
            $self->{itemcontextchain}->[$i]           = $self->{itemcontextchainhead}->{$context};
            $self->{itemcontextchainhead}->{$context} = $i;
            ++$self->{contextsize}->{$context};
            my $outcome = $project->get_exemplar_outcome($i);
            if ( defined $self->{subtooutcome}->{$context} ) {
                $self->{subtooutcome}->{$context} = 0
                  if $self->{subtooutcome}->{$context} != $outcome;
            }
            else {
                $self->{subtooutcome}->{$context} = $outcome;
            }
        }
# line 1400 "given"
        if ( exists $self->{subtooutcome}->{$nullcontext} ) {
            ++$testindata;
## begin exclude given
            # TODO: this doesn't look right. Why does it check exclude_given?
            delete $self->{subtooutcome}->{$nullcontext}, ++$self->{eg} if $self->{exclude_given};
## end exclude given;
        }
# line 1500 "print summary"

        #TODO: choose Nulls and Gang value here instead of in regex for eval string
        $self->print_summary($data);
        $logger->info('Test item is in the data.')
          if $testindata;

# line 1600 "call XS"
        $self->_fillandcount(X);
        $grandtotal = $self->{pointers}->{'grandtotal'};
        unless ($grandtotal) {
            #TODO: is this tested yet?
            $logger->warn('No data items considered.  No prediction possible.');
            next;
        }

        # TODO: explain all of these formatting variables
        my $longest = length $grandtotal;
        my $gang_format =  "%$longest.${longest}s";
        my $var_format = $project->var_format;
        my $spec_format = $project->spec_format;
        my $outcome_format = $project->outcome_format;
        my $data_format = $project->data_format;

# line 1700 "calculate results"
        #TODO: put all of this information in a return value or something!
        $data->{pointermax}    = "";
        $logger->info('Statistical Summary');
        for ( my $i = 1 ; $i < @{$self->{outcomelist}} ; ++$i ) {
            my $n;
            next unless $n = $self->{sum}->[$i];

            if(
                length($n) > length($data->{pointermax})
                or length($n) == length($data->{pointermax})
                and $n gt $data->{pointermax}
            ){
                $data->{pointermax} = $n
            }
            $logger->info(
                sprintf(
                    "$outcome_format  $gang_format  %7.3f%%",
                    $project->get_outcome($i), $n, 100 * $n / $grandtotal
                )
            );
        }
        $logger->info( sprintf( "$outcome_format  $gang_format", "", '-' x $longest ) );
        $logger->info( sprintf( "$outcome_format  $gang_format", "", $grandtotal ) );
        if ( defined $curTestOutcome ) {
            $logger->info('Expected outcome: ' .
                $project->get_outcome($curTestOutcome));
            if ( $self->{sum}->[$curTestOutcome] eq $data->{pointermax} ) {
                $logger->info('Correct outcome predicted.');
            }
            else {
                $logger->info('Incorrect outcome predicted');
            }
        }

## begin analogical set
# line 1800 "analogical set"
        my @datalist = ();
        foreach my $k ( keys %{$self->{pointers}} ) {
            my $p = $self->{pointers}->{$k};
            for (
                my $i = $self->{itemcontextchainhead}->{$k} ;
                defined $i ;
                $i = $self->{itemcontextchain}->[$i]
              )
            {
                push @datalist, $i;
            }
        }
        $logger->info('Analogical Set');
        $logger->info("Total Frequency = $grandtotal");
        @datalist = sort { $a <=> $b } @datalist;
        foreach my $i (@datalist) {
            my $p = $self->{pointers}->{$self->{datatocontext}->[$i] };
            $logger->info(
                sprintf(
                    "$outcome_format  $spec_format  $gang_format  %7.3f%%",
                    $project->get_outcome(
                        $project->get_exemplar_outcome($i) ),
                    $project->get_exemplar_spec($i),
                    $p, 100 * $p / $grandtotal
                )
            );
        }
## end analogical set

## begin gang
# line 1900 "start gangs"
        #TODO: explain the magic below
        $logger->info('Gang effects');
        my $dashes = '-' x ( $longest + 10 );
        my $pad = " " x length sprintf "%7.3f%%  $gang_format x $data_format  $outcome_format",
          0, '0', 0, "";
        foreach my $k (
            sort {
                     ( length( $self->{gang}->{$b} ) <=> length( $self->{gang}->{$a} ) )
                  || ( $self->{gang}->{$b} cmp $self->{gang}->{$a} )
            } keys %{$self->{gang}}
          )
        {
            my @clist   = unpack "S!4", $k;
            my @alist   = @{$self->{activeVars}};
            my (@vtemp) = @{ $data->{curTestItem} };
            my $j       = 1;
            while (@alist) {
                my $a = pop @alist;
                my $c = pop @clist;
                for ( ; $a ; --$a ) {
## begin exclude nulls
                    ++$j while $vtemp[ -$j ] eq '=';
## end exclude nulls
                    $vtemp[ -$j ] = '' if $c & 1;
                    $c >>= 1;
                    ++$j;
                }
            }
            my $p = $self->{pointers}->{$k};
            if ( $self->{subtooutcome}->{$k} ) {
                {
                    no warnings;
                    $logger->info(
                        sprintf(
                            "%7.3f%%  $gang_format   $data_format  $outcome_format  $var_format",
                            100 * $self->{gang}->{$k} / $grandtotal,
                            $self->{gang}->{$k}, "", "", @{ $data->{curTestItem} }
                        )
                    );
                    $logger->info(
                        sprintf(
                            "$dashes   $data_format  $outcome_format  $var_format",
                            "", "", @vtemp
                        )
                    );
                }
                $logger->info(
                    sprintf(
                        "%7.3f%%  $gang_format x $data_format  $outcome_format",
                        100 * $self->{gang}->{$k} / $grandtotal,
                        $p,
                        $self->{contextsize}->{$k},
                        $project->get_outcome($self->{subtooutcome}->{$k} )
                    )
                );
## begin skip gang list
# line 2000 "skip gang list"
                my $i;
                for (
                    $i = $self->{itemcontextchainhead}->{$k} ;
                    defined $i ;
                    $i = $self->{itemcontextchain}->[$i]
                  )
                {
                    $logger->info( sprintf "$pad  $var_format  " .
                        $project->get_exemplar_spec($i),
                        @{ $project->get_exemplar_data($i) } );
                }
## end skip gang list
            }
            else {
                my @gangsort = (0) x ($project->num_outcomes + 1);
## begin skip gang list
                my @ganglist = ();
## end skip gang list
                my $i;
                for (
                    $i = $self->{itemcontextchainhead}->{$k} ;
                    defined $i ;
                    $i = $self->{itemcontextchain}->[$i]
                  )
                {
                    ++$gangsort[ $project->get_exemplar_outcome($i) ];
## begin skip gang list
                    push @{ $ganglist[
                        $project->get_exemplar_outcome($i) ] }, $i;
## end skip gang list
                }
                {
                    no warnings;
                    $logger->info(
                        sprintf(
"%7.3f%%  $gang_format   $data_format  $outcome_format  $var_format",
                            100 * $self->{gang}->{$k} / $grandtotal,
                            $self->{gang}->{$k}, "", "", @{ $data->{curTestItem} }
                        )
                    );
                    $logger->info(
                        sprintf(
                            "$dashes   $data_format  $outcome_format  $var_format",
                            "", "", @vtemp
                        )
                    );
                }
                for $i ( 1 .. $project->num_outcomes ) {
                    next unless $gangsort[$i];
                    $logger->info(
                        sprintf(
                            "%7.3f%%  $gang_format x $data_format  $outcome_format",
                            100 * $gangsort[$i] * $p / $grandtotal,
                            $p, $gangsort[$i], $project->get_outcome($i)
                        )
                    );
## begin skip gang list
                    foreach ( @{ $ganglist[$i] } ) {
                        $logger->info(
                            sprintf( "$pad  $var_format  " .
                                $project->get_exemplar_spec($_),
                                @{ $project->get_exemplar_data($_) } )
                        );
                    }
## end skip gang list
                }
            }
        }
## end gang

    }
    continue {
        $self->{endrepeathook}->($self, $data);
        ++$pass;
        ( $sec, $min, $hour ) = localtime();
        $logger->info(
            sprintf( "$pass/$self->{repeat}  %2s:%02s:%02s", $hour, $min, $sec ) );
    }
    $self->{endtesthook}->($self, $data);
}
# line 2100 "end eval"

( $sec, $min, $hour ) = localtime();
$logger->info( sprintf( "Time: %2s:%02s:%02s", $hour, $min, $sec ) );

$self->{endhook}->($self, $data);

#go back to printing to the screen
$logger->remove('amcpresults');
$logger->add(
    Log::Dispatch::Screen->new(
        name        => 'Screen',
        min_level   => 'warning',
        newline     => 1,
    )
);

__END__

=head1 SYNOPSIS

  use Algorithm::AM;

  my $p = Algorithm::AM->new('finnverb', -commas => 'no');
  $p->classify();

=head1 DESCRIPTION

Analogical Modeling is an exemplar-based way to model language usage.
C<Algorithm::AM> is a Perl module which analyzes data sets using
Analogical Modeling.

How to create data sets is not explained here.  See the appendices in
the "red book", I<Analogical Modeling: An exemplar-based approach to
language>, for details on that.  See also the "green book",
I<Analogical Modeling of Language>, for an explanation of the method
in general, and the "blue book", I<Analogy and Structure>, for its
mathematical basis.

=head1 METHODS

=head2 C<new>

Arguments: see "Initializing a Project" (TODO: reorganize POD properly)

Creates and returns a subroutine to classify the data in a given project.

=head2 C<classify>

Using the analogical modeling algorithm, this method classifies the instances
in the project and prints the results to STDOUT, as well as to
C<amcpresults> in the project directory.

=head2 C<print_summary>
THIS METHOD IS UNDER CONSTRUCTION. Currently it is called by
C<classify> to print a summary of the classifcation results.

=head1 HISTORY

Initially, Analogical Modeling was implemented as a Pascal program.
Subsequently, it was ported to Perl, with substantial improvements
made in 2000.  In 2001, the core of the algorithm was rewritten in C,
while the parsing, printing, and statistical routines remained in C;
this was accomplished by embedding a Perl interpreter into the C code.

In 2004, the algorithm was again rewritten, this time in order to
handle more variables and large data sets.  It breaks the
supracontextual lattice into the direct product of four smaller ones,
which the algorithm manipulates individually before recombining them.
Because these lattices could be manipulated in parallel, using the
right hardware, the module was named C<AM::Parallel>. Later it was
renamed C<Algorithm::AM> to fit better into the CPAN ecostystem.

To provide more flexibility and to more closely follow "the Perl way",
the C core is now an XSUB wrapped within a Perl module.  Instead of
specifying a configuration file, parameters are passed to the C<new()>
function of C<Algorithm::AM>.  The core functionality of the module has
been stripped down; the only reports available are the statistical
summary, the analogical set, and the gang listings.  However,
L<hooks|/"USING HOOKS"> are provided for users to create their own reports.
They can also manipulate various parameters at run time and redirect
output.

It is expected that future improvements will maintain a Perl interface
to an XSUB.  However, the design will remain simple enough that users
without much programming experience will still be able to use the
module with the least amount of trouble.

=head1 PROJECTS

C<Algorithm::AM> assumes the existence of a I<project>, a directory
containing the data set, the test set, and the outcome file (named,
not surprisingly, F<data>, F<test>, and F<outcome>).  Once the project
is initialized, the user can set various parameters and run the
algorithm.

If no outcome file is given, one is created using the outcomes which
appear in the data set.  If no test set is given, it is assumed that
the data set functions as the test set.

=head2 Initializing a Project

A project is initialized using the syntax

I<$p> = B<Algorithm::AM>-E<gt>B<new>(I<directory>, B<-commas> =>
I<commas>, ?I<options>?);

The first parameter must be the name of the directory where the files
are.  It can be an absolute or a relative path.  The following
parameter is required:

=over 4

=item -commas

Tells how to parse the lines of the F<data> file.  May be set to
either C<yes> or C<no>.  Any other value will trigger a warning and
stop creation of the project, as will omitting this option entirely.
See details in the "red book" to determine how to set this.

=back

The following options are available:

=over 4

=item -nulls

Tells how to treat nulls, i.e., variables marked with an equals sign
C<=>.  Can be C<include> or C<exclude>; any other value will revert
back to the default.  Default: C<exclude>.

=item -given

Tells whether or not to include the test item as a data item if it is
found in the data set.  Can be C<include> or C<exclude>; any other
value will revert back to the default.  Default: C<exclude>.

=item -linear

Determines if the analogical set will be computed using I<occurrences>
(linearly) or I<pointers> (quadratically).  If C<-linear> is set to
C<yes>, the analogical set will be computed using occurrences;
otherwise, it will be computed using pointers.  Default: compute using
pointers.

=item -probability

Sets the probability of including any one data item.  Default:
C<undef>. (TODO: what's undef do here?)

=item -repeat

Determines how many times each individual test item will be analyzed.
Only makes sense if the probability is less than 1.  Default: C<1>.

=item -skipset

Determines whether or not the analogical set is printed.  Can be
C<yes> or C<no>; any other value will revert to the default.  Default:
C<yes>.

=item -gangs

Determines whether or not gang effects will be printed.  Can be one of
the following three values:

=for comment
  I need the next block for the spacing to look right

=begin html

<p></p>

=end html

=over 8

=item *

C<yes>: Prints which contexts affect the result, how many pointers
they contain, and which data items are in them.

=item *

C<summary>: Prints which contexts affect the result and how many
pointers they contain.

=item *

C<no>: Omits any information about gang effects.

=back

Any other value will revert to the default.  Default: C<no>.

=back

So, the minimal invocation to initialize a project would be something
like

  $p = Algorithm::AM->new('finnverb', -commas => 'no');

while something fancier might be

  $p = Algorithm::AM->new('negpre', -commas => 'yes',
                         -probability => 0.2, -repeat => 5,
       -skipset => 'no', -gangs => 'summary');

Initializing a project doesn't do anything more than read in the files
and prepare them for analysis.  To actually do any work, read on.

=head2 Running a project

To run an already initialized project with the defaults set at
initialization time, use the following:

  $p->classify();

Yep, that's all there is to it.

Of course, you can override the defaults.  Any of the options set at
initialization can be temporarily overridden.  So, for instance, you
can run your project twice, once including nulls and once excluding
them, as follows:

  $p->classify(-nulls => 'include');
  $p->classify(-nulls => 'exclude');

Or, if you didn't specify a value at initialization time and accepted
the default, you can merely use

  $p->classify(-nulls => 'include');
  $p->classify();

Or you can play with the probabilities:

  $p->classify(-probability => 0.5, -repeat => 2);
  $p->classify(-probability => 0.2, -repeat => 5);
  $p->classify(-probability => 0.1, -repeat => 10);

=head2 Output

Output from the program is appended to the file F<amcpresults> in the
project directory by default.  Internally, C<Algorithm::AM> opens
F<amcpresults> at the beginning each run and selects its file handle
to be current, so that the output of all C<print()> statements gets
directed to it.  Directing output elsewhere is possible, but you can't
do it the "obvious" way; the following won't work:

  ## do not use this code -- it is a BAD example
  open FH5, ">results05";
  open FH2, ">results02";
  open FH1, ">results01";
  select FH5;
  $p->classify(-probability => 0.5, -repeat => 2);
  select FH2;
  $p->classify(-probability => 0.2, -repeat => 5);
  select FH1;
  $p->classify(-probability => 0.1, -repeat => 10);
  close FH1;
  close FH2;
  close FH5;

That's because at the very beginning of each run, the code for C<$p>
reselects the file handle.  However, you can do this using a
L<hook|/"USING HOOKS">; see C<-beginhook> for a simple example of redirected
output and C<-beginrepeathook> for a more complicated one.

L<Warnings and error messages|/"WARNINGS AND ERROR MESSAGES"> get sent
to STDERR.  If there are no fatal errors and the program runs
normally, status messages are sent to STDERR.  You can see how long
the program has been running, what test item it's currently on, and
even which iteration of an individual test item it's on if the repeat
is set greater than one.

=head1 USING HOOKS

C<Algorithm::AM> provides I<power> and I<flexibility>.  The I<power> is
in the C code; the I<flexibility> is in the I<hooks> provided for the
user to interact with the algorithm at various stages.

=head2 Hook Placement in C<Algorithm::AM>

Hooks are just references to subroutines that can be passed to the
project at run time; the subroutine references can be either named or
anonymous.  They are passed as any other option.  The following hooks
are currently implemented:

=over 4

=item -beginhook

This hook is called before any test items are run.

=item -endhook

This hook is called after all test items are run.

Example: To send all the output from a run to another file, you can do
the following:

  $p->classify(-beginhook => sub {open FH, ">myoutput"; select FH;},
       -endhook => sub {close FH;});

=item -begintesthook

This hook is called at the beginning of each new test item.  If a test
item will be run more than once, this hook is called just once before
the first iteration.

=item -endtesthook

This hook is called at the end of each test item.  If a test item will
be run more than once, this hook is called just once after the last
iteration.

Example: If each test item is run just once, and you want to keep a
running tally of how many test items are correctly predicted, you can
use the variables C<$curTestOutcome>, C<$pointermax>, and C<@sum>:

  $count = 0;
  $countsub = sub {
    ## must use eq instead of == in following statement
    ++$count if $sum[$curTestOutcome] eq $pointermax;
  };
  $p->classify(-endtesthook => $countsub,
       -endhook => sub {print "Number of correct predictions: $count\n";});

=item -beginrepeathook

This hook is called at the beginning of each iteration of a test item.


=item -endrepeathook

This hook is called at the end of each iteration of a test item.

Example: To vary the probability of each iteration through a test
item, you can use the variables C<$probability> and C<$pass>:

  open FH5, ">results05";
  open FH2, ">results02";
  $repeatsub = sub {
    $probability = (0.5, 0.2)[$pass];
    select((FH5, FH2)[$pass]);
  };
  $p->classify(-beginrepeathook => $repeatsub);

Then on iteration 0, the test item is analyzed with the probability of
any data item being included set to 0.5, with output sent to file
F<results05>, while on iteration 1, the test item is analyzed with the
probability of any data item being included set to 0.2, with output
sent to file F<results02>.

=item -datahook

This hook is called for each data item considered during a test item
run.  Unlike other hooks, which receive no arguments, this hook is
passed the index of the data item under consideration.  The value of
this index ranges from one less than the number of data items to 0
(data items are considered in reverse order in C<Algorithm::AM> for
various reasons not gone into here).

The index passed is not a copy but the actual index variable used in
C<Algorithm::AM>; be careful not to change it -- for example, by
assigning to C<$_[0]> -- unless that is what is intended.

This hook should return a true value (in the Perl sense of true) if
the data item should still be included in the test run, and should
return a false value otherwise.  To ensure this, it's a good idea to
end the subroutine assigned to the hook with

  return 1;

since

  return;

returns an undefined value.

If the probability of including any data item is less than one, this
hook is called I<before> a call to C<rand()> to see whether or not to
include the item.  If you don't like this, set C<-probability> to 1 in
the option list and call C<rand()> yourself somewhere within the hook.

Example: The results for I<sorta-> in the "red book" do not match what
you get when you run F<finnverb>.  That's because the "red book"
omitted all data items with outcome I<a-oi>.  You can do this using
the variables C<@curTestItem>, C<@outcome>, and C<%outcometonum>:

  $datasub = sub {
    ## we use @curTestItem because finnverb/test has no specifiers
    return 1 unless join('', @curTestItem) eq 'SO0=SR0=TA';
    return 1 unless $outcome[$_[0]] eq $outcometonum{'a-oi'};
    return 0;
  };
  $p->classify(-datahook => $datasub);

=back

=head2 Hook Variables

Various variables can be read and even manipulated by the hooks.

B<Note:> All hook variables are exported into package C<main>.  If you
don't know what this means, chances are you don't need to worry about
it; if you I<do> know what it means, you'll know how to deal with it.

However, these variables exist in package C<main> only while a project
is being run (they are exported using C<local()>).  Thus, you can only
access them through a hook, and they will not clobber the values of
variables of the same name outside of the run.

=head3 Variables Fixed at Initialization

These variables should be considered B<read-only>, unless you're
B<really sure> what you're doing.

=over 4

=item @outcomelist

This array lists all possible outcomes.  It is generated either from
the F<outcome> file, if it exists, or from the outcomes that appear in
the F<data> file.  If there is a "short" version and a "long" version
of each outcome, C<@outcomelist> contains the "long" version.

Outcomes are assigned positive integer values; outcome 0 is reserved
for internal use of C<Algorithm::AM>.  (You'll have to look at the
source code and its documentation for further details, which most
likely you won't need.)

Example: File F<finnverb/outcome> is as follows:

  A V-i
  B a-oi
  C tV-si

During initialization, C<Algorithm::AM> makes a series of assignments
equivalent to the following:

  @outcomelist = ('', 'V-i', 'a-oi', 'tV-si');

=item %outcometonum

This hash maps outcome strings (the "long" ones that appear in
C<@outcomelist>) to their respective positions in C<@outcomelist>.

=item @outcome

C<$outcome[$i]> contains the outcome of data item C<$i> as an integer
index into C<@outcomelist>.

=item @data

C<$data[$i]> is a reference to an array containing the variables of
data item C<$i>.

=item @spec

C<$spec[$i]> contains the specifier for data item C<$i>.

Example: Line 80 of file F<finnverb/data> is as follows:

  C MU0=SR0=TA MURTA

During initialization, C<Algorithm::AM> makes a series of assignments
equivalent to the following:

  $outcome[79] = 3;
  $data[79] = ['M', 'U', '0', '=', 'S', 'R', '0', '=', 'T', 'A'];
  $spec[79] = 'MURTA';

=back

=head3 Variables Used for a Specific Test Item

These variables should be considered B<read-only>, unless you're
B<really sure> what you're doing.

=over 4

=item $curTestOutcome

Contains the outcome index for the outcome of the current test item,
as determined by C<@outcomelist>, if an outcome has been specified,
and 0 otherwise.

=item @curTestItem

Contains the variables of the current test item.

=item $curTestSpec

Contains the specifier of the current test item, if one has been
specified, and is empty otherwise.

=back

=head3 Variables Used for a Specific Iteration of a Test Item Run

=over 4

=item $probability

Setting this changes the likelihood of including any one particular
data item in a test run.  B<Note:> If the option C<-probability> is
not set at either initialization time or at run time, setting the
value of C<$probability> inside a hook has no effect.  (This is an
intentional optimization; see the source code and its documentation
for the reason why.)  Therefore, if you plan to change the probability
during test item runs, make sure to specify a value (1 is a good
choice) for the option C<-probability>.

=item $pass

This variable indicates the current iteration of a test item run; it
will range from 0 to one less than the number specified by the
C<-repeat> option.

B<Note:> You cannot (easily) change the number of repetitions from
within a hook.  You can only do this (easily) using the C<-repeat>
option at run time.  This is because typically you want each test item
to be subjected to the same number of repetitions.  (But if for some
reason you really want to do this, you can increase C<$pass> so that
C<Algorithm::AM> will skip some passes.  You're on your own figuring
out which hook to put this in.)

=item $datacap

This variable determines how many data items will be considered.  It
is initially set to C<scalar @data>.  However, if it is set smaller,
only the first C<$datacap> items in the F<data> file will be
considered.  C<Algorithm::AM> automatically truncates C<$datacap> if it
isn't an integer, so you don't have to.

Example: It is often of interest to see how results change as the
number of data items considered decreases.  Here's one way to do it:

  $repeatsub = sub {
    $datacap = (1, 0.5, 0.25)[$pass] * scalar @data;
  };
  $p->classify(-repeat => 3, -beginrepeathook => $repeatsub);

Note that this will give different results than the following:

  $repeatsub = sub {
    $probability = (1, 0.5, 0.25)[$pass];
  };
  $p->classify(-probability => 1, -repeat => 3, -beginrepeathook => $repeatsub);

The first way would be useful for modeling how predictions change as
more examples are gathered -- say, as a child grows older (though the
way it's written, it looks like the child is actually growing
younger).  The second way would be useful for modeling how predictions
change as memory worsens -- say, as an adult grows older.  Note that
option C<-probability> must be specified at run time if it hasn't been
at initialization time; otherwise, calling the hook has no effect.

=back

=head3 Variables Available at the End of a Test Run Iteration

Before looking at these variables, it is important to know what they
contain.

C<Algorithm::AM> works with really big integers, much larger than what
32 bits can hold.  The XSUB uses a special internal format for storing
them.  (You can read all about it in the usual place: the source code
and its documentation.)  However, when the XSUB has finished its
computations, it converts these integers into something that the Perl
code finds more useful.

The scalar values returned from the XSUB are I<dual-valued> scalars;
they have different values depending on the context they're called
in.  In string context, you get a string representation of the
integer.  In numeric context, you get a double.

For example, if C<$n> and C<$d> are big integers returned from the
XSUB, you can write

  print $n/$d;

to see the decimal value of the fraction you get when you divide C<$n>
by C<$d>, because the division will use the numeric values, while

  print "$n/$d";

will let you see this fraction expressed as the quotient of two
integers, because the quotation marks will interpolate the string
values.

Because of this, you can't use C<==> to test if two big integers have
the same value -- they might be so big that the double representation
doesn't give enough accuracy to distinguish them.  Use C<eq> to test
equality.

If you need a comparison operator, you can use C<bigcmp()>.

=over 4

=item @sum

Contains the number of pointers for each outcome index.  (Remember
that outcome indices start with 1.)

=item $pointertotal

Contains the total number of pointers.

=item $pointermax

Contains the maximum value among all the values in C<@sum>.

=back

Note that there is no variable reporting which outcome has the most
pointers.  That's because there could be a tie, and different users
treat ties in different ways.  So, if you want to see which outcomes
have the highest number of pointers, try something like this:

  @winners = ();
  for ($i = 1; $i < @sum; ++$i) {
    push @winners, $i if $sum[$i] eq $pointermax; ## use eq, not ==
  }

For another example using these variables, see C<-endtesthook>.

=head3 Variables Useful for Formatting

You may want to create your own reports.  These variables can help
your formatting.  (They are also used by C<Algorithm::AM> to format the
standard reports.)

=over 4

=item $dformat

Leaves enough space to hold an integer equal to the number of data
items.  Justifies right.

=item $sformat

Leaves enough space to hold any of the specifiers in the data set.  Justifies left.

=item $oformat

Leaves enough space to hold a "long" outcome.  Justifies left.

=item $vformat

Formats a list of variables.  Set C<-gangs> to C<yes> for an example.

=item $pformat

Leaves enough space to hold the big integer C<$pointertotal>, and thus
is big enough to hold C<$pointermax> or any element of C<@sum> as
well.  Justifies right.

B<Note:> This variable changes with each iteration of a test item.

=back

=head2 Hook Function

The following function is also exported into package C<main> and
available for use in hooks.  This is done with C<local()>, just as
with hook variables, so it is not available outside of hooks.

=over 4

=item bigcmp()

Compares two big integers, returning 1, 0, or -1 depending on whether
the first argument is greater than, equal to, or less than the second
argument.  Remember that the syntax is different: you must write

  bigcmp($a, $b)

instead of C<$a bigcmp $b>.

=back

=head1 MORE EXAMPLES

=head2 Summarizing a Repeated Test Item

Suppose you run each test item 5 times, each with probability 0.005,
and you want to create a statistical analysis summarizing the results
for each test item.  Here's one way to do it:

  $begintest = sub {
    $valid = 0;
    @testPct = ();
    @testPctSq = ();
    $correct = 0;
  };
  $endrepeat = sub {
    return unless $pointertotal;
    ++$valid;
    ++$correct if $sum[$curTestOutcome] eq $pointermax;
    for ($i = 1; $i < @outcomelist; ++$i) {
      $testPct[$i] += $sum[$i]/$pointertotal;
      $testPctSq[$i] += ($sum[$i]*$sum[$i])/($pointertotal*$pointertotal);
    }
  };
  $endtest = sub {
    print "Summary for test item: $curTestSpec\n";
    print "Valid runs: $valid out of 5\n\n";
    print "\n" and return unless $valid;
    printf "$oformat    Avg     Std Dev\n", "";
    for ($i = 1; $i < @outcomelist; ++$i) {
      next unless $testPct[$i];
      if ($valid > 1) {
        printf "$oformat  %7.3f%% %7.3f%%\n",
    $outcomelist[$i],
    100 * $testPct[$i]/$valid,
    100 * sqrt(($testPctSq[$i]-$testPct[$i]*$testPct[$i]/$valid)/($valid-1));
      } else {
        printf "$oformat  %7.3f%%\n",
    $outcomelist[$i],
    100 * $testPct[$i]/$valid;
      }
    }
    printf "\nCorrect prediction occurred %7.3f%% (%i/5) of the time\n",
      100 * $correct / 5,
      $correct;
    print "\n\n";
  };
  $p->classify(-probability => 0.005, -repeat => 5,
       -begintesthook => $begintest, -endrepeathook => $endrepeat, -endtesthook => $endtest);

=head2 Creating a Confusion Matrix

Suppose you want to compare correct outcomes with predicted outcomes.
Here's one way to do it:

  $begin = sub {
    @confusion = ();
  };
  $endrepeat = sub {
    if (!$pointertotal) {
      ++$confusion[$curTestOutcome][0];
      return;
    }
    if ($sum[$curTestOutcome] eq $pointermax) {
      ++$confusion[$curTestOutcome][$curTestOutcome];
      return;
    }
    my @winners = ();
    my $i;
    for ($i = 1; $i < @outcomelist; ++$i) {
      push @winners, $i if $sum[$i] == $pointermax;
    }
    my $numwinners = scalar @winners;
    foreach (@winners) {
      $confusion[$curTestOutcome][$_] += 1 / $numwinners;
    }
  };
  $end = sub {
    my($i,$j);
    for ($i = 1; $i < @outcomelist; ++$i) {
      my $total = 0;
      foreach (@{$confusion[$i]}) {
        $total += $_;
      }
      next unless $total;
      printf "Test items with outcome $oformat were predicted as follows:\n",
        $outcomelist[$i];
      for ($j = 1; $j < @outcomelist; ++$j) {
        my $t;
        next unless ($t = $confusion[$i][$j]);
        printf "%7.3f%% $oformat  (%i/%i)\n", 100 * $t / $total, $outcomelist[$j], $t, $total;
      }
      if ($t = $confusion[$i][0]) {
        printf "%7.3f%% could not be predicted (%i/%i)\n", 100 * $t / $total, $t, $total;
      }
      print "\n\n";
    }
  };
  $p->classify(-probability => 0.005, -repeat => 5,
       -beginhook => $begin, -endrepeathook => $endrepeat, -endhook => $end);


=head1 WARNINGS AND ERROR MESSAGES

=over 4

=item Project not specified

No project was specified in the call to C<< Algorithm::AM->new >>.  An
empty subroutine is returned (so that batch scripts do not break).

=item Project %s has no data file

The project directory has no file named F<data>.  An empty subroutine
is returned (so that batch scripts do not break).

=item Project %s did not specify comma formatting

The required parameter C<-commas> was not provided.  An empty
subroutine is returned (so that batch scripts do not break).

=item Project %s did not specify comma formatting correctly

Parameter C<-commas> must be either C<yes> or C<no>.  An empty
subroutine is returned (so that batch scripts do not break).

=item Project %s did not specify option -nulls correctly

Parameter C<-nulls> must be either C<include> or C<exclude>.
Displayed default value will be used.

=item Project %s did not specify option -given correctly

Parameter C<-given> must be either C<include> or C<exclude>.
Displayed default value will be used.

=item Project %s did not specify option -skipset correctly

Parameter C<-skipset> must be either C<yes> or C<no>.
Displayed default value will be used.

=item Project %s did not specify option -gangs correctly

Parameter C<-gangs> must be either C<yes>, C<summary>, or C<no>.
Displayed default value will be used.

=item Couldn't open %s/test

Project %s does not have a F<test> file.  The F<data> file will be
used.

=back

=head1 SEE ALSO

The <home page|http://humanities.byu.edu/am/> for Analogical Modeling
includes information about current research and publications, awell as
sample data sets.

The L<Wikipedia article|http://en.wikipedia.org/wiki/Analogical_modeling>
has details and illustrations explaining the utility and inner-workings
of analogical modeling.

=head1 AUTHORS

Theron Stanford <shixilun@yahoo.com>

Nathan Glenn <garfieldnate@gmail.com>

=head1 COPYRIGHT

Copyright (C) 2004 by Royal Skousen

=cut
