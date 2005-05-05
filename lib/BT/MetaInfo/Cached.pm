# $Id$
use strict;

package BT::OBTMetaInfo;

require 5.6.0;
use vars qw( $VERSION @ISA );

use Digest::SHA1 qw(sha1);
use YAML qw/ DumpFile LoadFile /;

use BT::MetaInfo;
use base 'BT::MetaInfo';

use OpenBSDTorrents;

$VERSION = do { my @r = (q$Id$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

sub new
{
	my $class = shift;
        my $file  = shift;

        my $obj = (defined($file)) ? _load($file, @_) : {};
        return(bless($obj, $class));
}	

sub _load {
	my $file = shift;
	my $meta_file = shift;
	my $regen = shift;
	
	my $info;
	if ($meta_file && ! $regen && -e $meta_file) {
		$info = LoadFile($meta_file);
	}

	unless ($info) {
		$info = BT::MetaInfo::_load($file);
		DumpFile($meta_file, $info) if $meta_file;
	}

	return $info;
}

#sub cached
#{
#	my $self = shift;
#        my $which_info = shift;
#	my $file = shift;
#	my @args = @_;
#
#	if (@args) {
#		return $self->$which_info(@args),
#	}
#
#	return undef unless $which_info;
#	return $self->$which_info unless $file;
#
#	my $info = undef;
#
#	if (-e $file) {
#		#print "Reading meta file: $file\n";
#		$info = LoadFile($file);
#	}
#
#	unless ($info->{$which_info}) {
#		my $cur_info = $self->$which_info;
#
#		$info->{$which_info} = $cur_info;
#		DumpFile($file, $info);
#	}
#
#	if (defined $info->{$which_info}) {
#		return $info->{$which_info};
#	} else {
#		return $self->$which_info;
#	}
#}

1
