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

if [ $? != 253 ]; then
	echo lftp -f ${OBT_DIR_HOME}/lftp.script
	lftp -f ${OBT_DIR_HOME}/lftp.script

	echo ${OBT_DIR_HOME}/ServerTorrents.pl
	${OBT_DIR_HOME}/ServerTorrents.pl
fi
