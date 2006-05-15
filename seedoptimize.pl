#!/usr/bin/perl
#$RedRiver: seedoptimize.pl,v 1.1 2005/05/05 00:46:09 andrew Exp $
use strict;
use warnings;

use YAML;
use File::Basename;
use Fcntl ':flock';

use constant {
    HEAP => 0,
    ARG0 => 1,
    ARG1 => 2,
    KERNEL => 5,
};

use lib 'lib';
use OpenBSDTorrents;

my $out_dir = $OBT->{DIR_FTP};

my $download_bin = '/usr/local/bin/btget';
my @download_opts = (
        '-s',
        '-v',
);

sub MAX_CONCURRENT_TASKS () { 25 }

my @Torrents = Get_Torrents();

$SIG{CHLD} = 'IGNORE';

chdir $out_dir or die "couldn't chdir to $out_dir: $!";

print "Starting . . . .\n";

my @data = <DATA>;
my %heap = (
    task => {
        1 => {
            torrent => '/home/torrentsync/torrents/OpenBSD_songs-2005-05-02-2127.torrent',
        },
    },
);

foreach (@data) {
    handle_task_result(\%heap, $_, 1);
}

# Handle information returned from the task. 
# 
# output from btget should be like the following:
#
#$ btget -sv /home/torrentsync/torrents/OpenBSD_songs-2005-05-02-2127.torrent
#389 of 390 completed (389 ok)
#Total good pieces 390 (100%)
#Total archive size 102225004
#completed+00000:ffffffff ffffffff ffffffff ffffffff ffffffff ffffffff
#completed+00024:ffffffff ffffffff ffffffff ffffffff ffffffff ffffffff
#completed+00048:fc
#
#get http://OpenBSD.somedomain.net/announce....
#Interval 1800
#Parsing compact peer list
#5: 66.185.225.45:8888 : incomplete
#3: Server ready...
#6: New peer connected 66.185.225.156
#5: completed connection 66.185.225.45
#Time 1115071457
# 4  66.185.225.156:6881 (OUT)[Cibr    1s( 20bps)^-001+0][Cibr    1s(122bps)_0]
# 5   66.185.225.45:8888 (OUT)[Cibr    1s(  0bps)^-001+0][Cibr    1s(122bps)_0]
# 6  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
#100% (390 of 390) 1 Peers, Download 0bps Upload 0bps


