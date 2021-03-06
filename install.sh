#!/usr/bin/env bash

tmsh create ltm data-group internal acme_responses type string

tmsh create sys icall script letsencrypt

tmsh modify sys icall script letsencrypt definition { exec /shared/letsencrypt/wrapper.sh }

tmsh create sys icall handler periodic letsencrypt first-occurrence 2017-07-21:00:00:00 interval 604800 script letsencrypt
tmsh save sys config

cat /config/filestore/files_d/Common_d/lwtunneltbl_d/*domains.txt* > /shared/letsencrypt/domains.txt

for i in $( cat domains.txt | awk '{ print $1}' ); do
	  tmsh create ltm profile client-ssl auto_$i
	    echo "Created  auto_$i client-ssl profile"
done
