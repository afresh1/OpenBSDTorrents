#!/bin/sh
#$Id$

LOGFILE=runbt.log

echo -n `date` >> ${LOGFILE}
echo '	Starting . . . ' >> ${LOGFILE}

btlaunchmany.py \
    --super_seeder 1 \
    --minport 10000 --maxport 10500 \
    --max_files_open 75 \
    --saveas /home/ftp/pub/ --saveas_style 2 \
    /home/torrentsync/torrents/ >> ${LOGFILE}

echo -n `date` >> ${LOGFILE}
echo '	Died . . . ' >> ${LOGFILE}

/home/OpenBSDTorrents/runbt.sh &
