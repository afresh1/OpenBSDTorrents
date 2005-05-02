# $Id$
use strict;

package BT::OBTMetaInfo;

require 5.6.0;
use vars qw( $VERSION @ISA );

use Digest::SHA1 qw(sha1);
use Fcntl ':flock'; # import LOCK_* constants

use BT::MetaInfo;
use base 'BT::MetaInfo';

use OpenBSDTorrents;

use Data::Dumper;

$VERSION = do { my @r = (q$Id$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

sub new
{
	my $classname	= shift;
	return $classname->SUPER::new(@_);
}	


sub info_hash_cached 
{ 
	my $self = shift;
	my $torrent = shift;

	return $self->SUPER::info_hash unless $torrent;

	my $meta_file = $torrent;
	$meta_file =~ s/\.torrent$/.$OBT->{META_EXT}/;

	my $hash = undef;

	if (-e $meta_file) {
		#print "Reading meta file: $meta_file\n";
		open my $meta, $meta_file or die "Couldn't open $meta_file: $!";
		flock($meta, LOCK_SH);
		binmode $meta;

		$hash = do { local $/; <$meta> };

		flock($meta, LOCK_UN);
		close $meta;
	} else {
		$hash = $self->SUPER::info_hash;
		#print "Writing meta file: $meta_file\n";
		open my $meta, '>', $meta_file 
			or die "Couldn't open $meta_file: $!";
		flock($meta, LOCK_EX);
		binmode $meta;

		print $meta $hash;

		flock($meta, LOCK_UN);
		close $meta;

	}
	#my $text_hash = unpack("H*", $hash);
	#print "INFO_HASH: $text_hash\n";
	
	return $hash;
}

1
