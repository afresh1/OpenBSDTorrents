package BT::OBTMetaInfo;

require 5.6.0;
use strict;

use BT::MetaInfo;

$VERSION = do { my @r = (q$Revision$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

sub new
{
	my $classname	= shift;
	my $pass = shift;

	my $self	= $classname->SUPER::new(@_);
}	


sub info_hash { return(sha1(bencode($_[0]->info))); }

