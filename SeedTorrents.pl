#!/usr/bin/perl -T
use strict;
use warnings;

use Mojo::UserAgent;

#use Transmission::Utils;
use Transmission::Client;

my $torrent_uri = 'http://openbsd.somedomain.net/torrent/';
my $download_dir = '';    # If you want to override

use lib 'lib';
eval { require OpenBSDTorrents };
unless ($@) {
    $torrent_uri  = $OpenBSDTorrents::OBT->{URL_TORRENTS};
    $download_dir = $OpenBSDTorrents::OBT->{DIR_FTP};
}

my $current
    = Mojo::UserAgent->new->get( $torrent_uri . 'torrents.json' )->res->json;
die "Couldn't get current torrents" unless $current;

my $client = Transmission::Client->new;
foreach my $torrent ( @{ $client->torrents } ) {
    next unless $torrent->comment =~ /OpenBSD.somedomain.net/;
    my $hash = $torrent->hash_string;

    if ( exists $current->{$hash} ) {
        delete $current->{$hash};    # No need to do anything
    }
    else {
        print "No longer seeding [$hash]\n";
        $torrent->stop or warn $torrent->error_string;
        $client->remove( $torrent->id ) or warn $client->error;
    }
}

foreach my $hash ( keys %{$current} ) {
    my $file = $current->{$hash}{torrent};
    print "Starting seed of [$file] [$hash]\n";

    $client->add(
        filename     => $torrent_uri . $file,
        download_dir => $download_dir,
    ) || warn $client->error, ": $file\n";
}

$client->start;
