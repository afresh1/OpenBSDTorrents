package OpenBSDTorrents;
#$Id$
use 5.008005;
use strict;
use warnings;

require Exporter;

our @ISA = qw(Exporter);

our $VERSION = '0.01';

our @EXPORT = qw(
	$BaseDir
	$TorrentDir
	$BaseName
	$Tracker
	&Name_Torrent
	&Get_Files_and_Dirs
);
	
our $BaseDir    = '/home/ftp/pub';
our $TorrentDir = '/home/andrew/torrents';
our $BaseName   = 'OpenBSD';
our $Tracker    = 'http://OpenBSD.somedomain.net/announce.php';

# These are regexes that tell what files to skip;
our $SkipDirs  = qr/\/patches$/;
our $SkipFiles = qr/^\./;


sub Name_Torrent
{
	my $torrent = shift;

	my $date = Torrent_Date();

	$torrent =~ s/\W/_/g;
	$torrent .= '-' . $date;
	$torrent .= '.torrent';

	return $torrent;
}


sub Get_Files_and_Dirs
{
	my $basedir = shift;
	opendir DIR, $basedir or die "Couldn't opendir $basedir: $!";
	my @contents = grep { ! /^\.\.$/ } grep { ! /^\.$/ } readdir DIR;
	closedir DIR;
	my @dirs  = grep { -d "$basedir/$_" } @contents;

	my %dirs; # lookup table
	my @files;# answer

	# build lookup table
	@dirs{@dirs} = ();

	foreach my $item (@contents) {
    		push(@files, $item) unless exists $dirs{$item};
	}

	@dirs  = grep { ! /$SkipDirs/  } @dirs  if $SkipDirs;
	@files = grep { ! /$SkipFiles/ } @files if $SkipFiles;

	return \@dirs, \@files;
}

sub Torrent_Date
{
	my ($min, $hour, $mday, $mon, $year) = (gmtime)[1..5];
	$mon++;
	$year += 1900;
	foreach ($min, $hour, $mday, $mon) {
		if (length $_ == 1) {
			$_ = '0' . $_;
		}
	}
	return join '-', ($year, $mon, $mday, $hour . $min);
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

OpenBSDTorrents - Perl extension for blah blah blah

=head1 SYNOPSIS

  use OpenBSDTorrents;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for OpenBSDTorrents, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.


=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Andrew Fresh, E<lt>andrew@E<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005 by Andrew Fresh

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.5 or,
at your option, any later version of Perl 5 you may have available.


=cut
