use strict;
use warnings;
use Test::More;
use SQL::Wizard;

my $q = SQL::Wizard->new;

# simple truncate
{
  my ($sql, @bind) = $q->truncate(-table => 'users')->to_sql;
  is $sql, 'TRUNCATE TABLE users', 'truncate';
  is_deeply \@bind, [], 'truncate no binds';
}

# schema-qualified
{
  my ($sql, @bind) = $q->truncate(-table => 'public.users')->to_sql;
  is $sql, 'TRUNCATE TABLE public.users', 'truncate schema.table';
}

# requires -table
{
  eval { $q->truncate()->to_sql };
  like $@, qr/truncate requires -table/, 'truncate requires table';
}

# rejects invalid table name
{
  eval { $q->truncate(-table => 'users; DROP TABLE x')->to_sql };
  like $@, qr/Invalid table name/, 'truncate rejects bad table';
}

done_testing;
