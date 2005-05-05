# $Id$
use strict;

package BT::MetaInfo::Cached;

require 5.6.0;
use vars qw( $VERSION @ISA );

use YAML;

#use Digest::SHA1 qw(sha1);
#use YAML qw/ DumpFile LoadFile /;

use Cache::FileCache;
use File::Basename;

use BT::MetaInfo;
use base 'BT::MetaInfo';

#use OpenBSDTorrents;

$VERSION = do { my @r = (q$Id$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

sub new
{
	my $class = shift;
        my $file  = shift;
	my $cache_settings = shift;

	$cache_settings->{namespace} ||= 'BT::MetaInfo::Cached';

	my $cache = new Cache::FileCache( $cache_settings );

        my $obj = (defined($file)) ? _load($file, $cache) : {};

	$obj->{cache} = $cache;

        return(bless($obj, $class));
}	

sub save {
	my ($self, $file) = @_;
	my $basename = basename($file);

	$self->SUPER::save($file, @_);

        my %info_hash = %$self; # unbless
	$self->cache->set->($basename, \%info_hash)
}

sub _load {
	my $file = shift;
	my $cache = shift;

	my $basename = basename($file);
	
	my $info = $cache->get( $basename );

	unless (defined $info) {
		$info = BT::MetaInfo::_load($file);
		$cache->set( $basename, $info );
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
