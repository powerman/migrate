use strict;
use Test::More;
use Test::Exception;
use Path::Tiny qw( path tempdir tempfile );
use App::migrate;


my $migrate = App::migrate->new;
my $file    = tempfile('migrate.XXXXXX');

my $proj    = tempdir('migrate.project.XXXXXX');
my $guard   = bless {};
sub DESTROY { chdir q{/} }
chdir $proj or die "chdir($proj): $!";

$file->spew_utf8(<<'MIGRATE');
VERSION 1
upgrade     touch empty_file
downgrade   rm empty_file
upgrade     mkdir empty_dir
downgrade   rmdir empty_dir
VERSION 2
MIGRATE

ok $migrate,                            'new';

lives_ok { $migrate->load($file) }      'load';

ok !$proj->children,                    'proj is empty';

$migrate->on(BACKUP => sub {});

lives_ok { $migrate->run( $migrate->find_paths('2', '1') ) } 'migrate 1->2';

is $proj->children, 2,                  'proj is not empty:';
ok $proj->child('empty_file')->is_file, '... has empty_file';
ok $proj->child('empty_dir')->is_dir,   '... has empty_dir/';

lives_ok { $migrate->run( $migrate->find_paths('1', '2') ) } 'migrate 2->1';

ok !$proj->children,                    'proj is empty';


done_testing;
