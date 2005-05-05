# $Id$
use strict;

package BT::MetaInfo::Cached;

require 5.6.0;
use vars qw( $VERSION @ISA );

use Cache::FileCache;
use File::Basename;

use BT::MetaInfo;
use base 'BT::MetaInfo';

$VERSION = do { my @r = (q$Id$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

sub new
{
	my $class = shift;
        my $file  = shift;
	my $cache_settings = shift;

	$cache_settings->{namespace} ||= 'BT::MetaInfo::Cached';

	my $cache = new Cache::FileCache( $cache_settings );

	my $obj = (defined($file)) ? _load($file, $cache) : {};

	bless($obj, $class);

	$obj->{cache} = $cache;

        return $obj;
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


sub save
{
	my $self = shift;
	my $file = shift;
	my $basename = basename($file);

	my $cache = delete $self->{cache};

	if ( $self->SUPER::save($file, @_) ) {
		my %info_hash = %$self; # unbless
		$cache->set($basename, \%info_hash)
	}

	$self->{cache} = $cache;
}
