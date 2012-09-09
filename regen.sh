#!/bin/sh
#$RedRiver: regen.sh,v 1.10 2010/03/08 20:19:37 andrew Exp $

. /etc/OpenBSDTorrents.conf

cd ${OBT_DIR_HOME}
PIDFILE=${OBT_DIR_HOME}/run/regen.pid

if [ -e ${PIDFILE} ]; then
        PID=`head -1 ${PIDFILE}`
        kill -0 ${PID} 2> /dev/null
        if [ $? -eq 0 ]; then
                echo $0 Already running
                exit 1
        fi
fi
echo $$ > ${PIDFILE}

if [[ $1 != skip ]]; then
	echo 
	echo ${OBT_DIR_HOME}/MakeTorrents.pl $*
	${OBT_DIR_HOME}/MakeTorrents.pl $*
fi

echo 
echo ${OBT_DIR_HOME}/CurrentTorrents.pl
${OBT_DIR_HOME}/CurrentTorrents.pl

#if [ $? != 253 ]; then exit; fi

echo 
echo ${OBT_DIR_HOME}/ServerTorrents.pl
${OBT_DIR_HOME}/ServerTorrents.pl

echo 
echo lftp torrents to ${OBT_FTP_SERVER}
lftp -c "set ftp:ssl-allow no
	open ftp://${OBT_FTP_USER}:${OBT_FTP_PASS}@${OBT_FTP_SERVER}
	cd active
	mirror -R -r -a -e /home/torrentsync/torrents/.
	cd /
	mirror -R -r -a /home/torrentsync/torrents/."

sleep 60;

echo 
echo ${OBT_DIR_HOME}/SeedTorrents[.pl
${OBT_DIR_HOME}/SeedTorrents.pl
