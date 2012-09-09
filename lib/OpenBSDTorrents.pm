package OpenBSDTorrents;
#$RedRiver: OpenBSDTorrents.pm,v 1.14 2010/05/19 22:19:43 andrew Exp $
use 5.008005;
use strict;
use warnings;

require Exporter;

our @ISA = qw(Exporter);

our $VERSION = '0.01';

our @EXPORT = qw(
	$OBT
	$INSTALL_ISO_REGEX
	$SONG_REGEX
	&Name_Torrent
	&Get_Files_and_Dirs
	&justme
);

my $config_file = '/etc/OpenBSDTorrents.conf';
our $OBT = Config();
our $INSTALL_ISO_REGEX = qr/ \b install\d+\.iso \b /xms;
our $SONG_REGEX        = qr/^song.*\.([^\.]+)$/xms;

sub Config
{
	my %config;
	open FILE, $config_file or die "Couldn't open FILE $config_file: $!";
	while (<FILE>) {
		chomp;
		s/#.*$//;
		s/\s+$//;
		next unless $_;
		my ($name, $val) = split /=/, $_, 2;
		$name =~ s/^OBT_//;
		# This should really look for contents that are a 
		# bit safer, but I can't think of what would work here.
		if ($val =~ /^(.*)$/) {
			$config{$name} = $1;
			$config{$name} =~ s/^['"]|["']$//gxms;
		}
	}
	close FILE;
	return \%config;
}

sub Name_Torrent
{
	my $torrent = shift;

	my $date = Torrent_Date();

	$torrent =~ s/^\W+//;
	$torrent =~ s/\W/_/g;
	$torrent .= '-' . $date;
	$torrent .= '.torrent';

	return $torrent;
}


sub Get_Files_and_Dirs
{
	my $basedir = shift;

	if ( -f $basedir ) {
		$basedir =~ s{^.*/}{}xms;
		return [], [ $basedir ];
	}

	opendir DIR, $basedir or die "Couldn't opendir $basedir: $!";
	my @contents = sort grep { ! /^\.\.$/ } grep { ! /^\.$/ } readdir DIR;
	closedir DIR;

	my @dirs;
	my @files;
	ITEM: foreach my $item (@contents) {
		if ( -d "$basedir/$item" ) {
			if ( $OBT->{SKIP_DIRS} 
			  && $item =~ /$OBT->{SKIP_DIRS}/) {
				next ITEM;
			}
			push @dirs, $item;
		}
		else {
			if ( $OBT->{SKIP_FILES} 
                         && $item =~ /$OBT->{SKIP_FILES}/) {
				next ITEM;
			}
    			push @files, $item;
		}
	}

	return \@dirs, \@files;
}

sub Torrent_Date
{
	my ($min, $hour, $mday, $mon, $year) = (gmtime)[1..5];
	$mon++;
	$year += 1900;
	foreach ($min, $hour, $mday, $mon) {
		if (length $_ == 1) {
			$_ = '0' . $_;
		}
	}
	return join '-', ($year, $mon, $mday, $hour . $min);
}

# "There can be only one."  --the Highlander
sub justme {

	my $myname;

	if ($0 =~ m#([^/]+$)#) {
		$myname = $1;
	} else {
		die "Couldn't figure out myname";
	}

	my $SEMA = $OBT->{DIR_HOME} . "/run/$myname.pid";
        if (open SEMA, "<", $SEMA) {
                my $pid = <SEMA>;
                if (defined $pid) {
                        chomp $pid;
			if ($pid =~ /^(\d+)$/) {
				$pid = $1;
			} else { 
				die "invalid pid read '$pid'";
			}
                        if (kill(0, $pid)) {
                              print "$0 already running (pid $pid), bailing out\n";
                              exit 253;
                        }
                }
                close SEMA;
        }
        open (SEMA, ">", $SEMA)      or die "can't write $SEMA: $!";
        print SEMA "$$\n";
        close(SEMA)                    or die "can't close $SEMA: $!";
}


1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

OpenBSDTorrents - Perl extension for blah blah blah

=head1 SYNOPSIS

  use OpenBSDTorrents;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for OpenBSDTorrents, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.


=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Andrew Fresh, E<lt>andrew@E<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005 by Andrew Fresh

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.5 or,
at your option, any later version of Perl 5 you may have available.


=cut
