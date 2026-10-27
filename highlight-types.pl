#!/usr/bin/perl
# Prints gitweb's %highlight_ext and %highlight_basename for every syntax the installed highlight knows.
use strict;
use warnings;

my $lang_dir = '/usr/share/highlight/langDefs';
my $filetypes = '/etc/highlight/filetypes.conf';

sub is_language { my ($name) = @_; return -f "$lang_dir/$name.lang" }
sub is_safe_key { my ($key) = @_; return $key =~ /^[A-Za-z0-9_+-]+$/ }

my %plain_text = map { $_ => 1 } qw(txt text);

my (@languages, %syntax_of_ext);
open my $list, '-|', 'highlight', '--list-scripts=langs' or die "highlight: $!";
while (my $line = <$list>) {
    next unless $line =~ /:\s+([\w+-]+)(?:\s+\(\s+([^)]*?)\s*\))?\s*$/;
    my ($language, $extensions) = ($1, $2 // '');
    next unless is_language($language);
    push @languages, $language;
    for my $extension (split ' ', $extensions) {
        $syntax_of_ext{$extension} //= $language;
    }
}
close $list or die "highlight --list-scripts=langs failed";
$syntax_of_ext{$_} //= $_ for @languages;
$syntax_of_ext{make} //= $syntax_of_ext{mak} if $syntax_of_ext{mak};

my %syntax_of_basename;
open my $config, '<', $filetypes or die "$filetypes: $!";
while (my $line = <$config>) {
    next unless $line =~ /Lang="([\w+-]+)".*Filenames=\{([^}]*)\}/;
    my ($language, $names) = ($1, $2);
    next unless is_language($language);
    $syntax_of_basename{$_} = $language for $names =~ /"([^"]+)"/g;
}
close $config;
my %well_known = (
    Dockerfile => 'dockerfile', Containerfile => 'dockerfile',
    Jenkinsfile => 'jenkinsfile',
    Makefile => 'mak', GNUmakefile => 'mak', makefile => 'mak',
);
while (my ($basename, $key) = each %well_known) {
    my $syntax = $syntax_of_ext{$key} or next;
    $syntax_of_basename{$basename} //= $syntax;
}

die "highlight lists no TypeScript, refusing to generate\n" unless ($syntax_of_ext{ts} // '') eq 'typescript';
die "$filetypes yields no Filenames, refusing to generate\n" unless $syntax_of_basename{'CMakeLists.txt'};

for my $extension (sort grep { is_safe_key($_) && !$plain_text{$_} } keys %syntax_of_ext) {
    print "\$highlight_ext{'$extension'} = '$syntax_of_ext{$extension}';\n";
}
for my $basename (sort grep { /^[A-Za-z0-9_.+-]+$/ } keys %syntax_of_basename) {
    print "\$highlight_basename{'$basename'} = '$syntax_of_basename{$basename}';\n";
}
print "1;\n";
