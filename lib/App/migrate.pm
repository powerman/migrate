package App::migrate;

use 5.010001;
use warnings;
use strict;
use utf8;
use Carp;

our $VERSION = 'v0.1.0';

use List::Util qw( first any );
use File::Temp qw( tempfile );

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
    my ($self, $to, @from) = @_;
    my $p = $self->{paths}{ $from[-1] } || {};
    return [@from, $to] if $p->{$to};
    my %seen = map {$_=>1} @from;
    return map {$self->find_paths($to,@from,$_)} grep {!$seen{$_}} keys %{$p};
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

    my $fh = path($file)->openr_utf8;
    my @op = _preprocess(_tokenize($fh, { file => $file, line => 0 }));
    close $fh or croak "close($file): $!\n";

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
            croak _e($op, "need VERSION before $op->{op}") if $prev_version eq q{};
            my ($cmd1, @args1) = @{ $op->{args} };
            push @steps, {
                type            => $op->{op},
                cmd             => $cmd1,
                args            => \@args1,
            };
            croak _e($op, "need RESTORE|downgrade|after_downgrade after $op->{op}")
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
            croak _e($op, "need before_upgrade|upgrade before $op->{op}");
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
        if ($from) {
            $self->_do({
                type            => 'BACKUP',    # internal step type
                version         => $from,
                prev_version    => $from,
                next_version    => $path[-1],
            });
        }
    };
    return;
}

sub _data2arg {
    my ($data) = @_;

    return if $data eq q{};

    my ($fh, $filename) = tempfile('migrate.XXXXXX', TMPDIR=>1, UNLINK=>1);
    print {$fh} $data;
    close $fh or croak "close($filename): $!\n";

    return $filename;
}

sub _do {
    my ($self, $step) = @_;
    local $ENV{MIGRATE_PREV_VERSION} = $step->{prev_version};
    local $ENV{MIGRATE_NEXT_VERSION} = $step->{prev_version};
    eval {
        if ($step->{type} eq 'BACKUP' or $step->{type} eq 'RESTORE' or $step->{type} eq 'VERSION') {
            $self->{on}{ $step->{type} }->($step);
        }
        else {
            my $cmd = $step->{cmd};
            if ($cmd =~ /\A#!/ms) {
                $cmd = _data2arg($cmd);
                chmod 0700, $cmd or croak "chmod($cmd): $!\n"; ## no critic (ProhibitMagicNumbers)
            }
            system($cmd, @{ $step->{args} }) == 0 or croak "$step->{type} failed: $cmd @{ $step->{args} }\n";
            print "\n";
        }
        1;
    }
    or $self->{on}{error}->($step);
    return;
}

