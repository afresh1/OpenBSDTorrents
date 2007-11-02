#!/usr/bin/perl -T
#$RedRiver: NewTorrents.pl,v 1.12 2007/10/01 20:17:23 andrew Exp $
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

my $last_dir = '';
while (<>) {
	#print;
	chomp;
	if (my ($message, $file) = m#(.*)\s+\`([^']+)'#) {
		next if $message eq 'Mirroring directory';
		next if $message eq 'Making directory';

		my $dir = '';
		if ($file =~ m#^(.*)/([^/]+)#) {
			($dir, $file) = ($1, $2);
		}
		#print "$message - ($last_dir) $dir - $file\n";
		print "$message - $dir - $file\n";
		if ($last_dir && $last_dir ne $dir) {
			StartTorrent($last_dir);
		}
		$last_dir = $dir;
	}
}

# Regen just the new ones now
sleep(1) while (keys %Kids > 0);
StartTorrent($last_dir);

# after the new ones are done, regen all, just to make sure
sleep(1) while (keys %Kids > 0);
StartTorrent('skip');

# and wait for it to finish
sleep(1) while (keys %Kids > 0);

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
	$dir =~ s/^.*$OBT->{BASENAME}\///;

	print "Starting '$dir'\n";
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

	if (@now_update) {
		print "Making torrents for ", join(" ", @now_update), "\n";
	} else {
		print "Remaking all torrents\n";
		push @now_update, $dir;
	}
	exec($OBT->{DIR_HOME} . '/regen.sh', @now_update);
}