sub handle_task_result {
    my ($heap, $result, $task_id) = @_[HEAP, ARG0, ARG1];
    #print $heap->{task}->{$task_id}->{torrent}, " - ";
    #print "$result\n";
    #print Dump $result;

    my $task    = $heap->{task}->{$task_id};
    my $torrent = $task->{torrent};

    if ($result eq '----') {
        # do nothing
    } elsif ($result =~
        /
        ^\s+(\d+)     # 6
        \s+([\d\.]+)  # 66.185.225.156
        :(\d+)        # :0
        \s+\((\w+)\)  # (ALL)
        \[\w+\s+\w+   # [Cibr 1s
        \(\s*(\w+)\)  # (122bps)
        \^-([\d\+]+)  # ^-001+0
        \]            # ]
        \[\w+\s+\w+^? # [Cibr 1s
        \(\s*(\w+)\)  # (122bps)
        _\d+          # _0
        \]            # ]
        /x
    ) {
	my $peer_id = $1;
        my %peer = (
	    Time     => $task->{status}->{Time},
	    peer_id  => $peer_id,
	    ip       => $2,
	    port     => $3,
	    complete => $4,
	    speed    => $5,
	    offset   => $6,
	    speed_2  => $7,
            offset_2 => $8,
	);
	$task->{peers}->{$peer_id} = \%peer;
    } elsif ($result =~ /^Time\s+(\d+)/) {
        my $this_time = $1;
        $task->{status}->{Time} = $this_time;
        defined $heap->{last_time} or $heap->{last_time} = 0;
        defined $task->{last_time} or $task->{last_time} = 0;

        if ($task->{last_time} <= ($this_time - 30)) {
            #print "Would log stats for ", $task->{torrent}, "\n";
	    myLog($torrent, { 
                Torrent => $task->{torrent}, 
                Status  => $task->{status}, 
                Peers   => $task->{peers},
	    });
            $task->{last_time} = $this_time;
        }

        if ($heap->{last_time} < ($this_time - 60)) {
            #myLog($0, "Updating torrent list");
            print scalar localtime, "\t",
                  "Seeding ", 
                  (scalar keys %{ $heap->{task} }), 
                  " torrents\n";
            Update_Torrent_List($heap);
            $heap->{last_time} = $this_time;
        }
    } elsif ($result =~
        /
        ^(\d+)\%
        .*
        \s(\d+)\s+Peers
        .*
        Download\s+(\w+)\s
        .*
        Upload\s+(\w+)\s
        /x
    ) {
        $task->{status}->{Percent}  = $1;
        $task->{status}->{Peers}    = $2;
        $task->{status}->{Download} = $3;
        $task->{status}->{Upload}   = $4;
    } elsif ($result =~ /^Total good pieces.*\D(\d+)\D+(\d+)\%/) {
        die "Good pieces for $torrent not 100% ($2)!: $_" if ($2 != 100);
        $task->{status}->{Good_Pieces        } = $1;
        $task->{status}->{Good_Pieces_Percent} = $2;
    } elsif ($result =~ /^Total\sarchive\ssize\s+(\d+)/) {
        $task->{status}->{Archive_Size} = $1;
    } elsif ($result =~ /^Interval\s+(\d+)/) {
        $task->{status}->{Interval} = $1;
    } elsif ($result =~ /^Tracker shutdown complete$/) {
        myLog($0, "Tracker for torrent '$torrent' shut down");
    } else { 
        #print $result, "\n";
    }
}

# Catch and display information from the child's STDERR.  This was
# being displayed otherwise.

sub handle_task_debug {
    my ($heap, $result, $task_id) = @_[HEAP, ARG0, ARG1];

    if ($result =~ /^Parsing compact peer list$/) {
	return undef;
    }

    if ($result =~ /Peer disconnected after repeated errors/) {
        return undef;
    }

    if ($result =~ /Unable to load/) {
        myLog($0, 
              "Unable to load torrent " . $heap->{task}->{$task_id}->{torrent});
        $heap->{task}->{$task_id}->{task}->kill;
    }

    myLog($0, "Debug: " . $heap->{task}->{$task_id}->{torrent}, "\t$result");
}

# The task is done.  Delete the child wheel, and try to start a new
# task to take its place.

sub handle_task_done {
    my ( $kernel, $heap, $task_id ) = @_[ KERNEL, HEAP, ARG0 ];
    myLog($0, "Finished with $heap->{task}->{$task_id}->{torrent}");
    delete $heap->{task}->{$task_id};
    $kernel->yield("next_task");
}

sub handle_task_cleanup
{
    my ($heap, $kernel) = @_[ HEAP, KERNEL ];
    foreach my $id (keys %{ $heap->{task} }) {
        myLog($0,"Killing ", $heap->{task}->{$id}->{torrent});
        $heap->{task}->{$id}->{task}->kill;
    }
}

# Look at what torrents are around, add new ones to the task list and 
# kill old ones

sub Update_Torrent_List
{
    my $heap = shift;
    my @current = Get_Torrents();

    my %cur;
    @cur{@current} = ();

    my @new;

    my %run;
    foreach my $id (keys %{ $heap->{task} }) {
	my $torrent = $heap->{task}->{$id}->{torrent};
        if (exists $cur{$torrent}) {
	    $run{$torrent} = 1;
	} else {
	    #$heap->{task}->{$id}->{task}->kill;
	}
    }

    my %old;
    foreach my $torrent (@Torrents) {
	if (exists $cur{$torrent}) {
	    $old{$torrent} = 1;
	    push @new, $torrent;
	}
    } 

    foreach my $tor (keys %cur) {
	if (exists $run{$tor}) {
	    # skip, already running
	} elsif (exists $old{$tor}) {
	    # skip, already waiting
        } else {
	    push @new, $tor;
	}
    }

    @Torrents = @new;
}

