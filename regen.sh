#!/bin/sh
#$Id$

BASEDIR=/home/OpenBSDTorrents

cd ${BASEDIR}

if [[ $1 != skip ]]; then
	echo ${BASEDIR}/MakeTorrents.pl $*
	${BASEDIR}/MakeTorrents.pl $*
fi

echo ${BASEDIR}/CurrentTorrents.pl
${BASEDIR}/CurrentTorrents.pl

if [ $? != 253 ]; then
	echo lftp -f ${BASEDIR}/lftp.script
	lftp -f ${BASEDIR}/lftp.script

	echo ${BASEDIR}/ServerTorrents.pl
	${BASEDIR}/ServerTorrents.pl
fi
