package App::migrate;
use 5.010001;
use warnings;
use strict;
use utf8;
use Carp;
## no critic (RequireCarping)

our $VERSION = 'v0.1.0';

use List::Util qw( first any );
use File::Temp qw( tempfile ); # don't use Path::Tiny to have temp files in error $SHELL

use constant KW_DEFINE      => { map {$_=>1} qw( DEFINE DEFINE2 DEFINE4     ) };
use constant KW_VERSION     => { map {$_=>1} qw( VERSION                    ) };
use constant KW_UP          => { map {$_=>1} qw( before_upgrade upgrade     ) };
use constant KW_DOWN        => { map {$_=>1} qw( downgrade after_downgrade  ) };
use constant KW_RESTORE     => { map {$_=>1} qw( RESTORE                    ) };
use constant KW             => { %{&KW_UP}, %{&KW_DOWN}, %{&KW_DEFINE}, %{&KW_RESTORE}, %{&KW_VERSION} };
use constant DEFINE_TOKENS  => 1;
use constant DEFINE2_TOKENS => 2;
use constant DEFINE4_TOKENS => 4;


# cleanup temp files
$SIG{HUP} = $SIG{HUP}     // \&CORE::exit; ## no critic (RequireLocalizedPunctuationVars)
$SIG{INT} = $SIG{INT}     // \&CORE::exit; ## no critic (RequireLocalizedPunctuationVars)
$SIG{QUIT}= $SIG{QUIT}    // \&CORE::exit; ## no critic (RequireLocalizedPunctuationVars)
$SIG{TERM}= $SIG{TERM}    // \&CORE::exit; ## no critic (RequireLocalizedPunctuationVars)


sub new {
    my ($class) = @_;
    my $self = bless {
        paths   => {},  # {prev_version}{next_version} = \@steps
        on      => {
            BACKUP  => \&_on_backup,
            RESTORE => \&_on_restore,
            VERSION => \&_on_version,
            error   => \&_on_error,
        },
    }, ref $class || $class;
    return $self;
}

sub find_paths {
    my ($self, $from, $to) = @_;
    return $self->_find_paths($to, $from);
}

sub get_steps {
    my ($self, $path) = @_;
    my @path = @{ $path };
    my @all_steps;
    for (; 2 <= @path; shift @path) {
        my ($prev, $next) = @path;
        croak "unknown version '$prev'" if !$self->{paths}{$prev};
        croak "no one-step migration from '$prev' to '$next'" if !$self->{paths}{$prev}{$next};
        my @steps = @{ $self->{paths}{$prev}{$next} };
        if (any { $_->{type} eq 'RESTORE' } @steps) {
            @all_steps = @steps;
        }
        else {
            push @all_steps, @steps;
        }
    }
    return @all_steps;
}

