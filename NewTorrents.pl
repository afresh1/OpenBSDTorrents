#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

use lib 'lib';
use OpenBSDTorrents;

use POSIX 'setsid';

%ENV = ();

use YAML;

# *** This requires --log-format="%t [%p] %o %f %l" on the rsync command

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

sleep(300);

StartTorrent('skip');


sub StartTorrent
{
	my $dir = shift;
	return undef unless $dir;

	if ($dir ne 'skip') {
		$dir = $OBT->{BASENAME} . "/$dir";
	} else {
		$dir = '';
	}

	# This actually needs to be a sub that forks off 
	# the generation of this, and the running of the update script.

	#defined(my $pid = fork)	or die "Can't fork: $!";

	#return if $pid;

	#chdir $HomeDir		or die "Can't chdir to $HomeDir: $!";

	#setsid			or die "Can't start a new session: $!";
	##open STDIN, '/dev/null' or die "Can't read /dev/null: $!";
	##open STDOUT, '>/dev/null'
	##                        or die "Can't write /dev/null: $!";
	##open STDERR, '>&STDOUT'	or die "Can't dup stdout: $!";

	print "Making torrents for $dir\n";
	exec($OBT->{DIR_HOME} . '/regen.sh' . " $dir &");
	#exec($HomeDir . '/regen.sh', "$dir");
}
