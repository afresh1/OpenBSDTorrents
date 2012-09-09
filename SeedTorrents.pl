#!/usr/bin/perl -T
use strict;
use warnings;

use Transmission::Client;
use Transmission::Utils;

my %keep;
my %seeding;

my $client = Transmission::Client->new;
foreach my $torrent (@{ $client->torrents } ) {

    #my $status = Transmission::Utils::from_numeric_status($torrent->status);
    my $hash = $torrent->hash_string;
    if ( exists $keep{$hash} ) {
        $seeding{$hash} = $torrent;
    }
    else {
        print "No longer seeding [$hash]\n";
        $torrent->stop or warn $torrent->error_string;
        $client->remove( $torrent->id ) or warn $client->error;
    }
}


foreach my $hash ( keys %keep ) {
    my $file = $keep{$hash}{file} || q{};
    my $dir  = $keep{$hash}{dir}  || q{};

    if ( !$seeding{$hash} ) {
        print 'Starting seed of ' . $reason . "[$file] [$hash]\n";
        $client->add(
            filename     => "$dir/$file",
            download_dir => $OBT->{DIR_FTP},
        ) ||  warn $client->error, ": $dir/$file\n";
    }
}


$client->start;
