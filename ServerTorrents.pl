#!/usr/bin/perl -T
#$RedRiver: ServerTorrents.pl,v 1.28 2010/01/07 18:50:02 andrew Exp $
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

my @Sizes = ( '', 'Ki', 'Mi', 'Gi', 'Ti' );
my $ua = LWP::UserAgent->new;

my $response = $ua->get( $OBT->{URL_TORRENTS} );

my %server_torrents;
if ( $response->is_success ) {
    my $content = $response->content;    # or whatever
    $content =~ s/^.*<!-- BEGIN LIST -->//s
        || die "Beginning of list not found!";
    $content =~ s/<!-- END LIST -->.*$//s || die "End of list not found!";
    unless ( $content =~ /No data/ ) {
        foreach ( split /\n/, $content ) {
            s/^\s+//;
            s/\s+$//;
            next unless $_;
            my ( $name, $hash, $disabled ) = split /\t/;
            next if $name eq 'File';

            $name =~ s#.*/##;
            $server_torrents{$hash} = {
                name     => $name,
                disabled => $disabled,
            };
        }
    }
}
else {
    die $response->status_line;
}

my %torrents;
opendir DIR, $OBT->{DIR_TORRENT}
    or die "Couldn't opendir $OBT->{DIR_TORRENT}: $!";
foreach my $torrent ( readdir DIR ) {
    chomp $torrent;
    next unless $torrent =~ /\.torrent$/;

    if ($torrent =~ /^([^\/]+)$/) {
        $torrent = $1;
    }
    else {
        die "Invalid character in $torrent: $!";
    }

    my $name = basename( $torrent, '.torrent' );

    if ( my ( $base, $year, $mon, $mday, $hour, $min )
        = $torrent =~ /^(.*)-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})/ )
    {
        $name = $base;
    }

    my $t;
    eval {
        $t = BT::MetaInfo::Cached->new(
            $OBT->{DIR_TORRENT} . '/' . $torrent,
            {   cache_root => '/tmp/OBTFileCache'

                    #$OBT->{DIR_HOME} . '/FileCache'
            }
        );
    };
    if ($@) {
        warn "Error reading torrent $torrent\n";
        next;
    }

    #my $epoch = $t->creation_date;

    my $hash = unpack( "H*", $t->info_hash );
    $torrents{$hash} = {
        file    => $torrent,
        details => $t,
        name    => $name,
        #epoch   => $epoch,
    };

    if ( !exists $server_torrents{$hash} ) {
        Upload_Torrent( $torrents{$hash} );
    }
}
closedir DIR;

#print Dump \%server_torrents;
#exit;

foreach my $hash ( keys %server_torrents ) {

    #printf "SERVER: [%s] [%s]\n", $hash, $torrent;
    if (   ( !exists $torrents{$hash} )
        && ( !$server_torrents{$hash}{disabled} ) )
    {
        Delete_Torrent( $server_torrents{$hash}{name}, $hash );
    }
}

$ua->get( $OBT->{URL_SANITY} );

sub Upload_Torrent {
    my $torrent = shift;
    my $t       = $torrent->{'details'};

    my $file = $torrent->{'file'};
    #print "Uploading $file\n";

    my $size = $t->total_size;
    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday )
        = gmtime( $t->creation_date );
    $year += 1900;
    $mon++;
    my $time = sprintf "%04d.%02d.%02d %02d:%02d",
        $year, $mon, $mday, $hour, $min;

    ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday )
        = localtime( $t->creation_date );
    $year += 1900;
    $mon++;
    my $sql_time = sprintf "%04d-%02d-%02d %02d:%02d",
        $year, $mon, $mday, $hour, $min;

    my $i = 0;
    while ( $size > 1024 ) {
        $size /= 1024;
        $i++;
    }
    $size = sprintf( '%.2f', $size );
    $size .= $Sizes[$i] . 'B';

    my $comment = $t->{comment};
    $comment =~ s/\n.*$//s;

    my $filename
        = $comment =~ /($OBT->{BASENAME}.+)/
        ? $1
        : $file;
    $filename =~ s#/# #g;
    $filename =~ s/\.torrent\z//;

    $comment  .= " [$size]";
    $filename .= " [$time]";

    my $response = $ua->post(
        $OBT->{URL_UPLOAD},
        {   username => $OBT->{UPLOAD_USER},
            password => $OBT->{UPLOAD_PASS},
            torrent  => [ $OBT->{DIR_TORRENT} . "/$file" ],
            url      => "/torrents/$file",
            filename => $filename,
            filedate => $sql_time,
            info     => $comment,
            hash     => '',
            autoset => 'enabled',    # -> checked="checked"
        },
        Content_Type => 'form-data'
    );

    if ( $response->is_success ) {
        print STDERR "Uploaded  $file\n";

        #print $response->content;
    }
    else {
        die $response->status_line;
    }
}

sub Delete_Torrent {
    my $filename = shift;
    my $hash     = shift;
    die "No hash passed!" unless $hash;

    #print "Removing $filename [$hash]\n";

    my $response = $ua->post(
        $OBT->{'URL_DELETE'},
        {   username => $OBT->{UPLOAD_USER},
            password => $OBT->{UPLOAD_PASS},
            filename => $filename,
            hash     => $hash,
        },
        Content_Type => 'form-data'
    );

    if ( $response->is_success ) {
        my ($result) = $response->content =~ /class="error"\>([^<]+)\</;

        if ( $result eq 'Torrent was removed successfully.' ) {
            print STDERR "Removed $filename [$hash]\n";
        }
        elsif ($result) {
            print STDERR "Error: $result (removing $filename [$hash])\n";
        }
        else {
            print STDERR
                "An unknown error occurred removing $filename [$hash]\n";
        }
    }
    else {
        die $response->status_line . " removing $filename [$hash]\n";
    }
}
