use strict;
use Test::More;
use Test::Exception;
use Test::Output;
use Path::Tiny qw( path tempdir tempfile );
use App::migrate;


my $migrate = App::migrate->new;
my $file    = tempfile('migrate.XXXXXX');

my $proj    = tempdir('migrate.project.XXXXXX');
my $guard   = bless {};
sub DESTROY { chdir q{/} }
chdir $proj or die "chdir($proj): $!";

my (@backup, @restore);
$migrate->on(BACKUP  => sub { push @backup,  shift->{version} });
$migrate->on(RESTORE => sub { push @restore, shift->{version} });

ok $migrate,                            'new';

# Make sure example from documentation actually works
$file->spew_utf8(<<'MIGRATE');
VERSION 0.0.0
# To upgrade from 0.0.0 to 0.1.0 we need to create new empty file and
# empty directory.
upgrade     touch   empty_file
downgrade   rm      empty_file
upgrade     mkdir   empty_dir
downgrade   rmdir   empty_dir
VERSION 0.1.0
# To upgrade from 0.1.0 to 0.2.0 we need to drop old database. This
# change can't be undone, so only way to downgrade from 0.2.0 is to
# restore 0.1.0 from backup.
upgrade     rm      useless.db
RESTORE
VERSION 0.2.0
# To upgrade from 0.2.0 to 1.0.0 we need to run several commands,
# and after downgrading we need to kill some background service.
before_upgrade
    patch    <0.2.0.patch >/dev/null
    chmod +x some_daemon
downgrade
    patch -R <0.2.0.patch >/dev/null
upgrade
    ./some_daemon &
after_downgrade
    killall -9 some_daemon
VERSION 1.0.0

# Let's define some lazy helpers:
DEFINE2 only_upgrade
upgrade
downgrade /bin/true

DEFINE2 mkdir
upgrade
    mkdir "$@"
downgrade
    rm -rf "$@"

# ... and use it:
only_upgrade
    echo "Just upgraded to $MIGRATE_NEXT_VERSION"

VERSION 1.0.1

# another lazy macro (must be defined above in same file)
mkdir dir1 dir2

VERSION 1.1.0
MIGRATE

lives_ok { $migrate->load($file) }      'load';

subtest '0.0.0 <-> 0.1.0', sub {
    ok !$proj->children,                    'proj is empty';
    lives_ok { $migrate->run( $migrate->find_paths('0.1.0', '0.0.0') ) } '0.0.0->0.1.0';
    is $proj->children, 2,                  'proj is not empty:';
    ok $proj->child('empty_file')->is_file, '... has empty_file';
    ok $proj->child('empty_dir')->is_dir,   '... has empty_dir/';

    lives_ok { $migrate->run( $migrate->find_paths('0.0.0', '0.1.0') ) } '0.1.0->0.0.0';
    ok !$proj->children,                    'proj is empty';

    done_testing;
};

subtest '0.1.0 <-> 0.2.0', sub {
    path('useless.db')->touch;
    ok -e 'useless.db', 'created useless.db';
    lives_ok { $migrate->run( $migrate->find_paths('0.2.0', '0.1.0') ) } '0.1.0->0.2.0';
    ok !-e 'useless.db', 'useless.db was removed';

    lives_ok { $migrate->run( $migrate->find_paths('0.1.0', '0.2.0') ) } '0.2.0->0.1.0';
    is_deeply \@restore, [qw(0.1.0)], '... RESTORE 0.1.0';

    done_testing;
};

subtest '0.2.0 <-> 1.0.0', sub {
    path('0.2.0.patch')->spew_utf8(<<'PATCH');
diff -uNr some_daemon some_daemon
--- some_daemon	1970-01-01 03:00:00.000000000 +0300
+++ some_daemon	2015-02-24 06:34:47.321969399 +0200
@@ -0,0 +1,2 @@
+#!/bin/sh
+kill -STOP $$
PATCH

    lives_ok { $migrate->run( $migrate->find_paths('1.0.0', '0.2.0') ) } '0.2.0->1.0.0';
    ok -e 'some_daemon', '... ./some_daemon exists';
    is system('ps | grep -q some_daemon'), 0, '... some_daemon is running';

    lives_ok { $migrate->run( $migrate->find_paths('0.2.0', '1.0.0') ) } '1.0.0->0.2.0';
    isnt system('ps | grep -q some_daemon'), 0, '... some_daemon is not running';
    ok !-e 'some_daemon', '... ./some_daemon does not exists';

    path('0.2.0.patch')->remove;
    done_testing();
};

subtest '1.0.0 -> 1.0.1', sub {
    lives_ok {
        stdout_is(sub {
            $migrate->run( $migrate->find_paths('1.0.1', '1.0.0') )
        }, "Just upgraded to 1.0.1\n"."\n", 'echo was run');
    } '1.0.0->1.0.1';
    lives_ok {
        stdout_is(sub {
            $migrate->run( $migrate->find_paths('1.0.0', '1.0.1') )
        }, ""."\n", 'nothing was run');
    } '1.0.1->1.0.0';

    done_testing;
};

subtest '1.0.1 -> 1.1.0', sub {
    ok !$proj->children, 'proj is empty';
    lives_ok { $migrate->run( $migrate->find_paths('1.1.0', '1.0.1') ) } '1.0.1->1.1.0';
    ok -d 'dir1', '... dir1/ exists';
    ok -d 'dir2', '... dir2/ exists';
    lives_ok { $migrate->run( $migrate->find_paths('1.0.1', '1.1.0') ) } '1.1.0->1.0.1';
    ok !$proj->children, 'proj is empty';
};


done_testing;
