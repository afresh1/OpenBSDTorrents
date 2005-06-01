#!/bin/sh
#$Id$

. /etc/OpenBSDTorrents.conf

cd ${OBT_DIR_HOME}
PIDFILE=${OBT_DIR_HOME}/run/regen.pid

if [ -e ${PIDFILE} ]; then
        PID=`head -1 ${PIDFILE}`
        kill -0 ${PID} 2> /dev/null
        if [ $? -eq 0 ]; then
                echo Already running
                exit 1
        fi
fi
echo $$ > ${PIDFILE}

if [[ $1 != skip ]]; then
	echo ${OBT_DIR_HOME}/MakeTorrents.pl $*
	${OBT_DIR_HOME}/MakeTorrents.pl $*
fi

echo ${OBT_DIR_HOME}/CurrentTorrents.pl
${OBT_DIR_HOME}/CurrentTorrents.pl

#if [ $? != 253 ]; then exit; fi

echo Removing old torrents
for f in `ls ${OBT_DIR_CUR_TORRENT}`; do
        if [ ! -e ${OBT_DIR_TORRENT}/$f ]; then
                rm ${OBT_DIR_CUR_TORRENT}/$f
        fi
done

echo ${OBT_DIR_HOME}/ServerTorrents.pl
${OBT_DIR_HOME}/ServerTorrents.pl

echo lftp -f ${OBT_DIR_HOME}/lftp.script
lftp -f ${OBT_DIR_HOME}/lftp.script

sleep 60;

echo Starting new torrents
for f in `ls ${OBT_DIR_TORRENT}`; do
        if [ ! -e ${OBT_DIR_CUR_TORRENT}/$f ]; then
                ln -s ${OBT_DIR_TORRENT}/$f ${OBT_DIR_CUR_TORRENT}/$f
        fi
done
