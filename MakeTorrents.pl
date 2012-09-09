#!/usr/bin/perl
# -T
#$RedRiver: MakeTorrents.pl,v 1.26 2010/03/22 20:16:02 andrew Exp $
use strict;
use warnings;
use diagnostics;

use lib 'lib';
use Net::BitTorrent::File;
use OpenBSDTorrents;

%ENV = ();

chdir( $OBT->{DIR_FTP} )
    || die "Couldn't change dir to " . $OBT->{DIR_FTP} . ": $!";

my $StartDir = '';
if (@ARGV) {
    foreach (@ARGV) {
        s#/$##;
        Process_Dir($_);
    }
}
else {
    $StartDir = '.';
    Process_Dir($StartDir);
}

sub Process_Dir {
    my $basedir = shift;

    #return undef if $basedir =~ /packages/;

    my ( $dirs, $files ) = Get_Files_and_Dirs($basedir);
    if ( -f $basedir) {
        $basedir =~ s{/[^/]+$}{}xms;
    }
    if (@$files) {
        Make_Torrent( $basedir, $files );
    }

    # don't recurse if we were started with a specific directory
    return 1 if $StartDir ne '.';

    foreach my $subdir (@$dirs) {
        next if $subdir =~ /^\./;
        Process_Dir("$basedir/$subdir");
    }
}

sub Make_Torrent {
    my $basedir = shift;
    my $files   = shift;

    $basedir =~ s{^[\./]+}{};
    return unless $basedir;

    if ( $basedir !~ /\.\./ && $basedir =~ /^([\w\/\.-]+)$/ ) {
        $basedir = $1;
    }
    else {
        die "Invalid characters in dir '$basedir'";
    }

    if ( $#{$files} < $OBT->{MIN_FILES} 
      && $files->[0] !~/$INSTALL_ISO_REGEX/xms ) {
        print "Too few files in $basedir, skipping . . .\n";
        return undef;
    }

    my $torrent = Name_Torrent($basedir);
    my $comment = "Files from $basedir";

    my %torrents;
    foreach my $file (@$files) {
        if ( $file =~ /^([^\/]+)$/ ) {
            $file = $1;

            my $t = $torrent;
            my $c = $comment;
            my $f = "$basedir/$file";

            if ( $file =~ /$INSTALL_ISO_REGEX/xms ) {
                my $renamed = $f;
                $renamed =~ s{/}{_}g;

                my $root = $OBT->{DIR_FTP};

                unlink $root . '/' . $renamed if -e $root . '/' . $renamed;
                link $root . '/' . $f, $root . '/' . $renamed
                    or die "Couldn't link $root/{$f to $renamed}: $!";

                $t = Name_Torrent($renamed);
                $c = $renamed;
            }
            elsif ( my ($ext) = $file =~ /$SONG_REGEX/xms ) {
                $t = Name_Torrent("$basedir/$ext");
                $c = "$ext files from $basedir";
            }

            $torrents{$t}{comment} = $c;
            push @{ $torrents{$t}{files} }, $f;
        }
        else {
            die "Invalid characters in file '$file' in '$basedir'";
        }
    }

    foreach my $t ( keys %torrents ) {

        print "Creating $t ("
            . ( scalar @{ $torrents{$t}{files} } )
            . " files)\n";

        my $c = $torrents{$t}{comment};
        $c .= "\nCreated by andrew fresh (andrew\@afresh1.com)\n"
            . "http://OpenBSD.somedomain.net/";

        eval { btmake( $t, $c, $torrents{$t}{files} ); };
        if ($@) {
            print "Error creating $t\n$@\n";
        }

        #        system($BTMake,
        #               '-C',
        #               '-c', $comment,
        #               '-n', $OBT->{BASENAME},
        #               '-o', $OBT->{DIR_TORRENT} . "/$t",
        #               '-a', $Tracker,
        #               @$files
        #        );# || die "Couldn't system $BTMake $t: $!";
    }

    return [ keys %torrents ];
}

# Stole and modified from btmake to work for this.
sub btmake {
    no locale;

    my $torrent = shift;
    my $comment = shift;
    my $files   = shift;

    my $name      = $OBT->{BASENAME};
    my $announce  = $OBT->{URL_TRACKER};
    my $piece_len = 2 << ( $OBT->{PIECE_LENGTH} - 1 );

    my $torrent_with_path = $OBT->{DIR_NEW_TORRENT} . "/$torrent";

    if (@$files == 1) {
    	$name = $files->[0];
    }

    my $t = Net::BitTorrent::File->new();

    $t->name($name);
    $t->announce([$announce]);
    unless ( $announce =~ m!^http://[^/]+/!i ) {
        warn
            "  [ WARNING: announce URL does not look like: http://hostname/ ]\n";
    }
    $t->comment($comment);

    #foreach my $pair (split(/;/, $::opt_f)) {
    #    if (my($key, $val) = split(/,/, $pair, 2)) {
    #        $t->set($key, $val);
    #    }
    #}
    $t->piece_length($piece_len);
    $t->creation_date(time);
    $t->created_by('OpenBSD Torrents - http://github.com/afresh1/OpenBSDTorrents');

    #print "Checksumming files. This may take a little while...\n";

    # Can't use this,  have to do this manually because
    # we need to have the multi-file type of torrent
    # even when we have only one file.
    #$t->set_files(@$files);

    my @file_list;
    my $total_size = 0;
    foreach my $f (@$files) {
        my $l = ( stat("$OBT->{DIR_FTP}/$f") )[7];
        $total_size += $l;
        my @p = split /\//, $f;
        shift @p;
        push @file_list,
            {
            length => $l,
            path   => \@p,
            };
    }

    if ( $total_size < $OBT->{MIN_SIZE} ) {
        print "Skipping smaller than minimum size\n";
        return 0;
    }

    $t->files( \@file_list );
    $t->gen_pieces_array(@$files);

    #$t->gen_info_hash();
    #my $hash = $t->info_hash;
    #$hash = unpack( "H*", $hash );

    $t->save($torrent_with_path);
    print "Created: $torrent_with_path\n";
}

