#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

use BT::MetaInfo;
use Time::Local;

use lib 'lib';
use OpenBSDTorrents;

%ENV = ();

#use YAML;

my %files;
opendir DIR, $TorrentDir or die "Couldn't opendir $TorrentDir: $!";
foreach (readdir DIR) {
	if (/^([^\/]+)$/) {
		$_ = $1;
	} else {
		die "Invalid character in $_: $!";
	}
	next unless /\.torrent$/;
	my ($name, $year, $mon, $mday, $hour, $min) = 
	   /^(.*)-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/;

	my $epoch = timegm(0,$min,$hour,$mday,$mon,$year);

        my $t = BT::MetaInfo->new("$TorrentDir/$_");
	my $hash = $t->info_hash;
	$hash = unpack("H*", $hash);

	$files{$name}{$epoch} = {
		file      => $_,
		comment   => $t->{comment},
		year      => $year,
		mon       => $mon,
		mday      => $mday,
		hour      => $hour,
		min       => $min,
		epoch     => $epoch,
		info_hash => $hash,
	};

}
closedir DIR;


my %keep;
my @delete;
foreach my $name (keys %files) {
	foreach my $time ( sort { $b <=> $a } keys %{ $files{$name} } ) {
		#print "$name - $time\n";
		my $hash = $files{$name}{$time}{info_hash};
		if (exists $keep{$name}) {
			if (exists $keep{$name}{$hash}) {
				push @delete, $keep{$name}{$hash};
				$keep{$name}{$hash} = 
					$files{$name}{$time}{file};
			} else {
				push @delete, $files{$name}{$time}{file};
			}
		} else { 
			$keep{$name}{$hash} = 
				$files{$name}{$time}{file};

		}
	}
}

#print Dump \%files, \%keep, \@delete;

foreach (@delete) {
	print "Deleting '$_'\n";
	unlink "$TorrentDir/$_" or die "Couldn't unlink $_";
}
