#make sure we can read different formats (just the comma-delimited one for now)
use strict;
use warnings;
use Algorithm::AM;
use Test::More 0.88;
use Test::LongString;
use FindBin qw($Bin);
use Path::Tiny;
use File::Slurp;

plan tests => 1;

my $project_path = path($Bin, 'data', 'chapter3');
my $results_path = path($project_path, 'amcpresults');
#clean up previous test runs
unlink $results_path
	if -e $results_path;

my $am = Algorithm::AM->new(
	$project_path,
	-commas => 'no',
	-repeat => 2,
);
$am->classify();
my $results = read_file($results_path);
is(() = $results =~ m/e\s+4\s+30.769%\v+r\s+9\s+69.231%/g, 2,
	'exemplar is analyzed twice') or diag $results;

#clean up the amcpresults file
unlink $results_path
	if -e $results_path;