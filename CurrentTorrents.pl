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

justme();

my %files;
opendir DIR, $OBT->{DIR_TORRENT} 
	or die "Couldn't opendir $OBT->{DIR_TORRENT}: $!";
foreach (readdir DIR) {
	if (/^([^\/]+)$/) {
		$_ = $1;
	} else {
		die "Invalid character in $_: $!";
	}
	next unless /\.torrent$/;
	my ($name, $year, $mon, $mday, $hour, $min) = 
	   /^(.*)-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/;

	$mon--;
	my $epoch = timegm(0,$min,$hour,$mday,$mon,$year);

	#print "Adding $_\n";

	$files{$name}{$epoch} = {
		file      => $_,
		year      => $year,
		mon       => $mon,
		mday      => $mday,
		hour      => $hour,
		min       => $min,
		epoch     => $epoch,
	};

}
closedir DIR;

my %keep;
my @delete;
foreach my $name (keys %files) {
	#print "$name\n";

	foreach my $epoch ( sort { $b <=> $a } keys %{ $files{$name} } ) {
		#print "\t$epoch\n";
		my $torrent = $files{$name}{$epoch}{file};

		my $t;
		eval { $t = BT::MetaInfo->new($OBT->{DIR_TORRENT} . "/$torrent"); };
		if ($@) {
			warn "Error reading torrent $torrent\n";
			next;
		}

		$files{$name}{$epoch}{comment}   = $t->{comment};
		my ($path) = $t->{comment} =~ /Files from ([^\n]+)\n/s;

		unless (-d $OBT->{DIR_FTP} . "/$path") {
			#print "Deleting $files{$name}{$epoch}{file} the path doesn't exist.\n"; 
			push @delete, $files{$name}{$epoch}{file};
		}

		if (keys %{ $files{$name} } == 1) {
			#print "Skipping torrent for $name there is only one.\n";
			next;
		}

		my $hash = $t->info_hash;
		$hash = unpack("H*", $hash);

		$files{$name}{$epoch}{info_hash} = $hash;

		undef $t;

		if (exists $keep{$name}) {
			if (exists $keep{$name}{$hash}) {
				push @delete, $keep{$name}{$hash};
				$keep{$name}{$hash} = 
					$files{$name}{$epoch}{file};
			} else {
				push @delete, $files{$name}{$epoch}{file};
			}
		} else { 
			$keep{$name}{$hash} = 
				$files{$name}{$epoch}{file};

		}
	}
}

#print Dump \%files, \%keep, \@delete;

foreach (@delete) {
	print "Deleting '$_'\n";
	unlink $OBT->{DIR_TORRENT} . "/$_" or die "Couldn't unlink $_";
}
