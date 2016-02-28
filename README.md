[![Build Status](https://travis-ci.org/powerman/migrate.svg?branch=master)](https://travis-ci.org/powerman/migrate)
[![Coverage Status](https://coveralls.io/repos/powerman/migrate/badge.svg?branch=master)](https://coveralls.io/r/powerman/migrate?branch=master)

# NAME

App::migrate - upgrade / downgrade project

# VERSION

This document describes App::migrate version v0.2.3

# SYNOPSIS

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
        ->run( $migrate->find_paths('1.1.8' => '1.2.3') );

# INTERFACE

## new

    $migrate = App::migrate->new;

Create and return new App::migrate object.

## load

    $migrate->load('path/to/migrate');

Load migration commands into `$migrate` object.

You should load at least one file with migration commands before you can
use ["find\_paths"](#find_paths), ["get\_steps"](#get_steps) or ["run"](#run).

When loading multiple files, if they contain two adjoining 'VERSION'
operations with same version values then migration commands between these
two version values will be used from first loaded file containing these
version values.

Will throw if given file's contents don't conform to ["Specification"](#specification) -
this may be used to check file's syntax.

## find\_paths

    @paths = $migrate->find_paths($from_version => $to_version);

Find and return all possible paths to migrate between given versions.

If no paths found - return empty list. This may happens because you didn't
loaded migrate files which contain required migrations or because there is
no way to migrate between these versions (for example, if one of given
versions is incorrect).

Multiple paths can be found, for example, when your project had some
branches which was later merged.

Each found path returned as single ARRAYREF element in returned list.
This ARRAYREF contains list of all intermediate versions, one by one,
starting from `$from_version` and ending with `$to_version`.

For example, if our project have this version history:

        1.0.0
          |
        1.0.42
         / \
    1.1.0   1.2.0
      |       |
    1.1.8   1.2.3
      | \     |
      |  \----|
    1.1.9   1.2.4
      |       |
    1.1.10  1.2.5

then you'll probably have these migrate files:

    1.1.10.migrate          1.0.0->…->1.0.42->1.1.0->…->1.1.10
    1.2.5.migrate           1.0.0->…->1.0.42->1.2.0->…->1.2.3->1.2.4->1.2.5
    1.1.8-1.2.4.migrate     1.0.0->…->1.0.42->1.1.0->…->1.1.8->1.2.4

If you ["load"](#load) files `1.2.5.migrate` and `1.1.8-1.2.4.migrate` and
then call `find_paths('1.0.42' => '1.2.5')`, then it will return
this list with two paths (in any order):

    (
        ['1.0.42', '1.1.0', …, '1.1.8', '1.2.4', '1.2.5'],
        ['1.0.42', '1.2.0', …, '1.2.3', '1.2.4', '1.2.5'],
    )

## get\_steps

    @steps = $migrate->get_steps( \@versions );

Return list of all migration operations needed to migrate on path given in
`@versions`.

For example, to get steps for first path returned by ["find\_paths"](#find_paths):

    @steps = $migrate->get_steps( $migrate->find_paths($from=>$to) );

Steps returned in order they'll be executed while ["run"](#run) for this path.
Each element in `@steps` is a HASHREF with these keys:

    type    => one of these values:
                'VERSION', 'before_upgrade', 'upgrade',
                'downgrade', 'after_downgrade', 'RESTORE'

    # these keys exists only if value of type key is one of:
    #   VERSION, RESTORE
    version => version number

    # these keys exists only if value of type key is one of:
    #   before_upgrade, upgrade, downgrade, after_downgrade
    cmd     => command to run
    args    => ARRAYREF of params for that command

Will throw if unable to return requested steps.

## on

    $migrate = $migrate->on(BACKUP  => \&your_handler);
    $migrate = $migrate->on(RESTORE => \&your_handler);
    $migrate = $migrate->on(VERSION => \&your_handler);
    $migrate = $migrate->on(error   => \&your_handler);

Set handler for given event.

All handlers will be called only by ["run"](#run); they will get single
parameter - step HASHREF (BACKUP handler will get step in same format as
RESTORE), see ["get\_steps"](#get_steps) for details of that HASHREF contents.
Also these handlers may use `$ENV{MIGRATE_PREV_VERSION}` and
`$ENV{MIGRATE_NEXT_VERSION}` - see ["run"](#run) for more details.

- 'BACKUP' event

    Handler will be executed when project backup should be created: before
    starting any new migration, except next one after RESTORE.

    If handler throws then 'error' handler will be executed.

    Default handler will throw (because it doesn't know how to backup your
    project).

    NOTE: If you'll use handler which doesn't really create and keep backups
    for all versions then it will be impossible to do RESTORE operation.

- 'RESTORE' event

    Handler will be executed when project should be restored from backup: when
    downgrading between versions which contain RESTORE operation or when
    migration fails.

    If handler throws then 'error' handler will be executed.

    Default handler will throw (because it doesn't know how to restore your
    project).

- 'VERSION' event

    Handler will be executed after each successful migration.

    If handler throws then 'error' handler will be executed.

    Default handler does nothing.

- 'error' event

    Handler will be executed when one of commands executed while migration
    fails or when BACKUP, RESTORE or VERSION handlers throw.

    If handler throws then try to restore version-before-migration (without
    calling error handler again if it throws too).

    Default handler will run $SHELL (to let you manually fix errors) and throw
    if you $SHELL exit status != 0 (to let you choose what to do next -
    continue migration if you fixed error or interrupt migration to restore
    version-before-migration from backup).

## run

    $migrate->run( \@versions );

Will use ["get\_steps"](#get_steps) to get steps for path given in `@versions` and
execute them in order. Will also call handlers as described in ["on"](#on).

Before executing each step will set `$ENV{MIGRATE_PREV_VERSION}` to
current version (which it will migrate from) and
`$ENV{MIGRATE_NEXT_VERSION}` to version it is trying to migrate to.

# SYNTAX

## Goals

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

## Example

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
    downgrade true

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

## Specification

Recommended name for file with upgrade/downgrade operations is either
`migrate` or `<version>.migrate`.

Each line in migrate file must be one of these:

- line start with symbol "#"

    For comments. Line is ignored.

- line start with any non-space symbol, except "#"

    Contain one or more elements separated by one or more space symbols:
    operation name (case-sensitive), zero or more params (any param may be
    quoted, params which contain one of 5 symbols "\\\\\\"\\t\\r\\n" must be
    quoted).

    Quoted params must be surrounded by double-quote symbol, and any of
    mentioned above 5 symbols must be escaped like shown above.

- line start with two spaces

    Zero or more such lines after line with operation name form one more,
    multiline, extra param for that operation (first two spaces will be
    removed from start of each line before providing this param to operation).

    Not all operations may have such multiline param.

- empty line

    If this line is between operations then it's ignored.

    If this line is inside operation's multiline param - then that multiline
    param will include this empty line.

    If you will need to include empty line at end of multiline param then
    you'll have to use line with two spaces instead.

While executing any commands two environment variables will be set:
`$MIGRATE_PREV_VERSION` and `$MIGRATE_NEXT_VERSION` (first is always
version we're migrating from, and second is always version we're migrating
to - i.e. while downgrading `$MIGRATE_NEXT_VERSION` will be lower/older
version than `$MIGRATE_PREV_VERSION`)

All executed commands must complete without error, otherwise emergency
shell will be started and user should either fix the error and `exit`
from shell to continue migration, or `exit 1` from shell to interrupt
migration and restore previous-before-this-migration version from backup.

## Supported operations

### VERSION

Must have exactly one param (version number). Some symbols are not allowed
in version numbers: special (0x00-0x1F,0x7F), both slash, all three
quotes, ?, \* and space.

Multiline param not supported.

This is delimiter between sequences of migrate operations.

Each file must contain 'VERSION' operation before any migrate operations
(i.e. before first 'VERSION' operation only 'DEFINE', 'DEFINE2' and
'DEFINE4' operations are allowed).

All operations after last 'VERSION' operation will be ignored.

### before\_upgrade

### upgrade

### downgrade

### after\_downgrade

These operations must be always used in pairs: first must be one of
'before\_upgrade' or 'upgrade' operation, second must be one of 'downgrade'
or 'after\_downgrade' or 'RESTORE' operations.

These four operations may have zero or more params and optional multiline
param. If they won't have any params at all they'll be processed like they
have one (empty) multiline param.

Their params will be executed as a single shell command at different
stages of migration process and in different order:

- On each migration only commands between two nearest VERSION operations
will be processed.
- On upgrading (migrate forward from previous VERSION to next VERSION) will
be executed all 'before\_upgrade' operations in forward order then all
'upgrade' operations in forward order.
- On downgrading (migrate backward from next VERSION to previous) will be
executed all 'downgrade' operations in backward order, then all
'after\_downgrade' operations in backward order.

Shell command to use will be:

- If operation has one or more params - first param will become executed
command name, other params will become command params.

    If operation also has multiline param then it content will be saved into
    temporary file and name of that file will be added at end of command's
    params.

- Else multiline param will be saved into temporary file (after shebang
`#!/path/to/bash -ex` if first line of multiline param doesn't start with
`#!`), which will be made executable and run without any params.

### RESTORE

Doesn't support any params, neither usual nor multiline.

Can be used only after 'before\_upgrade' or 'upgrade' operations.

When one or more 'RESTORE' operations are used between some 'VERSION'
operations then all 'downgrade' and 'after\_downgrade' operations between
same 'VERSION' operations will be ignored and on downgrading previous
version will be restored from backup.

### DEFINE

This operation must have only one non-multiline param - name of defined
macro. This name must not be same as one of existing operation names, both
documented here or created by one of previous 'DEFINE' or 'DEFINE2' or
'DEFINE4' operations.

Next operation must be one of 'before\_upgrade', 'upgrade', 'downgrade' or
'after\_downgrade' - it will be substituted in place of all next operations
matching name of this macro.

When substituting macro it may happens what both this macro definition
have some normal params and multiline param, and substituted operation
also have some it's own normal params and multiline param. All these
params will be combined into single command and it params in this way:

- If macro definition doesn't have any params - params of substituted
operation will be handled as usually for 'upgrade' etc. operations.
- If macro definition have some params - they will be handled as usually for
'upgrade' etc. operations, so we'll always get some command and optional
params for it.

    Next, all normal params of substituted command (if any) will be appended
    to that command params.

    Next, if substituted command have multiline param then it will be saved to
    temporary file and name of that file will be appended to that command
    params.

### DEFINE2

Work similar to DEFINE, but require two next operations after it: first
must be one of 'before\_upgrade' or 'upgrade', and second must be one of
'downgrade' or 'after\_downgrade'.

Params of both operations will be combined with params of substituted
operation as explained above.

### DEFINE4

Work similar to DEFINE, but require four next operations after it: first
must be 'before\_upgrade', second - 'upgrade', third - 'downgrade', fourth
\- 'after\_downgrade'.

Params of all four operations will be combined with params of substituted
operation as explained above.

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

Alex Efros &lt;powerman@cpan.org>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2015- by Alex Efros &lt;powerman@cpan.org>.

This is free software, licensed under:

    The MIT (X11) License
