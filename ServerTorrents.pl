#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

use BT::MetaInfo;
use LWP::UserAgent;
use Time::Local;

use lib 'lib';
use OpenBSDTorrents;

%ENV = ();

use YAML;

my $url_torrents = 'http://openbsd.somedomain.net/dumptorrents.php';
my $url_upload   = 'http://openbsd.somedomain.net/newtorrents.php';
my $url_delete   = 'http://openbsd.somedomain.net/deltorrents.php';

my $user = 'torrentup';
my $pass = 'ssapword';

my $ua = LWP::UserAgent->new;

my $response = $ua->get($url_torrents);

my %server_torrents;
if ($response->is_success) {
    my $content = $response->content;  # or whatever
    $content =~ s/^.*<!-- BEGIN LIST -->//s || die "Beginning of list not found!";
    $content =~ s/<!-- END LIST -->.*$//s   || die "End of list not found!";
    unless ($content =~ /No data/) {
        foreach (split /\n/, $content) {
            s/^\s+//;
            s/\s+$//;
            next unless $_;
            my ($name, $hash) = split /\t/;
            next if $name eq 'File';

            $name =~ s#^/torrents/##;
            $server_torrents{$name} = $hash;
        }
    }
} else {
    die $response->status_line;
}


my %files;
opendir DIR, $TorrentDir or die "Couldn't opendir $TorrentDir: $!";
foreach (readdir DIR) {
	if (/^([^\/]+)$/) {
		$_ = $1;
	} else {
		die "Invalid character in $_: $!";
	}
	next unless /\.torrent$/;
	chomp;
	my ($name, $year, $mon, $mday, $hour, $min) = 
	   /^(.*)-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/;

	my $epoch = timegm(0,$min,$hour,$mday,$mon,$year);

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

#print Dump \%server_torrents, \%files;

foreach my $name (keys %files) {
	#print "$name\n";
	foreach my $epoch ( sort { $b <=> $a } keys %{ $files{$name} } ) {
		#print "\t$epoch\n";
		my $torrent = $files{$name}{$epoch}{file};
		unless (exists $server_torrents{$torrent} ) {
			my $time = 
				$files{$name}{$epoch}{year} . '-' . 
				$files{$name}{$epoch}{mon}  . '-' . 
				$files{$name}{$epoch}{mday} . ' ' .
				$files{$name}{$epoch}{hour} . ':' .
				$files{$name}{$epoch}{min}  . ':00';
				
			Upload_Torrent($torrent, $time);
		}
		next;
	}
}

foreach my $file (keys %server_torrents) {
	unless (exists $files{$file}) {
		Delete_Torrent($file);
	}
}


sub Upload_Torrent
{
	my $file = shift;
	my $time = shift;

	print "Uploading $file\n";

	my $t;
	eval { $t = BT::MetaInfo->new("$TorrentDir/$file"); };
	if ($@) {
		warn "Error reading torrent $file\n";
		return undef;
	}

	my $comment = $t->{comment};
	$comment =~ s/\n.*$//s;

	my ($filename) = $comment =~ /Files from ([^<]+)/;
	$filename =~ s#/# #g;
	
	$filename .= ' (' . $time . ')';

	my $response = $ua->post($url_upload, {
		username => $user,
		password => $pass,
		torrent  => [ "$TorrentDir/$file" ],
		url      => "/torrents/$file",
		filename => $filename,
		filedate => $time,
		info     => $comment,
		hash     => '',
		autoset  => 'enabled', # -> checked="checked"
	}, Content_Type => 'form-data');

	if ($response->is_success) {
		print "Uploaded  $file\n";
		#print $response->content;
	} else {
    		die $response->status_line;
	}
}

sub Delete_Torrent
{
	my $file = shift;
	print "Will delete $file soon enough\n";
}
