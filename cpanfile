requires 'perl', '5.010001';
requires 'Path::Tiny';
requires 'List::Util';
requires 'Getopt::Long';

on configure => sub {
    requires 'Devel::AssertOS';
    requires 'Module::Build::Tiny', '0.039';
};

on test => sub {
    requires 'Test::More', '0.96';
    requires 'Test::Exception';
};

on develop => sub {
    requires 'Test::Perl::Critic';
};

