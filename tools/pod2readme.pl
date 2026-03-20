#!/usr/bin/env perl
# Converts POD to README.md with title-cased headers and proper structure.
use strict;
use warnings;

my %acronyms = map { lc($_) => $_ } qw(SQL DBI CTEs CTE MySQL PostgreSQL SQLite ANSI);
my $skip_name = 0;

while (<STDIN>) {
  if (/^(#+)\s+(.+)/) {
    my ($h, $t) = ($1, $2);
    $t = join(' ', map { ucfirst(lc($_)) } split(/\s+/, $t));
    $t =~ s/\b(\w+)\b/$acronyms{lc($1)} || $1/ge;

    # Remove # Name section; promote its next sibling (the description line) to h1
    if ($h eq '#' && $t eq 'Name') { $skip_name = 1; next }
    if ($skip_name && $h eq '#')   { $skip_name = 0; print "# $t\n"; next }
    if ($skip_name)                { next }

    # Demote: h1 -> h2, h2 -> h3, etc.
    print "#$h $t\n";
  } else {
    if ($skip_name && /\S/) {
      chomp;
      print "# $_\n";
      $skip_name = 0;
      next;
    }
    next if $skip_name;
    print;
  }
}
