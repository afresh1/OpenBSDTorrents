#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

use lib 'lib';
use OpenBSDTorrents;

%ENV = ();

use YAML;

my $last_dir = '';
while (<>) {
	chomp;
	if (my ($year,  $mon,  $mday,   $time,               $pid,   $oper, $file, $size) = 
	    m#^(\d{4})/(\d{2})/(\d{2}) (\d{2}:\d{2}:\d{2}) \[(\d+)\] (\S+) (.+) (\d+)$# ) {
		#print "($year, $mon, $mday, $time, $pid, $oper, $file, $size)\n";
		my ($dir, $file) = $file =~ m#^(.*)/([^/]+)#;
		#print "$dir - $file\n";
		if ($last_dir && $last_dir ne $dir) {
			StartTorrent($last_dir);
		}
		$last_dir = $dir;
	} else {
		#print $_;
	}
}
StartTorrent($last_dir);

sub StartTorrent
{
	my $dir = shift;

	# This actually needs to be a sub that forks off 
	# the generation of this, and the running of the update script.
	print "MakeTorrents.pl $BaseName/$dir\n";
}