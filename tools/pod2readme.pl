#!/usr/bin/env perl
# Converts lib/SQL/Wizard.pod to README.md with title-cased headers and proper structure.
use strict;
use warnings;
use Pod::Markdown;

binmode STDOUT, ':utf8';

my $pod_file = $ARGV[0] || 'lib/SQL/Wizard.pod';

# Read POD
open my $fh, '<', $pod_file or die "Cannot open $pod_file: $!\n";
my $pod_string = do { local $/; <$fh> };
close $fh;

# Convert to markdown
my $markdown;
my $parser = Pod::Markdown->new;
$parser->output_string(\$markdown);
$parser->parse_string_document($pod_string);

# Transform headers
my %acronyms = map { lc($_) => $_ } qw(SQL DBI CTEs CTE MySQL PostgreSQL SQLite ANSI);
my %methods = map { lc($_) => 1 } qw(
  new col val raw func coalesce greatest least cast exists between
  and or not as asc desc over select insert update delete with
  join returning columns limit offset
);
my $skip_name = 0;

for my $line (split /\n/, $markdown) {
  if ($line =~ /^(#+)\s+(.+)/) {
    my ($h, $t) = ($1, $2);
    my @words = split(/\s+/, $t);
    my $single = @words == 1;
    $t = join(' ', map {
      /[_]/ || /^-/              ? lc($_)              # underscored/dashed: to_sql, -columns
      : $single && $methods{lc($_)} ? lc($_)           # single-word method headers: new, col, etc.
                                 : ucfirst(lc($_))     # normal words: Title Case
    } @words);
    $t =~ s/\b(\w+)\b/$acronyms{lc($1)} || $1/ge;

    # Remove # Name section; promote its description line to h1
    if ($h eq '#' && $t eq 'Name') { $skip_name = 1; next }
    if ($skip_name && $h eq '#')   { $skip_name = 0; print "# $t\n"; next }
    if ($skip_name)                { next }

    # Demote: h1 -> h2, h2 -> h3, etc.
    print "#$h $t\n";
  } else {
    if ($skip_name && $line =~ /\S/) {
      print "# $line\n";
      $skip_name = 0;
      next;
    }
    next if $skip_name;
    print "$line\n";
  }
}
