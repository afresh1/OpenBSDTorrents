#!/bin/sh

MakeTorrents.pl
CurrentTorrents.pl
lftp -f lftp.script
ServerTorrents.pl
