use strict;
use Test::More;
use Test::Exception;
use POSIX qw(locale_h); BEGIN { setlocale(LC_MESSAGES,'en_US.UTF-8') } # avoid UTF-8 in $!
use Path::Tiny qw( path tempdir tempfile );
use App::migrate;


my $migrate = App::migrate->new;
my $file    = tempfile('migrate.XXXXXX');

my $proj    = tempdir('migrate.project.XXXXXX');
my $guard   = bless {};
sub DESTROY { chdir q{/} }
chdir $proj or die "chdir($proj): $!";

$file->remove;
throws_ok { $migrate->load($file) } qr/No such file/msi;

$file->touch;
lives_ok  { $migrate->load($file) } 'empty file';

$file->spew_utf8(<<"MIGRATE");

# previous line is empty, next contain space symbols
  \t
MIGRATE
lives_ok  { $migrate->load($file) } 'empty lines and comments';

$file->spew_utf8(<<"MIGRATE");
DEFINE4 bug/define4_order
before_upgrade
upgrade
downgrade
after_downgrade
VERSION 0
bug/define4_order /bin/true
VERSION 1
MIGRATE
lives_ok  { $migrate->load($file) } 'DEFINE4';


done_testing;
