#!/bin/sh
#$Id$

LOGFILE=runbt.log

echo -n `date` >> ${LOGFILE}
echo '	Starting . . . ' >> ${LOGFILE}

btlaunchmany.py \
    --super_seeder 1 \
    --minport 10000 --maxport 10500 \
    --saveas /home/ftp/pub/ --saveas_style 2 \
    /home/torrentsync/torrents/ > /dev/null

echo -n `date` >> ${LOGFILE}
echo '	Died . . . ' >> ${LOGFILE}

/home/OpenBSDTorrents/OpenBSDTorrents/runbt.sh &
