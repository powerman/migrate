# NAME

App::Migrate - upgrade / downgrade project

# VERSION

This document describes App::Migrate version v0.1.0

# SYNOPSIS

    use App::Migrate;

    my $migrate = App::Migrate->new()
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

# DESCRIPTION

TODO

# INTERFACE

- new

        my $migrate = App::Migrate->new;

    TODO

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

    [https://metacpan.org/search?q=App-Migrate](https://metacpan.org/search?q=App-Migrate)

- CPAN Ratings

    [http://cpanratings.perl.org/dist/App-Migrate](http://cpanratings.perl.org/dist/App-Migrate)

- AnnoCPAN: Annotated CPAN documentation

    [http://annocpan.org/dist/App-Migrate](http://annocpan.org/dist/App-Migrate)

- CPAN Testers Matrix

    [http://matrix.cpantesters.org/?dist=App-Migrate](http://matrix.cpantesters.org/?dist=App-Migrate)

- CPANTS: A CPAN Testing Service (Kwalitee)

    [http://cpants.cpanauthors.org/dist/App-Migrate](http://cpants.cpanauthors.org/dist/App-Migrate)

# AUTHOR

Alex Efros <powerman@cpan.org>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2015 by Alex Efros <powerman@cpan.org>.

This is free software, licensed under:

    The MIT (X11) License
