#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

%ENV = ();

use YAML;

my $BaseDir  = '/home/ftp/pub';
my $BaseName = 'OpenBSD';
my $OutDir   = '/home/andrew/torrents';
my $BTMake   = '/usr/local/bin/btmake';
my $Tracker  = 'http://OpenBSD.somedomain.net/announce.php';

# These are regexes that tell what files to skip;
my $SkipDirs;
my $SkipFiles = qr/^\./;

my $StartDir = shift || $BaseName;
$StartDir =~ s#/$##;

chdir($BaseDir) || die "Couldn't change dir to $BaseDir";

Process_Dir($StartDir);

sub Process_Dir
{
	my $basedir = shift;

	my ($dirs, $files) = Get_Files_and_Dirs($basedir);
	if (@$files) {
		Make_Torrent($basedir, $files);
	}
	foreach my $subdir (@$dirs) {
		#next if $subdir eq '.';
		#next if $subdir eq '..';
		Process_Dir("$basedir/$subdir")
	}
}

sub Make_Torrent
{
	my $basedir = shift;
	my $files   = shift;

	if ($basedir =~ /^([\w\/\.-]+)$/) {
		$basedir = $1;
	} else {
		die "Invalid characters in dir '$basedir'";
	}

	foreach (@$files) {
		if (/^([^\/]+)$/) {
			$_ = "$basedir/$1";
		} else {
			die "Invalid characters in file '$_' in '$basedir'";
		}
	}

	my $torrent = $basedir;
	$torrent =~ s/\W/_/g;
	$torrent .= '-' . Torrent_Date();
	$torrent .= '.torrent';

	print Dump $torrent, $basedir, $files;
	print "Creating $torrent\n";

	system($BTMake, 
	       '-C',
	       '-c', "Created by andrew fresh <andrew\@mad-techies.org>\n" . 
	             "See http://OpenBSD.somedomain.net/",
	       '-n', $BaseName,
	       '-o', "$OutDir/$torrent",
	       '-a', $Tracker,
	       @$files
	);# || die "Couldn't system $BTMake $torrent: $!";
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
