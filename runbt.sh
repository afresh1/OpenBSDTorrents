#!/bin/sh
#$RedRiver: runbt.sh,v 1.15 2006/05/27 04:31:48 andrew Exp $

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

nice launchmany-console \
    --display_interval 600 \
    --minport 60881 --maxport 60981 \
    --max_files_open 25 \
    --saveas_style 2 \
    --save_in ${OBT_DIR_FTP} \
    --torrent_dir ${OBT_DIR_CUR_TORRENT} >> ${LOGFILE}

echo -n `date` >> ${LOGFILE}
echo '	Died . . . ' >> ${LOGFILE}
