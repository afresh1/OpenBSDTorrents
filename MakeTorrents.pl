#!/usr/bin/perl
# -T
#$RedRiver: MakeTorrents.pl,v 1.26 2010/03/22 20:16:02 andrew Exp $
use strict;
use warnings;
use diagnostics;

use File::Basename qw( dirname );
use File::Path qw( make_path );

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

    # Only source from inside the actual baedir
    return unless $basedir =~ /^\Q$OBT->{BASENAME}\E\//;

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
                $f = $renamed;
            }
            elsif ( my ($ext) = $file =~ /$SONG_REGEX/xms ) {
                my $destdir = dirname($f) . '/' . $ext;
                $destdir =~ s{/}{_}g;

                my $root     = $OBT->{DIR_FTP};
                my $destfile = "$destdir/$file";

                make_path("$root/$destdir");
                unlink "$root/$destfile" if -e "$root/$destfile";
                link "$root/$f", "$root/$destfile"
                    or die "Couldn't link $root/{$f to $destfile}: $!";

                $t = Name_Torrent($destdir);
                $f = $destfile;
                $c = "$ext files from $basedir";

                $torrents{$t}{dir} = $destdir;
            }
            else {
                $torrents{$t}{dir} = $basedir;
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

        eval { btmake( $t, $torrents{$t} ); };
        warn "Error creating $t\n$@\n" if $@;
    }

    return [ keys %torrents ];
}

sub btmake {
    my ($t, $opts) = @_;

    my $source  = $opts->{dir} || $opts->{files}->[0];

    my $torrent_with_path = $OBT->{DIR_NEW_TORRENT} . "/$t";
    my $announce  = $OBT->{URL_TRACKER};
    my $web_seed  = $OBT->{URL_WEBSEED};
    $web_seed .= $source if @{ $opts->{files} } == 1;

    my $comment = join "\n", $opts->{comment},
        'Created by andrew fresh (andrew@afresh1.com)',
        'http://OpenBSD.somedomain.net/';

    system '/usr/local/bin/mktorrent',
        '-o', $torrent_with_path,
        '-a', $announce,
        '-w', $web_seed,
        '-c', $comment,
        $source;

    print "Created: $torrent_with_path\n";
}

