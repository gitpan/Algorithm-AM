use strict;
use warnings;
use Test::More 0.88;
# This is a relatively nice way to avoid Test::NoWarnings breaking our
# expectations by adding extra tests, without using no_plan.  It also helps
# avoid any other test module that feels introducing random tests, or even
# test plans, is a nice idea.
our $success = 0;
END { $success && done_testing; }
diag('I"m in Tiny.pm right now');
# List our own version used to generate this
my $v = "\nGenerated by Dist::Zilla::Plugin::ReportVersions::Tiny v1.08\n";

eval {                     # no excuses!
    # report our Perl details
    my $want = '5.010';
    $v .= "perl: $] (wanted $want) on $^O from $^X\n\n";
};
defined($@) and diag("$@");

# Now, our module version dependencies:
sub pmver {
    my ($module, $wanted) = @_;
    $wanted = " (want $wanted)";
    my $pmver;
    eval "require $module;";
    if ($@) {
        if ($@ =~ m/Can't locate .* in \@INC/) {
            $pmver = 'module not found.';
        } else {
            diag("${module}: $@");
            $pmver = 'died during require.';
        }
    } else {
        my $version;
        eval { $version = $module->VERSION; };
        if ($@) {
            diag("${module}: $@");
            $pmver = 'died during VERSION check.';
        } elsif (defined $version) {
            $pmver = "$version";
        } else {
            $pmver = '<undef>';
        }
    }

    # So, we should be good, right?
    return sprintf('%-45s => %-10s%-15s%s', $module, $pmver, $wanted, "\n");
}

eval { $v .= pmver('Carp','any version') };
eval { $v .= pmver('Data::Dumper','any version') };
eval { $v .= pmver('Dist::Zilla','4.300039') };
eval { $v .= pmver('Dist::Zilla::Plugin::ArchiveRelease','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::AutoPrereqs','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Bugtracker','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::CPANFile','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::CheckChangesHasContent','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::CheckPrereqsIndexed','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Clean','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::ConfirmRelease','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::CopyFilesFromBuild','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::ExecDir','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::GatherDir','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::GenerateFile','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Git::Commit','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Git::NextVersion','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Git::Push','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Git::Tag','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::GithubMeta','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Homepage','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::InstallGuide','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::License','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MakeMaker','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Manifest','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::ManifestSkip','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MetaConfig','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MetaData::BuiltWith','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MetaJSON','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MetaNoIndex','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MetaProvides::Package','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MetaResources','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MetaTests','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MetaYAML','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MinimumPerl','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::MojibakeTests','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::NextRelease','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::OverridePkgVersion','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::PodCoverageTests','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::PodSyntaxTests','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::PodWeaver','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Prepender','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Prereqs::AuthorDeps','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::PruneCruft','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::ReadmeAnyFromPod','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::ReadmeFromPod','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::ReportPhase','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::ReportVersions::Tiny','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Repository','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::RunExtraTests','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::ShareDir','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Signature','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::CPAN::Changes','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::CPAN::Meta::JSON','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::Compile','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::DistManifest','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::Kwalitee','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::MinimumVersion','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::Perl::Critic','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::Pod::LinkCheck','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::Portability','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::Synopsis','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::UnusedVars','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::Test::Version','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::TestRelease','any version') };
eval { $v .= pmver('Dist::Zilla::Plugin::UploadToCPAN','any version') };
eval { $v .= pmver('Exporter::Easy','any version') };
eval { $v .= pmver('ExtUtils::MakeMaker','6.30') };
eval { $v .= pmver('File::Find','any version') };
eval { $v .= pmver('File::Slurp','any version') };
eval { $v .= pmver('File::Temp','any version') };
eval { $v .= pmver('FindBin','any version') };
eval { $v .= pmver('IO::Handle','any version') };
eval { $v .= pmver('Log::Any','any version') };
eval { $v .= pmver('Log::Dispatch','any version') };
eval { $v .= pmver('Log::Dispatch::File','any version') };
eval { $v .= pmver('Path::Tiny','any version') };
eval { $v .= pmver('Pod::Coverage::TrustPod','any version') };
eval { $v .= pmver('Test::CPAN::Meta','any version') };
eval { $v .= pmver('Test::Exception','any version') };
eval { $v .= pmver('Test::LongString','any version') };
eval { $v .= pmver('Test::More','0.88') };
eval { $v .= pmver('Test::NoWarnings','any version') };
eval { $v .= pmver('Test::Pod','1.41') };
eval { $v .= pmver('Test::Pod::Coverage','1.08') };
eval { $v .= pmver('Test::Warn','any version') };
eval { $v .= pmver('XSLoader','any version') };
eval { $v .= pmver('feature','any version') };
eval { $v .= pmver('integer','any version') };
eval { $v .= pmver('strict','any version') };
eval { $v .= pmver('subs','any version') };
eval { $v .= pmver('vars','any version') };
eval { $v .= pmver('version','0.9901') };
eval { $v .= pmver('warnings','any version') };


# All done.
$v .= <<'EOT';

Thanks for using my code.  I hope it works for you.
If not, please try and include this output in the bug report.
That will help me reproduce the issue and solve your problem.

EOT

diag($v);
ok(1, "we really didn't test anything, just reporting data");
$success = 1;

# Work around another nasty module on CPAN. :/
no warnings 'once';
$Template::Test::NO_FLUSH = 1;
exit 0;