sub Get_Torrents
{
    my $torrent_dir = $OBT->{DIR_TORRENT};
    opendir DIR, $torrent_dir or die "Couldn't opendir $torrent_dir: $!";
    my @torrents = sort grep { /\.torrent$/i } readdir DIR;
    closedir DIR;
    return @torrents;
}

sub myLog
{
    my ($fullname, @message) = @_;
    my ($name,$path,$suffix) = fileparse($fullname, '.torrent', '.pl');
    #print "Logging to $name had ext $suffix\n";
    my $open_type = '>>';
    if ($suffix eq '.torrent') {
	$open_type = '>';
    }

    open my $FILE, $open_type, $OBT->{DIR_LOG_TORRENT} . '/' . $name . '.log'
	or die "Couldn't open file $name.log: $!";
    flock($FILE,LOCK_EX);
    seek($FILE, 0, 2);
    foreach (@message) {
        print $FILE scalar localtime;
        if (ref $_) {
            print $FILE "\n";
            print $FILE Dump $_;
        } else {
            print $FILE "\t";
            print $FILE $_, "\n";
        }
    }
    flock($FILE,LOCK_UN);
    close $FILE;
}

# Run until there are no more tasks.
#$poe_kernel->run();

print "Finished\n";

__DATA__
0 of 390 completed (0 ok)10 of 390 completed (10 ok)20 of 390 completed (20 ok)30 of 390 completed (30 ok)40 of 390 completed (40 ok)50 of 390 completed (50 ok)60 of 390 completed (60 ok)70 of 390 completed (70 ok)80 of 390 completed (80 ok)90 of 390 completed (90 ok)100 of 390 completed (100 ok)110 of 390 completed (110 ok)120 of 390 completed (120 ok)130 of 390 completed (130 ok)140 of 390 completed (140 ok)150 of 390 completed (150 ok)160 of 390 completed (160 ok)170 of 390 completed (170 ok)180 of 390 completed (180 ok)190 of 390 completed (190 ok)200 of 390 completed (200 ok)210 of 390 completed (210 ok)220 of 390 completed (220 ok)230 of 390 completed (230 ok)240 of 390 completed (240 ok)250 of 390 completed (250 ok)260 of 390 completed (260 ok)270 of 390 completed (270 ok)280 of 390 completed (280 ok)290 of 390 completed (290 ok)300 of 390 completed (300 ok)310 of 390 completed (310 ok)320 of 390 completed (320 ok)330 of 390 completed (330 ok)340 of 390 completed (340 ok)350 of 390 completed (350 ok)360 of 390 completed (360 ok)370 of 390 completed (370 ok)380 of 390 completed (380 ok)386 of 390 completed (386 ok)387 of 390 completed (387 ok)388 of 390 completed (388 ok)389 of 390 completed (389 ok)
Total good pieces 390 (100%)
Total archive size 102225004
completed+00000:ffffffff ffffffff ffffffff ffffffff ffffffff ffffffff
completed+00024:ffffffff ffffffff ffffffff ffffffff ffffffff ffffffff
completed+00048:fc

