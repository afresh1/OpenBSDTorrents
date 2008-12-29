#!/usr/bin/perl -T
#$RedRiver: ServerTorrents.pl,v 1.26 2008/12/29 22:02:14 andrew Exp $
use strict;
use warnings;
use diagnostics;

use LWP::UserAgent;
use Time::Local;
use File::Basename;
#use YAML;

use lib 'lib';
use OpenBSDTorrents;
use BT::MetaInfo::Cached;

%ENV = ();

justme();

my @Sizes = ('', 'Ki', 'Mi', 'Gi', 'Ti');
my $ua = LWP::UserAgent->new;

my $response = $ua->get($OBT->{URL_TORRENTS});

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
            my ($name, $hash, $disabled) = split /\t/;
            next if $name eq 'File';

            $name =~ s#.*/##;
            $server_torrents{$name}{$hash} = $disabled;
        }
    }
} else {
    die $response->status_line;
}

my %files;
opendir DIR, $OBT->{DIR_TORRENT} or die "Couldn't opendir $OBT->{DIR_TORRENT}: $!";
foreach (readdir DIR) {
	chomp;
	if (/^([^\/]+)$/) {
		$_ = $1;
	} else {
		die "Invalid character in $_: $!";
	}
	next unless /\.torrent$/;

	my $name = basename($_, '.torrent');

	if (my ($base, $year, $mon, $mday, $hour, $min) = 
	   /^(.*)-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/) {
		$name = $base;
	}

	my $t;
        eval {
		$t = BT::MetaInfo::Cached->new(
			$OBT->{DIR_TORRENT} . '/' . $_,
			{
				cache_root => '/tmp/OBTFileCache'
				#$OBT->{DIR_HOME} . '/FileCache'
			}
		);
	};

	if ($@) {
		warn "Error reading torrent $_\n";
		next;
	}

	my $epoch = $t->creation_date;

	$files{$name}{$epoch} = {
		file      => $_,
		details   => $t,
		name      => $name,
		epoch     => $epoch,
	};

}
closedir DIR;

#print Dump \%server_torrents;
#print Dump \%files;
#exit;

my %torrents;
FILE: foreach my $name (keys %files) {
	#print "$name\n";
	foreach my $epoch ( sort { $b <=> $a } keys %{ $files{$name} } ) {
		#print "\t$epoch\n";
		my $torrent = $files{$name}{$epoch}{file};
		my $hash = unpack("H*", $files{$name}{$epoch}{'details'}->info_hash );
		#printf "LOCAL:  [%s] [%s]\n", $hash, $torrent;

		$torrents{$torrent}{$hash} = $files{$name}{$epoch};

		unless (exists $server_torrents{$torrent}{$hash}) {
			Upload_Torrent($files{$name}{$epoch});
		}
	}
}

foreach my $torrent (keys %server_torrents) {
	foreach my $hash (keys %{ $server_torrents{$torrent} }) {
		#printf "SERVER: [%s] [%s]\n", $hash, $torrent;
		if ((! exists $torrents{$torrent}{$hash}) &&
		    (
		     (! defined $server_torrents{$torrent}{$hash}) ||
		     $server_torrents{$torrent}{$hash} != 1
		    )
		) {
			Delete_Torrent($torrent, $hash);
		}
	}
}

$ua->get($OBT->{URL_SANITY});

sub Upload_Torrent
{
	my $torrent = shift;
	my $t = $torrent->{'details'};

	my $file = $torrent->{'file'};
	print "Uploading $file\n";

	my $size = $t->total_size;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) =
		gmtime($t->creation_date);
	$year += 1900;
	$mon++;
	my $time = sprintf "%04d.%02d.%02d %02d:%02d", 
		$year, $mon, $mday,  $hour, $min;

	($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) =
		localtime($t->creation_date);
	$year += 1900;
	$mon++;
	my $sql_time = sprintf "%04d-%02d-%02d %02d:%02d", 
		$year, $mon, $mday,  $hour, $min;

	my $i = 0;
	while ($size > 1024) {
		$size /= 1024;
		$i++;
	}
	$size = sprintf('%.2f', $size);
	$size .= $Sizes[$i] . 'B';
	
	my $comment = $t->{comment};
	$comment =~ s/\n.*$//s;
	
	my $filename = 
		 $comment =~ /($OBT->{BASENAME}.+)/ ? $1
		:                                $file;
	$filename =~ s#/# #g;
	$filename =~ s/\.torrent\z//;
	
	$comment  .= " [$size]";
	$filename .= " [$time]";

	my $response = $ua->post($OBT->{URL_UPLOAD}, {
		username => $OBT->{UPLOAD_USER},
		password => $OBT->{UPLOAD_PASS},
		torrent  => [ $OBT->{DIR_TORRENT} . "/$file" ],
		url      => "/torrents/$file",
		filename => $filename,
		filedate => $sql_time,
		info     => $comment,
		hash     => '',
		autoset  => 'enabled', # -> checked="checked"
	}, Content_Type => 'form-data');

	if ($response->is_success) {
		print STDERR "Uploaded  $file\n";
		#print $response->content;
	} else {
    		die $response->status_line;
	}
}

sub Delete_Torrent
{
	my $filename = shift;
	my $hash = shift;
	die "No hash passed!" unless $hash;

	print "Removing $filename [$hash]\n";

	my $response = $ua->post($OBT->{'URL_DELETE'}, {
		username => $OBT->{UPLOAD_USER},
		password => $OBT->{UPLOAD_PASS},
		filename => $filename,
		hash     => $hash,
	}, Content_Type => 'form-data');

	if ($response->is_success) {
		my ($result) = $response->content =~ /class="error"\>([^<]+)\</;

		if ($result eq 'Torrent was removed successfully.') {
			print STDERR "Removed $filename [$hash]\n";
		}
		elsif ($result) {
			print STDERR "Error: $result (removing $filename [$hash])\n";
		} 
		else {
			print STDERR "An unknown error occurred removing $filename [$hash]\n";
		}
	} 
	else {
    		die $response->status_line . " removing $filename [$hash]\n";
	}
}
