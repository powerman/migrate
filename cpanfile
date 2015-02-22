requires 'perl', '5.010001';
requires 'File::Temp';
requires 'List::Util';
requires 'Getopt::Long';

on configure => sub {
    requires 'Devel::AssertOS';
    requires 'Module::Build::Tiny', '0.039';
};

on test => sub {
    requires 'Test::More', '0.96';
};

on develop => sub {
    requires 'Test::Perl::Critic';
};
