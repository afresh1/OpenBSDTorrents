#!/bin/sh

doas -u _torrentseeder tmux new-session -d 'rtorrent \
	-d /var/www/ftp/pub/ \
	-s /var/torrentseeder/ \
	-o dht=on,upload_rate=4096 \
	-Oschedule=load,10,10,load_start=/var/www/ftp/pub/torrents/*.torrent \
	-Oschedule=untie,10,10,remove_untied='
