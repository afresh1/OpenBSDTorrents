# $Id$
use strict;

package BT::MetaInfo::Cached;

require 5.6.0;
use vars qw( $VERSION @ISA );

use Cache::FileCache;
use File::Basename;
use Digest::MD5;

use BT::MetaInfo;
use base 'BT::MetaInfo';

$VERSION = do { my @r = (q$Id$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

sub new
{
	my $class = shift;
        my $file  = shift;
	my $cache_settings = shift;

	if (ref $file eq 'HASH') {
		$cache_settings = $file;
		$file = undef;
	}

	$cache_settings->{namespace}           ||= 'BT::MetaInfo::Cached';
	$cache_settings->{default_expires_in}  ||=  7 * 24 * 60 * 60;
	$cache_settings->{auto_purge_interval} ||=  1 *  1 * 10 * 60;

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

	my $md5;
	if (defined $info && $info->{'md5'}) {
		my $old_md5 = delete $info->{'md5'};
		my $cur_md5 = _MD5_file($file);
		if ($old_md5 ne $cur_md5) {
			$cache->remove( $basename );
			$info = undef;
		}
		$md5 = $cur_md5;
	}

	unless (defined $info) {
		$info = BT::MetaInfo::_load($file);
		$info->{'md5'} = $md5;
		$cache->set( $basename, $info );
		delete $info->{'md5'};
	}

	return $info;
}


sub save
{
	my $self = shift;
	my $file = shift;
	my $basename = basename($file);

	my $cache   = delete $self->{'cache'};

	if ( $self->SUPER::save($file, @_) ) {
		my %info_hash = %$self; # unbless

		$info_hash{'md5'} = _MD5_file($file);
		$cache->set($basename, \%info_hash)
	}

	$self->{'cache'} = $cache;

	return 1;
}

sub _MD5_file
{
	my $file = shift;

	my $ctx = Digest::MD5->new;
	open my $fh, $file or die "Couldn't open FILE '$file': $!";
	binmode $fh;
	$ctx->addfile($fh);
	close $fh;

	return $ctx->hexdigest;
}
