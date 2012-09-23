#!/usr/bin/perl
# -T
#$RedRiver: MakeTorrents.pl,v 1.26 2010/03/22 20:16:02 andrew Exp $
use strict;
use warnings;
use diagnostics;

use lib 'lib';
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
                $c = $f;
                $torrents{$t}{name} = $renamed;
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

        my $n = $torrents{$t}{name} || $OBT->{BASENAME};
        my $c = $torrents{$t}{comment};
        $c .= "\nCreated by andrew fresh (andrew\@afresh1.com)\n"
            . "http://OpenBSD.somedomain.net/";

        eval { btmake( $t, $n, $c, $torrents{$t}{files} ); };
        if ($@) {
            print "Error creating $t\n$@\n";
        }
    }

    return [ keys %torrents ];
}

sub btmake {
    my $torrent = shift;
    my $name    = shift;
    my $comment = shift;
    my $files   = shift;

    my $announce  = $OBT->{URL_TRACKER};
    my $web_seed  = $OBT->{URL_WEBSEED} . $name;
    my $piece_len = 2 << ( $OBT->{PIECE_LENGTH} - 1 );

    my $torrent_with_path = $OBT->{DIR_NEW_TORRENT} . "/$torrent";

    system '/usr/local/bin/mktorrent',
        '-a', $announce,
        '-w', $web_seed,
        '-n', $name,
        '-c', $comment,
        '-o', $torrent_with_path,
        @{$files};

    print "Created: $torrent_with_path\n";
}

