#!/bin/sh
#$Id$

. /etc/OpenBSDTorrents.conf

cd ${OBT_DIR_HOME}

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
