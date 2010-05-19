#!/usr/bin/perl -T
#$RedRiver: NewTorrents.pl,v 1.16 2010/03/08 20:19:37 andrew Exp $
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
my $last_file = '';
while (<>) {
	#print;
	chomp;
	# *** This requires --log-format="%t [%p] %o %f %l" on the rsync command
	if (my ($year,  $mon,   $mday,     $time,
                $pid,        $oper,    $file,  $size) = m#^
		(\d{4})/(\d{2})/(\d{2}) \s (\d{2}:\d{2}:\d{2}) \s
		\[(\d+)\] \s (\S+) \s  (.+) \s (\d+)
		$#xms) {

		$file =~ s/^.*$OBT->{BASENAME}\/?//;

        	my ($dir, $file) = $file =~ m#^(.*)/([^/]+)#;
		#print "$oper - ($last_dir) [$dir]/[$file]\n";

		next unless $oper eq 'recv';
		next unless $size;
		next unless $dir;

		if ($last_dir && $last_dir ne $dir) {
			StartTorrent($last_dir);
		}
		elsif ($last_file && $last_file ne $file 
			&& $last_file =~ /$INSTALL_ISO_REGEX/xms) {
			StartTorrent("$dir/$file");
		}

		$last_dir = $dir;
		$last_file = $file;
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

	StartTorrent('waiting');
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
	} 
	elsif ($dir eq 'waiting') {
		return if ! %Need_Update;

		my $count = scalar keys %Need_Update;
		print "Have $count waiting torrents\n";
	}
	else {
		#print "Need to make torrent for '$dir'\n";
		$dir = $OBT->{BASENAME} . "/$dir";
		$Need_Update{$dir} = 1;
	}

	if (keys %Kids > 0) {
		print "Not making torrents for $dir now, already running\n";
		return;
	}

	my @now_update = keys %Need_Update;
	%Need_Update = ();

	if ($should_fork) {
		defined(my $pid = fork)	or die "Can't fork: $!";

		if ($pid) {
			$Kids{$pid} = 1;
			return;
		}

	}

	print "\n";
	if (@now_update) {
		print "Making torrents for ", join(" ", @now_update), "\n";
	} else {
		print "Remaking all torrents\n";
		push @now_update, $dir;
	}
	exec($OBT->{DIR_HOME} . '/regen.sh', @now_update);
	exit;
}
