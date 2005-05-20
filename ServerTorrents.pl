#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

use LWP::UserAgent;
use Time::Local;

use lib 'lib';
use OpenBSDTorrents;
use BT::MetaInfo::Cached;

%ENV = ();

#use YAML;

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
opendir DIR, $OBT->{DIR_TORRENT} or die "Couldn't opendir $OBT->{DIR_TORRENT}: $!";
foreach (readdir DIR) {
	chomp;
	if (/^([^\/]+)$/) {
		$_ = $1;
	} else {
		die "Invalid character in $_: $!";
	}
	next unless /\.torrent$/;
	my ($name, $year, $mon, $mday, $hour, $min) = 
	   /^(.*)-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/;

	my $t;
        eval {
		$t = BT::MetaInfo::Cached->new(
			$_,
			{
				cache_root =>
				$OBT->{DIR_HOME} . '/FileCache'
			}
		);
	};

	if ($@) {
		warn "Error reading torrent $_\n";
		return undef;
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

#print Dump \%server_torrents, \%files;

foreach my $name (keys %files) {
	#print "$name\n";
	foreach my $epoch ( sort { $b <=> $a } keys %{ $files{$name} } ) {
		#print "\t$epoch\n";
		my $torrent = $files{$name}{$epoch}{file};
		unless (exists $server_torrents{$torrent} ) {
			#my $time = 
			#	$files{$name}{$epoch}{year} . '-' . 
			#	$files{$name}{$epoch}{mon}  . '-' . 
			#	$files{$name}{$epoch}{mday} . ' ' .
			#	$files{$name}{$epoch}{hour} . ':' .
			#	$files{$name}{$epoch}{min}  . ':00';
				
			Upload_Torrent($files{$name}{$epoch});
		}
		next;
	}
}

foreach my $file (keys %server_torrents) {
	my ($name, $year, $mon, $mday, $hour, $min) = 
	   $file =~
	   /^(.*)-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/;
	unless (exists $files{$name}) {
		Delete_Torrent($file);
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

	my $i = 0;
	while ($size > 1024) {
		$size /= 1024;
		$i++;
	}
	$size = sprintf('%.2f', $size);
	$size .= $Sizes[$i] . 'B';
	
	my $comment = $t->{comment};
	$comment =~ s/\n.*$//s;
	
	my ($filename) = $comment =~ /Files from (.+)/;
	$filename =~ s#/# #g;
	
	$comment  .= " [$size]";
	$filename .= " [$time]";

	my $response = $ua->post($OBT->{URL_UPLOAD}, {
		username => $OBT->{UPLOAD_USER},
		password => $OBT->{UPLOAD_PASS},
		torrent  => [ $OBT->{DIR_TORRENT} . "/$file" ],
		url      => "/torrents/$file",
		filename => $filename,
		filedate => $t->creation_date,
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
	my $file = shift;
	print "Will delete $file soon enough\n";
}
