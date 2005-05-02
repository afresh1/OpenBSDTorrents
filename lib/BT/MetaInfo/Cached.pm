# $Id$
use strict;

package BT::OBTMetaInfo;

require 5.6.0;
use vars qw( $VERSION @ISA );

use BT::MetaInfo;

use Data::Dumper;

$VERSION = do { my @r = (q$Id$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

sub new
{
	my $classname	= shift;
	print Dumper $classname;
	exit;

#	my $self	= $classname->SUPER::new(@_);
}	


sub info_hash { return(sha1(bencode($_[0]->info))); }

1