sub _e {
    my ($loc, $msg, $near) = @_;
    return "parse error: $msg at $loc->{file}:$loc->{line}"
      . ($near eq q{} ? "\n" : " near '$near'\n");
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
    say 'YOU NEED TO MANUALLY FIX THIS ISSUE RIGHT NOW';
    say 'When done, use:';
    say '   exit        to continue migration';
    say '   exit 1      to interrupt migration and RESTORE from backup';
    system($ENV{SHELL} // '/bin/sh') == 0 or croak "migration interrupted\n";
    return;
}

sub _preprocess { ## no critic (ProhibitExcessComplexity)
    my @tokens = @_;
    my @op;
    my %macro;
    while (@tokens) {
        my $t = shift @tokens;
        if ($t->{op} =~ /\ADEFINE[24]?\z/ms) {
            croak _e($t, "$t->{op} must have one param", "@{$t->{args}}") if 1 != @{$t->{args}};
            croak _e($t, "bad name for $t->{op}", $t->{args}[0]) if $t->{args}[0] !~ /\A\S+\z/ms;
            croak _e($t, "no data allowed for $t->{op}", $t->{data}) if $t->{data} ne q{};
            my $name = $t->{args}[0];
            croak _e($t, "you can't redefine keyword '$name'") if KW->{$name};
            croak _e($t, "'$name' is already defined") if $macro{$name};
            if ($t->{op} eq 'DEFINE') {
                croak _e($t, 'need operation after DEFINE') if @tokens < DEFINE_TOKENS;
                my $t1 = shift @tokens;
                croak _e($t1, 'first operation after DEFINE must be before_upgrade|upgrade|downgrade|after_downgrade', $t1->{op}) if !( KW_UP->{$t1->{op}} || KW_DOWN->{$t1->{op}} );
                $macro{$name} = [ $t1 ];
            }
            elsif ($t->{op} eq 'DEFINE2') {
                croak _e($t, 'need two operations after DEFINE2') if @tokens < DEFINE2_TOKENS;
                my $t1 = shift @tokens;
                my $t2 = shift @tokens;
                croak _e($t1,  'first operation after DEFINE2 must be before_upgrade|upgrade',      $t1->{op}) if !KW_UP->{$t1->{op}};
                croak _e($t2, 'second operation after DEFINE2 must be downgrade|after_downgrade',   $t2->{op}) if !KW_DOWN->{$t2->{op}};
                $macro{$name} = [ $t1, $t2 ];
            }
            elsif ($t->{op} eq 'DEFINE4') {
                croak _e($t, 'need four operations after DEFINE4') if @tokens < DEFINE4_TOKENS;
                my $t1 = shift @tokens;
                my $t2 = shift @tokens;
                my $t3 = shift @tokens;
                my $t4 = shift @tokens;
                croak _e($t1,  'first operation after DEFINE4 must be before_upgrade',  $t1->{op}) if $t1->{op} ne 'before_upgrade';
                croak _e($t2, 'second operation after DEFINE4 must be upgrade',         $t2->{op}) if $t2->{op} ne 'upgrade';
                croak _e($t3,  'third operation after DEFINE4 must be downgrade',       $t3->{op}) if $t3->{op} ne 'downgrade';
                croak _e($t4, 'fourth operation after DEFINE4 must be after_downgrade', $t4->{op}) if $t4->{op} ne 'after_downgrade';
                $macro{$name} = [ $t1, $t2, $t3, $t4 ];
            }
        }
        elsif (KW_VERSION->{$t->{op}}) {
            croak _e($t, 'VERSION must have one param', "@{$t->{args}}") if 1 != @{$t->{args}};
            croak _e($t, 'bad value for VERSION', $t->{args}[0])
                if $t->{args}[0] !~ /\A\S+\z/ms || $t->{args}[0] =~ /[\x00-\x1F\x7F \/?*`"’\\]/ms;
            croak _e($t, 'no data allowed for VERSION', $t->{data}) if $t->{data} ne q{};
            push @op, {
                loc     => $t->{loc},
                op      => $t->{op},
                args    => [ $t->{args}[0] ],
            };
        }
        elsif (KW_RESTORE->{$t->{op}}) {
            croak _e($t, 'RESTORE must have no params', "@{$t->{args}}") if 0 != @{$t->{args}};
            croak _e($t, 'no data allowed for RESTORE', $t->{data}) if $t->{data} ne q{};
            push @op, {
                loc     => $t->{loc},
                op      => $t->{op},
                args    => [],
            };
        }
        elsif (KW_UP->{$t->{op}} || KW_DOWN->{$t->{op}}) {
            croak _e($t, "$t->{op} require command or data") if !@{$t->{args}} && $t->{data} !~ /\S/ms;
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
                croak _e($t, "$t->{op} require command or data") if !@args;
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
            croak _e($loc, 'bad operation param', $1) if $args =~ /\G(.+)\z/msgc; ## no critic (ProhibitCaptureWithoutTest)
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
                croak _e($loc, 'data before operation', $_);
            }
            else {
                # skip /^\s*$/ before first token
            }
        }
        else {
            croak _e($loc, 'bad token', $_);
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
    @paths   = $migrate->find_paths($v_to, $v_from)
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
    $migrate = $migrate->on(BACKUP  => sub{my$step=shift;return or die})
    $migrate = $migrate->on(RESTORE => sub{my$step=shift;return or die})
    $migrate = $migrate->on(VERSION => sub{my$step=shift;return or die})
    $migrate = $migrate->on(error   => sub{my$step=shift;return or die})
    $migrate->run($paths[0])


=head1 DESCRIPTION

TODO


=head1 INTERFACE

=over

=item new

    my $migrate = App::migrate->new;

TODO

=back


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
