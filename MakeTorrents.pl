#!/usr/bin/perl
# -T
#$RedRiver: MakeTorrents.pl,v 1.22 2007/11/02 02:36:01 andrew Exp $
use strict;
use warnings;
use diagnostics;

use lib 'lib';
use BT::MetaInfo::Cached;
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
		next if $subdir =~ /^\./;
		Process_Dir("$basedir/$subdir")
	}
}

sub Make_Torrent
{
        my $basedir = shift;
        my $files   = shift;
        my $ignore_too_few = shift || 0;

	my $torrent_base = $basedir;
        my $comment = "Files from $torrent_base\n";
	if ($ignore_too_few && $files->[0] =~ /$INSTALL_ISO_REGEX/) {
		$torrent_base = "$basedir/$files->[0]";
		$comment = "$torrent_base\n";
	}
        elsif ($#{ $files } < $OBT->{MIN_FILES}) {
                print "Too few files in $basedir, skipping . . .\n";
                return undef;
        }

        if ($basedir !~ /\.\./ && $basedir =~ /^([\w\/\.-]+)$/) {
                $basedir = $1;
        } else {
                die "Invalid characters in dir '$basedir'";
        }

	my @good_files;
        foreach my $file (@$files) {
		if ((!$ignore_too_few) && $file =~ /$INSTALL_ISO_REGEX/) {
			my @f = ($file);
			#foreach my $f (@$files) {
			#	if ($f =~ /INSTALL|MD5/) {
			#		push @f, $f;
			#	}
			#}
			Make_Torrent($basedir, \@f, 1)
		}
                elsif ($file =~ /^([^\/]+)$/) {
                       	push @good_files, "$basedir/$1";
                } 
		else {
                        die "Invalid characters in file '$file' in '$basedir'";
                }
        }

        my $torrent = Name_Torrent($torrent_base);

        print "Creating $torrent\n";

	$comment .= "Created by andrew fresh (andrew\@afresh1.com)\n" .
                      "http://OpenBSD.somedomain.net/";

	eval { btmake($torrent, $comment, \@good_files); };
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

    #if (@$files == 1) {
        #$name = $files->[0];
    #}

    my $t = BT::MetaInfo::Cached->new(
        {
		cache_root => '/tmp/OBTFileCache'
        }
    );

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

    # Can't use this,  have to do this manually because 
    # we need to have the multi-file type of torrent
    # even when we have only one file.
    #$t->set_files(@$files);

    my @file_list;
    foreach my $f (@$files) {
    	my $l = (stat("$OBT->{DIR_FTP}/$f"))[7];
        my @p = split /\//, $f;
	shift @p;
	push @file_list, {
            length => $l,
            path   => \@p,
        }
    }
    $t->files(\@file_list);
    $t->make_pieces(@$files);

    if ($t->total_size < $OBT->{MIN_SIZE}) {
        print "Skipping smaller than minimum size\n";
        return 0;
    }

    my $hash = $t->info_hash;
    $hash = unpack("H*", $hash);

    $t->save($torrent_with_path);
    print "Created: $torrent_with_path\n";
}

