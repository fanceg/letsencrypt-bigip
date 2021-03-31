#!/bin/bash

MAILRCPT=""
MAILFROM=""
MAILSERVER=""
MAILSERVERPORT="25"
LOGFILE="/var/log/letsencrypt.log"
DATE=$(date)
SENDMAIL="/shared/letsencrypt/send_mail"
MAILFILE="/var/tmp/mail.txt"
date >$LOGFILE 2>&1
echo "" > $MAILFILE

send_status_mail () {
  local message=$1
  cat <<-EOF >$MAILFILE
From: $MAILFROM
To: $MAILRCPT
Date: $DATE
Subject: $message
EOF
  cat $LOGFILE >> $MAILFILE
  $SENDMAIL $MAILSERVER $MAILSERVERPORT $MAILFILE >/dev/null 2>&1
}


cd /var/www/
mkdir -p dehydrated


cd /shared/letsencrypt 
cat /config/filestore/files_d/Common_d/lwtunneltbl_d/*domains.txt* > /shared/letsencrypt/domains.txt

ME=`echo $HOSTNAME|awk -F. '{print $1}'`
ACTIVE=$(tmsh show cm failover-status | grep ACTIVE | wc -l)

if [[ "${ACTIVE}" = "1" ]]; then
    echo "Unit is active - proceeding..."
    exec >/var/log/letsencrypt.log 2>&1
    ./dehydrated -c
    send_status_mail "Lets Encrypt Report $ME"


fi
