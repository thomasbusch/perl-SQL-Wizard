use strict;
use warnings;
use Test::More;
use SQL::Wizard;

# Simple lowercase identifiers: no quoting
{
  my $q = SQL::Wizard->new;

  {
    my ($sql) = $q->select(-columns => ['id', 'name'], -from => 'users')->to_sql;
    is $sql, 'SELECT id, name FROM users', 'lowercase: no quotes';
  }

  {
    my ($sql) = $q->select(-columns => ['u.id'], -from => 'users|u')->to_sql;
    is $sql, 'SELECT u.id FROM users u', 'dotted lowercase: no quotes';
  }

  {
    my ($sql) = $q->col('name')->to_sql;
    is $sql, 'name', 'col() lowercase: no quotes';
  }

  {
    my ($sql) = $q->func('COUNT', '*')->as('total')->to_sql;
    is $sql, 'COUNT(*) AS total', 'as() lowercase: no quotes';
  }
}

# Reserved words: quoted
{
  my $q = SQL::Wizard->new;

  {
    my ($sql) = $q->select(-from => 'users', -where => { 'key' => 'val' })->to_sql;
    like $sql, qr/"key" = \?/, 'reserved word key: quoted';
  }

  {
    my ($sql) = $q->select(-from => 'users', -order_by => 'order')->to_sql;
    like $sql, qr/ORDER BY "order"/, 'reserved word order: quoted in order_by';
  }

  {
    my ($sql) = $q->select(-from => 'users', -group_by => 'group')->to_sql;
    like $sql, qr/GROUP BY "group"/, 'reserved word group: quoted in group_by';
  }

  {
    my ($sql) = $q->select(-from => 'users', -where => { 'table' => 'foo' })->to_sql;
    like $sql, qr/"table" = \?/, 'reserved word table: quoted in where';
  }

  {
    my ($sql) = $q->insert(-into => 'counters', -values => { 'key' => 'hits', value => 1 })->to_sql;
    like $sql, qr/\("key", value\)/, 'reserved key quoted in insert cols';
  }

  {
    my ($sql) = $q->update(-table => 'users', -set => { 'column' => 'x' }, -where => { id => 1 })->to_sql;
    like $sql, qr/SET "column" = \?/, 'reserved column: quoted in SET';
  }

  {
    my ($sql) = $q->col('select')->to_sql;
    is $sql, '"select"', 'reserved word select: col() quoted';
  }

  {
    my ($sql) = $q->select(-from => 'order')->to_sql;
    like $sql, qr/FROM "order"/, 'reserved word: table name quoted';
  }

  {
    my ($sql) = $q->select(-from => 'order|o')->to_sql;
    like $sql, qr/FROM "order" o/, 'reserved table with non-reserved alias';
  }
}

# Uppercase identifiers: quoted
{
  my $q = SQL::Wizard->new;

  {
    my ($sql) = $q->col('Name')->to_sql;
    is $sql, '"Name"', 'uppercase: quoted';
  }

  {
    my ($sql) = $q->col('u.Name')->to_sql;
    is $sql, '"u"."Name"', 'dotted with uppercase: all parts quoted';
  }

  {
    my ($sql) = $q->select(-columns => ['UserName'], -from => 'users')->to_sql;
    is $sql, 'SELECT "UserName" FROM users', 'uppercase col in select';
  }
}

# Star never quoted
{
  my $q = SQL::Wizard->new;
  my ($sql) = $q->select(-from => 'users')->to_sql;
  like $sql, qr/SELECT \*/, 'star not quoted';
}

# MySQL dialect uses backticks
{
  my $q = SQL::Wizard->new(dialect => 'mysql');

  {
    my ($sql) = $q->select(-from => 'users', -where => { 'key' => 1 })->to_sql;
    like $sql, qr/`key` = \?/, 'mysql: reserved word uses backticks';
  }

  {
    my ($sql) = $q->select(-columns => ['id'], -from => 'users')->to_sql;
    is $sql, 'SELECT id FROM users', 'mysql: lowercase not quoted';
  }
}

# Embedded quote escaping
{
  my $r = SQL::Wizard::Renderer->new(dialect => 'ansi');
  is $r->_quote_ident('odd"name'), '"odd""name"', 'ansi: embedded quote escaped';

  my $r2 = SQL::Wizard::Renderer->new(dialect => 'mysql');
  is $r2->_quote_ident('odd`name'), '`odd``name`', 'mysql: embedded backtick escaped';
}

done_testing;
