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

nice btlaunchmany \
    --check_hashes 0 \
    --display_interval 600 \
    --minport 6881 --maxport 6989 \
    --max_files_open 75 \
    --saveas_style 2 \
    --save_in ${OBT_DIR_FTP} \
    --torrent_dir ${OBT_DIR_CUR_TORRENT} >> ${LOGFILE}

echo -n `date` >> ${LOGFILE}
echo '	Died . . . ' >> ${LOGFILE}