sub load {
    my ($self, $file) = @_;

    open my $fh, '<:encoding(UTF-8)', $file or die "open($file): $!";
    my @op = _preprocess(_tokenize($fh, { file => $file, line => 0 }));
    close $fh or croak "close($file): $!";

    my ($prev_version, $next_version, @steps) = (q{}, q{});
    while (@op) {
        my $op = shift @op;
        if (KW_VERSION->{$op->{op}}) {
            $next_version = $op->{args}[0];
            if ($prev_version ne q{}) {
                $self->{paths}{ $prev_version }{ $next_version } ||= [
                    (grep { $_->{type} eq 'before_upgrade'  } @steps),
                    (grep { $_->{type} eq 'upgrade'         } @steps),
                    {
                        type            => 'VERSION',
                        version         => $next_version,
                    },
                ];
                my $restore = first { KW_RESTORE->{$_->{type}} } @steps;
                $self->{paths}{ $next_version }{ $prev_version } ||= [
                  $restore ? (
                    $restore,
                  ) : (
                    (grep { $_->{type} eq 'downgrade'       } reverse @steps),
                    (grep { $_->{type} eq 'after_downgrade' } reverse @steps),
                  ),
                    {
                        type            => 'VERSION',
                        version         => $prev_version,
                    },
                ];
                for (@{ $self->{paths}{ $prev_version }{ $next_version } }) {
                    $_->{prev_version} = $prev_version;
                    $_->{next_version} = $next_version;
                }
                for (@{ $self->{paths}{ $next_version }{ $prev_version } }) {
                    $_->{prev_version} = $next_version;
                    $_->{next_version} = $prev_version;
                }
            }
            ($prev_version, $next_version, @steps) = ($next_version, q{});
        }
        elsif (KW_UP->{$op->{op}}) {
            die _e($op, "need VERSION before $op->{op}") if $prev_version eq q{};
            my ($cmd1, @args1) = @{ $op->{args} };
            push @steps, {
                type            => $op->{op},
                cmd             => $cmd1,
                args            => \@args1,
            };
            die _e($op, "need RESTORE|downgrade|after_downgrade after $op->{op}")
                if !( @op && (KW_DOWN->{$op[0]{op}} || KW_RESTORE->{$op[0]{op}}) );
            my $op2 = shift @op;
            if (KW_RESTORE->{$op2->{op}}) {
                push @steps, {
                    type            => 'RESTORE',
                    version         => $prev_version,
                };
            }
            else {
                my ($cmd2, @args2) = @{ $op2->{args} };
                push @steps, {
                    type            => $op2->{op},
                    cmd             => $cmd2,
                    args            => \@args2,
                };
            }
        }
        else {
            die _e($op, "need before_upgrade|upgrade before $op->{op}");
        }
    }

    return $self;
}

sub on {
    my ($self, $e, $code) = @_;
    croak "unknown event $e" if !$self->{on}{$e};
    $self->{on}{$e} = $code;
    return $self;
}

sub run {
    my ($self, $path) = @_;
    my @path = @{ $path };
    croak "no steps for path: @path" if !$self->get_steps($path);  # validate full @path before starting
    my $from;
    eval {
        my $just_restored = 0;
        for (; 2 <= @path; shift @path) {
            my ($prev, $next) = @path;
            if (!$just_restored) {
                $self->_do({
                    type            => 'BACKUP',    # internal step type
                    version         => $prev,
                    prev_version    => $prev,
                    next_version    => $next,
                });
                $from = $prev;
            }
            $just_restored = 0;
            for my $step ($self->get_steps([$prev, $next])) {
                $self->_do($step);
                if ($step->{type} eq 'RESTORE') {
                    $just_restored = 1;
                }
            }
        }
        1;
    }
    or do {
        my $err = $@;
        if ($from) {
            eval {
                $self->_do({
                    type            => 'RESTORE',   # internal step type
                    version         => $from,
                    prev_version    => $from,
                    next_version    => $path[-1],
                });
                warn "successfully undone interrupted migration by RESTORE $from\n";
                1;
            } or warn "failed to RESTORE $from: $@";
        }
        die $err;
    };
    return;
}

sub _data2arg {
    my ($data) = @_;

    return if $data eq q{};

    my ($fh, $file) = tempfile('migrate.XXXXXX', TMPDIR=>1, UNLINK=>1);
    print {$fh} $data;
    close $fh or croak "close($file): $!";

    return $file;
}

sub _do {
    my ($self, $step) = @_;
    local $ENV{MIGRATE_PREV_VERSION} = $step->{prev_version};
    local $ENV{MIGRATE_NEXT_VERSION} = $step->{next_version};
    eval {
        if ($step->{type} eq 'BACKUP' or $step->{type} eq 'RESTORE' or $step->{type} eq 'VERSION') {
            $self->{on}{ $step->{type} }->($step);
        }
        else {
            my $cmd = $step->{cmd};
            if ($cmd =~ /\A#!/ms) {
                $cmd = _data2arg($cmd);
                chmod 0700, $cmd or croak "chmod($cmd): $!";    ## no critic (ProhibitMagicNumbers)
            }
            system($cmd, @{ $step->{args} }) == 0 or die "$step->{type} failed: $cmd @{ $step->{args} }\n";
            print "\n";
        }
        1;
    }
    or do {
        warn $@;
        $self->{on}{error}->($step);
    };
    return;
}

