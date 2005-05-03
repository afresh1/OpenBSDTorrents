#!/usr/bin/perl -T
#$Id$
use strict;
use warnings;
use diagnostics;

use lib 'lib';
use BT::OBTMetaInfo;
use OpenBSDTorrents;

%ENV = ();

chdir($OBT->{DIR_FTP}) || die "Couldn't change dir to " . $OBT->{DIR_FTP} . ": $!";

my $StartDir = '';
if (@ARGV) {
	foreach (@ARGV) {
		s#/$##;
		Process_Dir($_);
	}
} else {
	$StartDir = $OBT->{BASENAME};
	Process_Dir($StartDir);
}



sub Process_Dir
{
	my $basedir = shift;

	#return undef if $basedir =~ /packages/;

	my ($dirs, $files) = Get_Files_and_Dirs($basedir);
	if (@$files) {
		my $torrent = Make_Torrent($basedir, $files);
	}

	# don't recurse if we were started with a specific directory
	return 1 if $StartDir ne $OBT->{BASENAME};

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

        if ($#{ $files } < $OBT->{MIN_FILES}) {
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

	eval { btmake($torrent, $comment, $files); };
	if ($@) {
		print "Error creating $torrent\n$@\n";
	}

#        system($BTMake,
#               '-C',
#               '-c', $comment,
#               '-n', $OBT->{BASENAME},
#               '-o', $OBT->{DIR_TORRENT} . "/$torrent",
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

    my $name = $OBT->{BASENAME};
    my $announce = $OBT->{URL_TRACKER};
    my $piece_len = 2 << ($OBT->{PIECE_LENGTH} - 1);

    my $torrent_with_path = $OBT->{DIR_NEW_TORRENT} . "/$torrent";

    my $t = BT::OBTMetaInfo->new();
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
    print "Checksumming files. This may take a little while...\n";
    $t->set_files(@$files);

    if ($t->total_size < $OBT->{MIN_SIZE}) {
        print "Skipping smaller than minimum size\n";
        return 0;
    }

    my $hash = $t->info_hash_cached($torrent_with_path);
    $hash = unpack("H*", $hash);

    $t->save($torrent_with_path);
    print "Created: $torrent_with_path\n";
}

