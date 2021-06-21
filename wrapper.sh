#!/bin/bash

# Wrapper file for letsencrypt-bigip
#
# Originally written by Gavin Fance 
# Heavily modified by Frederic Pasteleurs <frederic@askarel.be>
#
# This script is licensed under The MIT License (see LICENSE for more information).

declare -A CONFIG

CONFIG['mailfrom']='noreply@example.invalid'
CONFIG['mailto']='johndoe@example.invalid'
CONFIG['mailrelay']='smtp.example.invalid'
CONFIG['logfile']="/var/log/letsencrypt.log"

#######################################################################

# Send email using parameters in $CONFIG array
# Body data is in stdin, subject is on first line of STDIN
do_send_mail() {
    test -n "${CONFIG['mailfrom']}" || echo "${FUNCNAME}: Variable CONFIG['mailfrom'] not set: no mail will be sent"
    test -n "${CONFIG['mailto']}" || echo "${FUNCNAME}: Variable CONFIG['mailto'] not set: no mail will be sent"
    test -n "${CONFIG['mailrelay']}" || echo "${FUNCNAME}: Variable CONFIG['mailrelay'] not set: no mail will be sent"
    test -z "${CONFIG['mailfrom']}" -o -z "${CONFIG['mailto']}" -o -z "${CONFIG['mailrelay']}" && return
    # Open TCP socket to SMTP server
    exec 3<>"/dev/tcp/${CONFIG['mailrelay']}/25"
    # SMTP dialog with SMTP server
    read -u 3
    test ${REPLY%%[[:space:]]*} -eq 220 || { echo "${FUNCNAME}: Got error from serveron connect. Message: '$REPLY'"; return; }
    printf 'HELO %s\r\n' "${HOSTNAME}" >&3
    read -u 3
    test ${REPLY%%[[:space:]]*} -eq 250 || { echo "${FUNCNAME}: Got error from server after HELO. Message: '$REPLY'"; return; }
    printf 'MAIL FROM:%s\r\n' "${CONFIG['mailfrom']}" >&3
    read -u 3
    test ${REPLY%%[[:space:]]*} -eq 250 || { echo "${FUNCNAME}: Got error from server after MAIL FROM. Message: '$REPLY'"; return; }
    printf 'RCPT TO:%s\r\n' "${CONFIG['mailto']}" >&3
    read -u 3
    test ${REPLY%%[[:space:]]*} -eq 250 || { echo "${FUNCNAME}: Got error from server after RCPT TO. Message: '$REPLY'"; return; }
    printf 'DATA\r\n' >&3
    read -u 3
    test ${REPLY%%[[:space:]]*} -eq 354 || { echo "${FUNCNAME}: Got error from server after DATA. Message: '$REPLY'"; return; }
    printf 'From: %s\r\n' "${CONFIG['mailfrom']}" >&3
    printf 'To: %s\r\n' "${CONFIG['mailto']}" >&3
    printf 'Date: %s\r\n' "$(date)" >&3
    # Use first line of STDIN as subject line
    read
    printf 'Subject: %s\r\n\r\n' "$REPLY" >&3
    # Add \r\n at the end of each line
    while read line; do printf '%s\r\n' "$line" >&3; done
    # Footer
    printf -- '-- \r\nMail sent by letsencrypt-bigip wrapper, running on %s\r\n' "$HOSTNAME" >&3
    printf '\r\n.\r\n' >&3
    read -u 3
    test ${REPLY%%[[:space:]]*} -eq 250 || { echo "${FUNCNAME}: Got error from server after end of data. Message: '$REPLY'"; return; }
    printf 'QUIT\r\n' >&3
}


cd /shared/letsencrypt 
# What is this ? This folder does not exists on version 15
#cat /config/filestore/files_d/Common_d/lwtunneltbl_d/*domains.txt* > /shared/letsencrypt/domains.txt

ACTIVE=$(tmsh show cm failover-status | grep ACTIVE | wc -l)

{ printf 'Lets Encrypt Report %s\n\n' "$(echo $HOSTNAME|awk -F. '{print $1}')"

if [[ "${ACTIVE}" = "1" ]]; then
	printf '%s %s: Unit is active - proceeding...\n' "$(date)" "$HOSTNAME"
	./dehydrated -c
	#send_status_mail "Lets Encrypt Report $ME"
    else
	printf '%s %s: Unit not active - skipping...\n' "$(date)" "$HOSTNAME"
fi

} | do_send_mail