sub _e {
    my ($loc, $msg, $near) = @_;
    return "parse error: $msg at $loc->{file}:$loc->{line}"
      . ($near eq q{} ? "\n" : " near '$near'\n");
}

sub _find_paths {
    my ($self, $to, @from) = @_;
    my $p = $self->{paths}{ $from[-1] } || {};
    return [@from, $to] if $p->{$to};
    my %seen = map {$_=>1} @from;
    return map {$self->_find_paths($to,@from,$_)} grep {!$seen{$_}} keys %{$p};
}

sub _on_backup {
    croak 'you need to define how to make BACKUP';
}

sub _on_restore {
    croak 'you need to define how to RESTORE from backup';
}

sub _on_version {
    # do nothing
}

sub _on_error {
    warn <<'ERROR';

YOU NEED TO MANUALLY FIX THIS ISSUE RIGHT NOW
When done, use:
   exit        to continue migration
   exit 1      to interrupt migration and RESTORE from backup

ERROR
    system($ENV{SHELL} // '/bin/sh') == 0 or die "migration interrupted\n";
    return;
}

sub _preprocess { ## no critic (ProhibitExcessComplexity)
    my @tokens = @_;
    my @op;
    my %macro;
    while (@tokens) {
        my $t = shift @tokens;
        if ($t->{op} =~ /\ADEFINE[24]?\z/ms) {
            die _e($t, "$t->{op} must have one param", "@{$t->{args}}") if 1 != @{$t->{args}};
            die _e($t, "bad name for $t->{op}", $t->{args}[0]) if $t->{args}[0] !~ /\A\S+\z/ms;
            die _e($t, "no data allowed for $t->{op}", $t->{data}) if $t->{data} ne q{};
            my $name = $t->{args}[0];
            die _e($t, "you can't redefine keyword '$name'") if KW->{$name};
            die _e($t, "'$name' is already defined") if $macro{$name};
            if ($t->{op} eq 'DEFINE') {
                die _e($t, 'need operation after DEFINE') if @tokens < DEFINE_TOKENS;
                my $t1 = shift @tokens;
                die _e($t1, 'first operation after DEFINE must be before_upgrade|upgrade|downgrade|after_downgrade', $t1->{op}) if !( KW_UP->{$t1->{op}} || KW_DOWN->{$t1->{op}} );
                $macro{$name} = [ $t1 ];
            }
            elsif ($t->{op} eq 'DEFINE2') {
                die _e($t, 'need two operations after DEFINE2') if @tokens < DEFINE2_TOKENS;
                my $t1 = shift @tokens;
                my $t2 = shift @tokens;
                die _e($t1,  'first operation after DEFINE2 must be before_upgrade|upgrade',      $t1->{op}) if !KW_UP->{$t1->{op}};
                die _e($t2, 'second operation after DEFINE2 must be downgrade|after_downgrade',   $t2->{op}) if !KW_DOWN->{$t2->{op}};
                $macro{$name} = [ $t1, $t2 ];
            }
            elsif ($t->{op} eq 'DEFINE4') {
                die _e($t, 'need four operations after DEFINE4') if @tokens < DEFINE4_TOKENS;
                my $t1 = shift @tokens;
                my $t2 = shift @tokens;
                my $t3 = shift @tokens;
                my $t4 = shift @tokens;
                die _e($t1,  'first operation after DEFINE4 must be before_upgrade',  $t1->{op}) if $t1->{op} ne 'before_upgrade';
                die _e($t2, 'second operation after DEFINE4 must be upgrade',         $t2->{op}) if $t2->{op} ne 'upgrade';
                die _e($t3,  'third operation after DEFINE4 must be downgrade',       $t3->{op}) if $t3->{op} ne 'downgrade';
                die _e($t4, 'fourth operation after DEFINE4 must be after_downgrade', $t4->{op}) if $t4->{op} ne 'after_downgrade';
                $macro{$name} = [ $t1, $t2, $t3, $t4 ];
            }
        }
        elsif (KW_VERSION->{$t->{op}}) {
            die _e($t, 'VERSION must have one param', "@{$t->{args}}") if 1 != @{$t->{args}};
            die _e($t, 'bad value for VERSION', $t->{args}[0])
                if $t->{args}[0] !~ /\A\S+\z/ms || $t->{args}[0] =~ /[\x00-\x1F\x7F \/?*`"’\\]/ms;
            die _e($t, 'no data allowed for VERSION', $t->{data}) if $t->{data} ne q{};
            push @op, {
                loc     => $t->{loc},
                op      => $t->{op},
                args    => [ $t->{args}[0] ],
            };
        }
        elsif (KW_RESTORE->{$t->{op}}) {
            die _e($t, 'RESTORE must have no params', "@{$t->{args}}") if 0 != @{$t->{args}};
            die _e($t, 'no data allowed for RESTORE', $t->{data}) if $t->{data} ne q{};
            push @op, {
                loc     => $t->{loc},
                op      => $t->{op},
                args    => [],
            };
        }
        elsif (KW_UP->{$t->{op}} || KW_DOWN->{$t->{op}}) {
            die _e($t, "$t->{op} require command or data") if !@{$t->{args}} && $t->{data} !~ /\S/ms;
            push @op, {
                loc     => $t->{loc},
                op      => $t->{op},
                args    => [
                    @{$t->{args}}           ? (@{$t->{args}}, _data2arg($t->{data}))
                  :                           _shebang($t->{data})
                ],
            };
        }
        elsif ($macro{ $t->{op} }) {
            for (@{ $macro{ $t->{op} } }) {
                my @args
                  = @{$_->{args}}           ? (@{$_->{args}}, _data2arg($_->{data}))
                  : $_->{data} =~ /\S/ms    ? _shebang($_->{data})
                  :                           ()
                  ;
                @args
                  = @args                   ? (@args, @{$t->{args}}, _data2arg($t->{data}))
                  : @{$t->{args}}           ? (@{$t->{args}}, _data2arg($t->{data}))
                  : $t->{data} =~ /\S/ms    ? _shebang($t->{data})
                  :                           ()
                  ;
                die _e($t, "$t->{op} require command or data") if !@args;
                push @op, {
                    loc     => $t->{loc},
                    op      => $_->{op},
                    args    => \@args,
                };
            }
        }
        else {
            croak "Internal error: bad op $t->{op}";
        }
    }
    return @op;
}

sub _shebang {
    my ($script) = @_;
    return $script =~ /\A#!/ms ? $script : "#!/bin/bash -ex\n$script";
}

sub _tokenize {
    my ($fh, $loc) = @_;
    state $QUOTED = {
        q{\\}   => q{\\},
        q{"}    => q{\"},
        'n'     => "\n",
        'r'     => "\r",
        't'     => "\t",
    };
    my @tokens;
    while (<$fh>) {
        $loc->{line}++;
        if (/\A#/ms) {
            # skip comments
        }
        elsif (/\A(\S+)\s*(.*)\z/ms) {
            # parse token's op and args
            my ($op, $args) = ($1, $2);
            my @args;
            while ($args =~ /\G([^\s"\\]+|"[^"\\]*(?:\\[\\"nrt][^"\\]*)*")(?:\s+|\z)/msgc) {
                my $param = $1;
                if ($param =~ s/\A"(.*)"\z/$1/ms) {
                    $param =~ s/\\([\\"nrt])/$QUOTED->{$1}/msg;
                }
                push @args, $param;
            }
            die _e($loc, 'bad operation param', $1) if $args =~ /\G(.+)\z/msgc; ## no critic (ProhibitCaptureWithoutTest)
            push @tokens, {
                loc => $loc,
                op  => $op,
                args=> \@args,
                data=> q{},
            };
        }
        elsif (/\A(?:\r?\n|[ ][ ].*)\z/ms) {
            if (@tokens) {
                $tokens[-1]{data} .= $_;
            }
            elsif (/\S/ms) {
                die _e($loc, 'data before operation', $_);
            }
            else {
                # skip /^\s*$/ before first token
            }
        }
        else {
            die _e($loc, 'bad token', $_);
        }
    }
    # post-process data
    for (@tokens) {
        $_->{data} =~ s/(\A(?:.*?\n)??)(?:\r?\n)*\z/$1/ms;
        $_->{data} =~ s/^[ ][ ]//msg;
    }
    return @tokens;
}


1; # Magic true value required at end of module
__END__

=encoding utf8

=head1 NAME

App::migrate - upgrade / downgrade project


=head1 VERSION

This document describes App::migrate version v0.1.0


=head1 SYNOPSIS

    use App::migrate;

    my $migrate = App::migrate->new()
    $migrate = $migrate->load($file)

    @paths   = $migrate->find_paths($v_from => $v_to)
    say "versions: @{$_}" for @paths;

    @steps   = $migrate->get_steps($paths[0])
    for (@steps) {
      say "$_->{prev_version} ... $_->{next_version}";
      if ($_->{type} eq 'VERSION' or $_->{type} eq 'RESTORE') {
          say "$_->{type} $_->{version}";
      } else {
          say "$_->{type} $_->{cmd} @{$_->{args}}";
      }
    }

    # - BACKUP: before start any new migration except next one after RESTORE
    # - VERSION: after finished migration
    # - die in BACKUP/RESTORE/VERSION result in calling error
    # - die in error will interrupt migration and RESTORE from backup
    # - $ENV{MIGRATE_PREV_VERSION}
    # - $ENV{MIGRATE_NEXT_VERSION}
    $migrate = $migrate->on(BACKUP  => sub{ my $step=shift; return or die });
    $migrate = $migrate->on(RESTORE => sub{ my $step=shift; return or die });
    $migrate = $migrate->on(VERSION => sub{ my $step=shift; return or die });
    $migrate = $migrate->on(error   => sub{ my $step=shift; return or die });
    $migrate->run($paths[0]);


=head1 DESCRIPTION

If you're looking for command-line tool - see L<migrate>. This module is
actual implementation of that tool's functionality and you'll need it only
if you're developing similar tool (like L<narada-install>) to implement
specifics of your project in single perl script instead of using several
external scripts.

This module implements file format (see L</"SYNTAX">) to describe sequence
of upgrade and downgrade operations needed to migrate I<something> between
different versions, and API to analyse and run these operations.

The I<something> mentioned above is usually some project, but it can be
literally anything - OS configuration in /etc, or overall OS setup
including installed packages, etc. - anything what has versions and need
complex operations to upgrade/downgrade between these versions.
For example, to migrate source code you can use VCS like Git or Mercurial,
but they didn't support empty directories, file permissions (except
executable), non-plain file types (fifo, UNIX socket, etc.), xattr, ACL,
configuration files which must differ on each site, and databases. So, if
you need to migrate anything isn't supported by VCS - you can try this
module/tool.

Sometimes it isn't possible to really downgrade because some data was lost
while upgrade - to handle these situations you should provide a ways to
create complete backup of your project and restore any project's version
from these backups while downgrade (of course, restoring backups will
result in losing new changes, so whenever possible it's better to do some
extra work to provide a way to downgrade without losing any data).

=head2 Example

Here is example how to run migration from version '1.1.8' to '1.2.3' of
some project which uses even minor versions '1.0.x' and '1.2.x' for stable
releases and odd minor versions '1.1.x' for unstable releases. The nearest
common version between '1.1.8' and '1.2.3' is '1.0.42', which was the
parent for both '1.1.x' and '1.2.x' branches, so we need to downgrade
project from '1.1.8' to '1.0.42' first, and then upgrade from '1.0.42' to
'1.2.3'. You'll need two C<*.migrate> files, one which describe migrations
from '1.0.42' (or earlier version) to '1.1.8', and another with migrations
from '1.0.42' (or earlier) to '1.2.3'. For brevity let's not make any
backups while migration.

    my $migrate = App::migrate
        ->new
        ->load('1.1.8.migrate')
        ->load('1.2.3.migrate');
    $migrate
        ->on(BACKUP => sub {})
        ->run( $migrate->find_paths('1.1.8' => '1.2.3') );


=head1 INTERFACE

=over

=item new

    $migrate = App::migrate->new;

=item load

    $migrate->load('path/to/migrate');

TODO

=item find_paths

    @paths = $migrate->find_paths($from_version => $to_version);

TODO

=item get_steps

    @steps = $migrate->get_steps( \@versions );

TODO

=item on

    $migrate = $migrate->on(BACKUP  => \&your_handler);
    $migrate = $migrate->on(RESTORE => \&your_handler);
    $migrate = $migrate->on(VERSION => \&your_handler);
    $migrate = $migrate->on(error   => \&your_handler);

TODO

=item run

    $migrate->run( \@versions );

TODO

=back


=head1 SYNTAX

Syntax of this file was designed to accomplish several goals:

=over

=item *

Be able to automatically make sure each 'upgrade' operation has
corresponding 'downgrade' operation (so it won't be forget - but, of
course, it's impossible to automatically check is 'downgrade' operation
will correctly undo effect of 'upgrade' operation).

I<Thus custom file format is needed.>

=item *

Make it easier to manually analyse is 'downgrade' operation looks correct
for corresponding 'upgrade' operation.

I<Thus related 'upgrade' and 'downgrade' operations must go one right
after another.>

=item *

Make it obvious some version can't be downgraded and have to be restored
from backup.

I<Thus RESTORE operation is named in upper case.>

=item *

Given all these requirements try to make it simple and obvious to define
migrate operations, without needs to write downgrade code for typical
cases.

I<Thus it's possible to define macro to turn combination of
upgrade/downgrade operations into one user-defined operation (no worries
here: these macro doesn't support recursion, it isn't possible to redefine
them, and they have lexical scope - from definition to the end of this
file - so they won't really add complexity).>

=back

Example:

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


=head1 SUPPORT

=head2 Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at L<https://github.com/powerman/migrate/issues>.
You will be notified automatically of any progress on your issue.

=head2 Source Code

This is open source software. The code repository is available for
public review and contribution under the terms of the license.
Feel free to fork the repository and submit pull requests.

L<https://github.com/powerman/migrate>

    git clone https://github.com/powerman/migrate.git

=head2 Resources

=over

=item * MetaCPAN Search

L<https://metacpan.org/search?q=App-migrate>

=item * CPAN Ratings

L<http://cpanratings.perl.org/dist/App-migrate>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/App-migrate>

=item * CPAN Testers Matrix

L<http://matrix.cpantesters.org/?dist=App-migrate>

=item * CPANTS: A CPAN Testing Service (Kwalitee)

L<http://cpants.cpanauthors.org/dist/App-migrate>

=back


=head1 AUTHOR

Alex Efros E<lt>powerman@cpan.orgE<gt>


=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2015 by Alex Efros E<lt>powerman@cpan.orgE<gt>.

This is free software, licensed under:

  The MIT (X11) License


=cut
