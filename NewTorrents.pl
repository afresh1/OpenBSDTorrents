#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

use lib 'lib';
use OpenBSDTorrents;

use POSIX qw / setsid :sys_wait_h /;
$SIG{CHLD} = \&REAPER;
my %Kids;
my %Kid_Status;
my %Need_Update;

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

# Regen just the new ones now
sleep(1) while (keys %Kids > 0);
StartTorrent($last_dir);

# after the new ones are done, regen all, just to make sure
sleep(1) while (keys %Kids > 0);
StartTorrent('skip');

sub REAPER {
	my $child;
        while (($child = waitpid(-1,WNOHANG)) > 0) {
		$Kid_Status{$child} = $?;
		delete $Kids{$child};
	}
	$SIG{CHLD} = \&REAPER;  # still loathe sysV
}

sub StartTorrent
{
	my $dir = shift;
	return undef unless $dir;

	my $should_fork = 1;

	if ($dir eq 'skip') {
		#$dir = '';
		%Need_Update = ();
		$should_fork = 0;
	} else {
		$dir = $OBT->{BASENAME} . "/$dir";
		$Need_Update{$dir} = 1;
	}

	if (keys %Kids > 0) {
		print "Not making torrents for $dir now, already running\n";
		return undef;
	}

	my @now_update = keys %Need_Update;
	%Need_Update = ();

	if ($should_fork) {
		defined(my $pid = fork)	or die "Can't fork: $!";

		if ($pid) {
			$Kids{$pid} = 1;
			return undef;
		}

	}

	chdir $OBT->{DIR_HOME} or die "Can't chdir to $OBT->{DIR_HOME}: $!";

	if (@now_update) {
		print "Making torrents for ", join(" ", @now_update), "\n";
	} else {
		print "Remaking all torrents\n";
		push @now_update, $dir;
	}
	exec($OBT->{DIR_HOME} . '/regen.sh', @now_update);
}
