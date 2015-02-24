[![Build Status](https://travis-ci.org/powerman/migrate.svg?branch=master)](https://travis-ci.org/powerman/migrate)
[![Coverage Status](https://coveralls.io/repos/powerman/migrate/badge.png?branch=master)](https://coveralls.io/r/powerman/migrate?branch=master)

# NAME

App::migrate - upgrade / downgrade project

# VERSION

This document describes App::migrate version v0.1.0

# SYNOPSIS

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
    $migrate = $migrate->on(BACKUP  => sub{ my $step=shift; return or die });
    $migrate = $migrate->on(RESTORE => sub{ my $step=shift; return or die });
    $migrate = $migrate->on(VERSION => sub{ my $step=shift; return or die });
    $migrate = $migrate->on(error   => sub{ my $step=shift; return or die });
    $migrate->run($paths[0]);

# DESCRIPTION

If you're looking for command-line tool - see [migrate](https://metacpan.org/pod/migrate). This module is
actual implementation of that tool's functionality and you'll need it only
if you're developing similar tool (like [narada-install](https://metacpan.org/pod/narada-install)) to implement
specifics of your project in single perl script instead of using several
external scripts.

This module implements file format (see ["SYNTAX"](#syntax)) to describe sequence
of upgrade and downgrade operations needed to migrate _something_ between
different versions, and API to analyse and run these operations.

The _something_ mentioned above is usually some project, but it can be
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

## Example

Here is example how to run migration from version '1.1.8' to '1.2.3' of
some project which uses even minor versions '1.0.x' and '1.2.x' for stable
releases and odd minor versions '1.1.x' for unstable releases. The nearest
common version between '1.1.8' and '1.2.3' is '1.0.42', which was the
parent for both '1.1.x' and '1.2.x' branches, so we need to downgrade
project from '1.1.8' to '1.0.42' first, and then upgrade from '1.0.42' to
'1.2.3'. You'll need two `*.migrate` files, one which describe migrations
from '1.0.42' (or earlier version) to '1.1.8', and another with migrations
from '1.0.42' (or earlier) to '1.2.3'. For brevity let's not make any
backups while migration.

    my $migrate = App::migrate
        ->new
        ->load('1.1.8.migrate')
        ->load('1.2.3.migrate');
    $migrate
        ->on(BACKUP => sub {})
        ->run( $migrate->find_paths('1.2.3', '1.1.8') );

# INTERFACE

- new

        $migrate = App::migrate->new;

- load

        $migrate->load('path/to/migrate');

    TODO

- find\_paths

        @paths = $migrate->find_paths($to_version, $from_version);

    TODO

- get\_steps

        @steps = $migrate->get_steps( \@versions );

    TODO

- on

        $migrate = $migrate->on(BACKUP  => \&your_handler);
        $migrate = $migrate->on(RESTORE => \&your_handler);
        $migrate = $migrate->on(VERSION => \&your_handler);
        $migrate = $migrate->on(error   => \&your_handler);

    TODO

- run

        $migrate->run( \@versions );

    TODO

# SYNTAX

Syntax of this file was designed to accomplish several goals:

- Be able to automatically make sure each 'upgrade' operation has
corresponding 'downgrade' operation (so it won't be forget - but, of
course, it's impossible to automatically check is 'downgrade' operation
will correctly undo effect of 'upgrade' operation).

    _Thus custom file format is needed._

- Make it easier to manually analyse is 'downgrade' operation looks correct
for corresponding 'upgrade' operation.

    _Thus related 'upgrade' and 'downgrade' operations must go one right
    after another._

- Make it obvious some version can't be downgraded and have to be restored
from backup.

    _Thus RESTORE operation is named in upper case._

- Given all these requirements try to make it simple and obvious to define
migrate operations, without needs to write downgrade code for typical
cases.

    _Thus it's possible to define macro to turn combination of
    upgrade/downgrade operations into one user-defined operation (no worries
    here: these macro doesn't support recursion, it isn't possible to redefine
    them, and they have lexical scope - from definition to the end of this
    file - so they won't really add complexity)._

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

# SUPPORT

## Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at [https://github.com/powerman/migrate/issues](https://github.com/powerman/migrate/issues).
You will be notified automatically of any progress on your issue.

## Source Code

This is open source software. The code repository is available for
public review and contribution under the terms of the license.
Feel free to fork the repository and submit pull requests.

[https://github.com/powerman/migrate](https://github.com/powerman/migrate)

    git clone https://github.com/powerman/migrate.git

## Resources

- MetaCPAN Search

    [https://metacpan.org/search?q=App-migrate](https://metacpan.org/search?q=App-migrate)

- CPAN Ratings

    [http://cpanratings.perl.org/dist/App-migrate](http://cpanratings.perl.org/dist/App-migrate)

- AnnoCPAN: Annotated CPAN documentation

    [http://annocpan.org/dist/App-migrate](http://annocpan.org/dist/App-migrate)

- CPAN Testers Matrix

    [http://matrix.cpantesters.org/?dist=App-migrate](http://matrix.cpantesters.org/?dist=App-migrate)

- CPANTS: A CPAN Testing Service (Kwalitee)

    [http://cpants.cpanauthors.org/dist/App-migrate](http://cpants.cpanauthors.org/dist/App-migrate)

# AUTHOR

Alex Efros <powerman@cpan.org>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2015 by Alex Efros <powerman@cpan.org>.

This is free software, licensed under:

    The MIT (X11) License
