#!/bin/sh
#$Id$

btlaunchmany.py \
    --super_seeder 1 \
    --minport 10000 --maxport 10500 \
    --saveas /home/ftp/pub/ --saveas_style 2 \
    /home/andrew/torrents/

/home/andrew/OpenBSDTorrents/runbt.sh &