get http://OpenBSD.somedomain.net/announce.php?info_hash=%2b%d9%df%da%0a%14%d4%2f%cc%b7%0c%af%39%b5%7d%ac%64%4a%05%d1&peer_id=%33%33%c8%98%29%80%d5%70%93%46%75%ae%e2%3f%3b%7d%cb%78%71%4f&key=%ee%58%0f%93%9e%00%11%56&port=6881&uploaded=0&downloaded=0&left=0&event=started&compact=1
Interval 1800
3: Server ready...
5: New peer connected 66.185.225.156
Time 1115253132
 4  66.185.225.156:6881 (OUT)[Cibr    1s( 20bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 1 Peers, Download 0bps Upload 0bps
----
Time 1115253133
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253134
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253135
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253136
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253137
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253138
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253139
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253140
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253141
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253142
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253143
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253144
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253145
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253146
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253147
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253148
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253149
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253150
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253151
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253152
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253153
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253154
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253155
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253156
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253157
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253158
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253159
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253160
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253161
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253162
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253163
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253164
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253165
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253166
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253167
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253168
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253169
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253170
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253171
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253172
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253173
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253174
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253175
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253176
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253177
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253178
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253179
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253180
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253181
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253182
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253183
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253184
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253185
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253186
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253187
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253188
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253189
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253190
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253191
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253192
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253193
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253194
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253195
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253196
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253197
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253198
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253199
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253200
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253201
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253202
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253203
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253204
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253205
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253206
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253207
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253208
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253209
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253210
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253211
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253212
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253213
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253214
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253215
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253216
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253217
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253218
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253219
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253220
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253221
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253222
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253223
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253224
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253225
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253226
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253227
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253228
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253229
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253230
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253231
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253232
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253233
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253234
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253235
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253236
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253237
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253238
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253239
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253240
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253241
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253242
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253243
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253244
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253245
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253246
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253247
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253248
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253249
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253250
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253251
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253252
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253253
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253254
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253255
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253256
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253257
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253258
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253259
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253260
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253261
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253262
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253263
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253264
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253265
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253266
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253267
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253268
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253269
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253270
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253271
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253272
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253273
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253274
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253275
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253276
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253277
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253278
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253279
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253280
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253281
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253282
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253283
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253284
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253285
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253286
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253287
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253288
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253289
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253290
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253291
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253292
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253293
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253294
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253295
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253296
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253297
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253298
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253299
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253300
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253301
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253302
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253303
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253304
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253305
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253306
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253307
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253308
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253309
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253310
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253311
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253312
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253313
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253314
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253315
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253316
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253317
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253318
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253319
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253320
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253321
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253322
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253323
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253324
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253325
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253326
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253327
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253328
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253329
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253330
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253331
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253332
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253333
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253334
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253335
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253336
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253337
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253338
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253339
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253340
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253341
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253342
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253343
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253344
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253345
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253346
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253347
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253348
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253349
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253350
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253351
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253352
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253353
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253354
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253355
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253356
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253357
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253358
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253359
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253360
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253361
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253362
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253363
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253364
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253365
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253366
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253367
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253368
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253369
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253370
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253371
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253372
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253373
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253374
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253375
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253376
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253377
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253378
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253379
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253380
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253381
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253382
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253383
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253384
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253385
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253386
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253387
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253388
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253389
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253390
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253391
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253392
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253393
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253394
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253395
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253396
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253397
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253398
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253399
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253400
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253401
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253402
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253403
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253404
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253405
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253406
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253407
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253408
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253409
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253410
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253411
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253412
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253413
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253414
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253415
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253416
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253417
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253418
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253419
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253420
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253421
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253422
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253423
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253424
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253425
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253426
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253427
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253428
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253429
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253430
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253431
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253432
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253433
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253434
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253435
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253436
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253437
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253438
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253439
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253440
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253441
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253442
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253443
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253444
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253445
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253446
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253447
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253448
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253449
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253450
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253451
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253452
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253453
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253454
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253455
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253456
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253457
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253458
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253459
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253460
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253461
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253462
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253463
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253464
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253465
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253466
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253467
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253468
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253469
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253470
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253471
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253472
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253473
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253474
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253475
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253476
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253477
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253478
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253479
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253480
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253481
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253482
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253483
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253484
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253485
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253486
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253487
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253488
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253489
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253490
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253491
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253492
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253493
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253494
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253495
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253496
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253497
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253498
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253499
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253500
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253501
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253502
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253503
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253504
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253505
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253506
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253507
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253508
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253509
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253510
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253511
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253512
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253513
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253514
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253515
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253516
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253517
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253518
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253519
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253520
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253521
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253522
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253523
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253524
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253525
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253526
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253527
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253528
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253529
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253530
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253531
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253532
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253533
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253534
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253535
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253536
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253537
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253538
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253539
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253540
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253541
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253542
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253543
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253544
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253545
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253546
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253547
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253548
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253549
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253550
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253551
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253552
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253553
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253554
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253555
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253556
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253557
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253558
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253559
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253560
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253561
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253562
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253563
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253564
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253565
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253566
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253567
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253568
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253569
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253570
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253571
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253572
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253573
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253574
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253575
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253576
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253577
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253578
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253579
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253580
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253581
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253582
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253583
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253584
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253585
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253586
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253587
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253588
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253589
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253590
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253591
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253592
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253593
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253594
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253595
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253596
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253597
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253598
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253599
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253600
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253601
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253602
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253603
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253604
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253605
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253606
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253607
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253608
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253609
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253610
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253611
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253612
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253613
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253614
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253615
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253616
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253617
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253618
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253619
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253620
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253621
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253622
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253623
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253624
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253625
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253626
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253627
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253628
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253629
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253630
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253631
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253632
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253633
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253634
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253635
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253636
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253637
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253638
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253639
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253640
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253641
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253642
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253643
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253644
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253645
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253646
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253647
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253648
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253649
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253650
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253651
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253652
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253653
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253654
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253655
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253656
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253657
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253658
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253659
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253660
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253661
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253662
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253663
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253664
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253665
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253666
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253667
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253668
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253669
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253670
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253671
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253672
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253673
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253674
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253675
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253676
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253677
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253678
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253679
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253680
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253681
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253682
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253683
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253684
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253685
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253686
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253687
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253688
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253689
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253690
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253691
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253692
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253693
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253694
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253695
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253696
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253697
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253698
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253699
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253700
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253701
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253702
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253703
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253704
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253705
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253706
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253707
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253708
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253709
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253710
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253711
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253712
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253713
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253714
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253715
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253716
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253717
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253718
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253719
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253720
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253721
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253722
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253723
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253724
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253725
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253726
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253727
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253728
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253729
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253730
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253731
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253732
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253733
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253734
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253735
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253736
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253737
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253738
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253739
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253740
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253741
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253742
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253743
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253744
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253745
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253746
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253747
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253748
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253749
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253750
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253751
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253752
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253753
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253754
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253755
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253756
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253757
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253758
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253759
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253760
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253761
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253762
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253763
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253764
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253765
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253766
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253767
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253768
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253769
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253770
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253771
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253772
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253773
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253774
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253775
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253776
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253777
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253778
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253779
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253780
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253781
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253782
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253783
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253784
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253785
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253786
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253787
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253788
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253789
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253790
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253791
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253792
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253793
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253794
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253795
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253796
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253797
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253798
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253799
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253800
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253801
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253802
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253803
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253804
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253805
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253806
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253807
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253808
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253809
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253810
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253811
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253812
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253813
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253814
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253815
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253816
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253817
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253818
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253819
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253820
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253821
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253822
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253823
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253824
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253825
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253826
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253827
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253828
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253829
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253830
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253831
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253832
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253833
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253834
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253835
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253836
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253837
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253838
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253839
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253840
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253841
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253842
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253843
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253844
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253845
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253846
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253847
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253848
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253849
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253850
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253851
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253852
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253853
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253854
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253855
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253856
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253857
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
Time 1115253858
 4  66.185.225.156:6881 (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
 5  66.185.225.156:0    (ALL)[Cibr    1s(122bps)^-001+0][Cibr    1s(122bps)_0]
100% (390 of 390) 2 Peers, Download 0bps Upload 0bps
----
get http://OpenBSD.somedomain.net/announce.php?info_hash=%2b%d9%df%da%0a%14%d4%2f%cc%b7%0c%af%39%b5%7d%ac%64%4a%05%d1&peer_id=%33%33%c8%98%29%80%d5%70%93%46%75%ae%e2%3f%3b%7d%cb%78%71%4f&key=%ee%58%0f%93%9e%00%11%56&port=6881&uploaded=0&downloaded=0&left=0&event=stopped&compact=1
Tracker shutdown complete
