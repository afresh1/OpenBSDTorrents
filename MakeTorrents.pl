#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

use BT::MetaInfo;

use lib 'lib';
use OpenBSDTorrents;

%ENV = ();

use YAML;

my $Piece_Length = 18;
my $MinFiles = 5;

my $StartDir = shift || $BaseName;
$StartDir =~ s#/$##;

chdir($BaseDir) || die "Couldn't change dir to $BaseDir";

Process_Dir($StartDir);

sub Process_Dir
{
	my $basedir = shift;

	my ($dirs, $files) = Get_Files_and_Dirs($basedir);
	if (@$files) {
		my $torrent = Make_Torrent($basedir, $files);
	}

	# don't recurse if we were called on a specific directory
	return 1 if $StartDir ne $BaseName;

	foreach my $subdir (@$dirs) {
		next if $subdir eq '.';
		next if $subdir eq '..';
		Process_Dir("$basedir/$subdir")
	}
}

sub Make_Torrent
{
        my $basedir = shift;
        my $files   = shift;

        if ($#{ $files } < $MinFiles) {
                print "Too few files in $basedir, skipping . . .\n";
                return undef;
        }

        if ($basedir !~ /\.\./ && $basedir =~ /^([\w\/\.-]+)$/) {
                $basedir = $1;
        } else {
                die "Invalid characters in dir '$basedir'";
        }

        foreach (@$files) {
                if (/^([^\/]+)$/) {
                        $_ = "$basedir/$1";
                } else {
                        die "Invalid characters in file '$_' in '$basedir'";
                }
        }

        my $torrent = Name_Torrent($basedir);

        print "Creating $torrent\n";

        my $comment = "Files from $basedir\n" .
                      "Created by andrew fresh (andrew\@mad-techies.org)\n" .
                      "http://OpenBSD.somedomain.net/";

	btmake($torrent, $comment, $files);

#        system($BTMake,
#               '-C',
#               '-c', $comment,
#               '-n', $BaseName,
#               '-o', "$TorrentDir/$torrent",
#               '-a', $Tracker,
#               @$files
#        );# || die "Couldn't system $BTMake $torrent: $!";

        return $torrent;
}


# Stole and modified from btmake to work for this.
sub btmake {
    no locale;

    my $torrent = shift;
    my $comment = shift;
    my $files = shift;

    my $name = $BaseName;
    my $announce = $Tracker;
    my $piece_len = 2 << ($Piece_Length - 1);

    $torrent = "$TorrentDir/$torrent";

    my $t = BT::MetaInfo->new();
    $t->name($name);
    $t->announce($announce);
    unless ($announce =~ m!^http://[^/]+/!i) {
        warn "  [ WARNING: announce URL does not look like: http://hostname/ ]\n";
    }
    $t->comment($comment);
    #foreach my $pair (split(/;/, $::opt_f)) {
    #    if (my($key, $val) = split(/,/, $pair, 2)) {
    #        $t->set($key, $val);
    #    }
    #}
    $t->piece_length($piece_len);
    $t->creation_date(time);
    warn "Checksumming files. This may take a little while...\n";
    $t->set_files(@$files);
    $t->save("$torrent");
    print "Created: $torrent\n";
    #system("btinfo $torrent") if ($::opt_I);
}

