#!/usr/bin/perl
# OpenPGP program for Git's signature verification in gitweb. Git calls it like gpg with
# "--keyid-format=long --status-fd=1 --verify <signature> -" and the signed data on stdin.
# gpgv takes neither --keyid-format nor --verify and reads only binary keyrings, so this
# drops both options, converts the mounted ASCII-armored keys into a keyring in /tmp and
# runs gpgv against it. Every key in that file is trusted, gpgv has no other trust model,
# so a good signature gets a TRUST_FULLY status line that Git turns into %G? = G.
use strict;
use warnings;
use File::Temp qw(tempfile);
use MIME::Base64 qw(decode_base64);

my $keys = '/etc/gitweb.d/trusted-keys.asc';
my $gpgv = '/usr/bin/gpgv';

sub keyring {
	open my $fd, '<', $keys or return '';
	binmode $fd;
	my $text = do { local $/; <$fd> };
	close $fd;
	my $keyring = '';
	while ($text =~ /^-----BEGIN PGP PUBLIC KEY BLOCK-----\r?\n(.*?)^-----END PGP PUBLIC KEY BLOCK-----/msg) {
		my $block = $1;
		$block =~ s/\A(?:[^\r\n]*:[^\r\n]*\r?\n)*\r?\n//;   # armor headers up to the empty line
		$block =~ s/^=[A-Za-z0-9+\/]{4}\r?$//m;          # CRC24 checksum line
		$keyring .= decode_base64($block);
	}
	return $keyring;
}

my ($fh, $keyring) = tempfile('gitweb-keyring-XXXXXXXX', DIR => '/tmp', UNLINK => 1);
binmode $fh;
print $fh keyring() or die "gpgv-git: cannot write $keyring: $!\n";
close $fh or die "gpgv-git: cannot write $keyring: $!\n";

my @args = grep { $_ ne '--verify' && !/^--keyid-format=/ } @ARGV;
my $pid = open my $status, '-|';
die "gpgv-git: cannot fork: $!\n" unless defined $pid;
if (!$pid) {
	require POSIX;
	exec($gpgv, '--homedir', '/nonexistent', '--keyring', $keyring, @args) or do {
		print STDERR "gpgv-git: cannot run $gpgv: $!\n";
		POSIX::_exit(2);
	};
}
my $output = do { local $/; <$status> };
close $status;
my $exit = $? >> 8;
print $output;
print "[GNUPG:] TRUST_FULLY 0 pgp\n"
	if $exit == 0 && $output =~ /^\[GNUPG:\] GOODSIG /m && $output !~ /^\[GNUPG:\] TRUST_/m;
exit $exit;
