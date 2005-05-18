#!/bin/sh
#$Id$

. /etc/OpenBSDTorrents.conf
LOGFILE=/home/torrentseeder/runbt.log

cd ${OBT_DIR_HOME}
PIDFILE=${OBT_DIR_HOME}/run/runbt.pid

if [ -e ${PIDFILE} ]; then
        PID=`head -1 ${PIDFILE}`
        kill -0 ${PID} 2> /dev/null
        if [ $? -eq 0 ]; then
                echo Already running
                exit 1
        fi
fi
echo $$ > ${PIDFILE}


echo -n `date` >> ${LOGFILE}
echo '	Starting . . . ' >> ${LOGFILE}

nice btlaunchmany.py \
    --super_seeder 1 \
    --check_hashes 0 \
    --display_interval 60 \
    --minport 6881 --maxport 6989 \
    --max_files_open 75 \
    --saveas /home/ftp/pub/ --saveas_style 2 \
    /home/torrentsync/torrents/ >> ${LOGFILE}

echo -n `date` >> ${LOGFILE}
echo '	Died . . . ' >> ${LOGFILE}
