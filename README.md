# **Let's Encrypt on a BigIP** 
~~With the opening of the public beta we can now all make use of trusted certificates in our applications free of charge. This is nice!~~ Let's Encrypt is no longer in beta (https://letsencrypt.org/2016/04/12/leaving-beta-new-sponsors.html) but that doesn't change much, you can still get hands of a lot of fully trusted certificates for your applications and websites, and it is still super nice!! ![alt text][lol]

Let's Encrypt is a great project with a new approach to certificates and how to secure and manage them. This new approach however forces us to think a little bit differently when we work with them. Normally this was a task that took place once a year and could easily be handled by hand. This is not the case with Let's Encrypt. Each certificate only has a lifespan of 90 days and for the time being we do not have access to wildcard certificates, only SAN. So for each domain we will have to change all the certificates every three months, and that is simply not feasible if done manually.

So here comes certificate automation. The project has built a client making automation possible when running on a generic Linux server, and that is fine. However it does make it a little more problematic if you don't have the certificates on the backend servers but on an ADC, F5 Big-IP in this case. This got me thinking, how do we fix this? Luckily I got some very talented colleagues (thank you Dindorp!) with an equal desire for Let's Encrypt, so here is one way of doing it!


## **Requirements**
---
As this solution is based on pure bash scripts we have very few dependencies, and that is why I've chosen to go this way. Also the main script handling the requesting runs without any changes on a BigIP. The big part of the scripting has already been done by [Lukas Schauer](https://github.com/lukas2511) - Great job Lukas!!!

Besides the ability to control a keyboard and a SSH client ![alt text][lol] you of course needs to have access to a BigIP with admin rights and an advanced shell (F5 terminology for a Bash shell).

The idea is to use crontab for the automation, so you need to hack this for your requirements. The crontab on a BigIP is no different than on a generic Linux server, so nothing magical here.

On the BigIP you must have a virtual server listening on port 80/tcp that the domain resolves to. This VS is what we use as a reverse proxy for the challenge-response validation mechanism that Let's Encrypt is based upon. You probably have this already and you can just reuse it. As we have the logic tied to an iRule, you just have to make sure that the iRule is the first thing being executed so current logic doesn't break the challenge-response communication.

Another important (and obvious ![alt text][fun]) requirement is when you have a HA pair, you must make sure that the scripts only run on the unit which is active for the traffic-group. Otherwise the changes wouldn't make much sense as the challenge-response traffic will never reach the configured virtual server/data group. I've made a wrapper script for inspiration that you can put into the crontab on all the units.


## **Limitations / Todo's**
---
Before you start to fire away with requests please be aware of these restrictions that is in place currently: https://community.letsencrypt.org/t/rate-limits-for-lets-encrypt/6769

I've been hit by them a couple of time now in my eagerness to test ![alt text][smile] They should be loosened over time but when and to what extent I do not know.

For now I haven't put in any cleanup of old and expired certificates, so they're just gonna pile up. So from time to time you need to go in and remove expired ones. This shouldn't be a too big deal as they are taken out of the client ssl profile automatically. So a simple sort-by-expiry and you can delete them in bunches.

The scripts are tested on TMOS version 12.1 but should work across other versions (Update: it also works with 13.0 and all in between). The limitation is gonna be the tmsh commands in the hook script, the rest is taken directly from GitHub.

## **Data Group**
---
When you initiate the certificate requests the authentication is based on a challenge-response to prove you own or control the domain name. For this to work we utilize a data group to contain the challenge-response values that are generated through the script. This bridges the script values with the iRule and allows for easy and dynamic access to it.

Here is the tmsh command to create it:

```sh
tmsh create ltm data-group internal acme_responses type string
```
### **iRule:**
The iRule works as the webserver/reverse proxy for the challenge-response communication. It features some simple logic that basically looks for the challenge URI. If found it searches, in the above mentioned data group, and if a match is found builds the correct response for ACME. Here it is of course important that other functions or logic doesn't interfere or return other values or challenges (like ASM DoS profile). Copy the iRule below and attach it to the proper virtual server which hosts the domain(s).
```tcl
when HTTP_REQUEST {
		if { not ([HTTP::path] starts_with "/.well-known/acme-challenge/") } { return }
		set token [lindex [split [HTTP::path] "/"] end]
		set response [class match -value -- $token equals acme_responses]
		if { "$response" == "" } {
			log local0. "Responding with 404 to ACME challenge $token"
			HTTP::respond 404 content "Challenge-response token not found."
		} else {
			log local0. "Responding to ACME challenge $token with response $response"
			HTTP::respond 200 content "$response" "Content-Type" "text/plain; charset=utf-8"
		}
	}
```
The virtual server you are using for this iRule probably also has other iRules or functions (like ASM or APM) attached to it. As I have found out this intervened with the challenge-response traffic. I had a bunch of redirect iRules which caused a multi-redirect error situation. So think about this when you attach this iRule. One simple and crude way of fixing this is to insert this in top of the HTTP_REQUEST event:
```tcl
if { ([HTTP::path] starts_with "/.well-known/acme-challenge/") } { return }
```
## **Client SSL Profiles**
---
When the certificate has been signed and returned the hook script will apply it to the F5 configuration through a set of tmsh commands. These commands has some assumptions. First of all it has to exist beforehand and secondly it must have the name convention as this: `auto_${DOMAIN}`

An example. If you have the domain `example.com` then the profile should be named `auto_example.com`.

The hook script simply replaces the certificate and key files already in place. You can apply whatever settings to the profile you like.

If you have the `domains.txt` file populated (see below for explanations on domain.txt) this script will create the needed clientssl profiles for you in one quick go:

```bash
#!/bin/bash
for i in $( cat domains.txt | awk '{ print $1}' ); do
  tmsh create ltm profile client-ssl auto_$i
  echo "Created  auto_$i client-ssl profile"
done
```
### **domains.txt:**
For the domains you would like to register a certificate for you insert them into the domains.txt file. You can have as many as you like (see restrictions above!). The format is important though.
```
example.com www.example.com
example.dk wiki.example.dk
example.se upload.example.se download.example.se
```
From the above example you can see that the `base` domain must be first followed by subdomains that will go in to the certificate as SAN names. Remember that all the names you put in here must resolve to the virtual server that handles the challenge-response validation mentioned previously. All names are validated. The above domain example will generate three certificates.
### **hook&#46;sh:**
Yet another updated version of the hook script. This one fits the `dehydrated` version of the script.
```bash
#!/usr/bin/env bash

function deploy_challenge {
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"

    # This hook is called once for every domain that needs to be
    # validated, including any alternative names you may have listed.
    #
    # Parameters:
    # - DOMAIN
    #   The domain name (CN or subject alternative name) being
    #   validated.
    # - TOKEN_FILENAME
    #   The name of the file containing the token to be served for HTTP
    #   validation. Should be served by your web server as
    #   /.well-known/acme-challenge/${TOKEN_FILENAME}.
    # - TOKEN_VALUE
    #   The token value that needs to be served for validation. For DNS
    #   validation, this is what you want to put in the _acme-challenge
    #   TXT record. For HTTP validation it is the value that is expected
    #   be found in the $TOKEN_FILENAME file.
    response=$(cat $WELLKNOWN/$TOKEN_FILENAME)
    cmd='tmsh modify ltm data-group internal acme_responses records add \{ "'$TOKEN_FILENAME'" \{ data "'$TOKEN_VALUE'" \} \}'
    $cmd
}

function clean_challenge {
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"

    # This hook is called after attempting to validate each domain,
    # whether or not validation was successful. Here you can delete
    # files or DNS records that are no longer needed.
    #
    # The parameters are the same as for deploy_challenge.
    cmd='tmsh modify ltm data-group internal acme_responses records delete \{ "'$TOKEN_FILENAME'" \}'
    $cmd
}

function deploy_cert {
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"

    # This hook is called once for each certificate that has been
    # produced. Here you might, for instance, copy your new certificates
    # to service-specific locations and reload the service.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - KEYFILE
    #   The path of the file containing the private key.
    # - CERTFILE
    #   The path of the file containing the signed certificate.
    # - FULLCHAINFILE
    #   The path of the file containing the full certificate chain.
    # - CHAINFILE
    #   The path of the file containing the intermediate certificate(s).
    # - TIMESTAMP
    #   Timestamp when the specified certificate was created.
    now=$(date +%Y-%m-%d)
    profile=auto_${DOMAIN}
    name=${DOMAIN}_${now}
    cert=${name}.crt
    key=${name}.key
    tmsh install sys crypto key ${name} from-local-file ${KEYFILE}
    tmsh install sys crypt cert ${name} from-local-file ${FULLCHAINFILE}
    tmsh modify ltm profile client-ssl ${profile} cert-key-chain replace-all-with { default { key $key cert $cert } }
}

function unchanged_cert {
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}"

    # This hook is called once for each certificate that is still
    # valid and therefore wasn't reissued.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - KEYFILE
    #   The path of the file containing the private key.
    # - CERTFILE
    #   The path of the file containing the signed certificate.
    # - FULLCHAINFILE
    #   The path of the file containing the full certificate chain.
    # - CHAINFILE
    #   The path of the file containing the intermediate certificate(s).
}

invalid_challenge() {
    local DOMAIN="${1}" RESPONSE="${2}"

    # This hook is called if the challenge response has failed, so domain
    # owners can be aware and act accordingly.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - RESPONSE
    #   The response that the verification server returned
}

request_failure() {
    local STATUSCODE="${1}" REASON="${2}" REQTYPE="${3}"

    # This hook is called when a HTTP request fails (e.g., when the ACME
    # server is busy, returns an error, etc). It will be called upon any
    # response code that does not start with '2'. Useful to alert admins
    # about problems with requests.
    #
    # Parameters:
    # - STATUSCODE
    #   The HTML status code that originated the error.
    # - REASON
    #   The specified reason for the error.
    # - REQTYPE
    #   The kind of request that was made (GET, POST...)
}

exit_hook() {
  # This hook is called at the end of a dehydrated command and can be used
  # to do some final (cleanup or other) tasks.

  :
}

HANDLER="$1"; shift
if [[ "${HANDLER}" =~ ^(deploy_challenge|clean_challenge|deploy_cert|unchanged_cert|invalid_challenge|request_failure|exit_hook)$ ]]; then
  "$HANDLER" "$@"
fi
```
### **OCSP stapling:**
If you plan make use of OCSP stapling you can change a part of the hook deploy script. Insert a snippet before this line - Note this will only work on v.13 as the syntax for OCSP has changed between v.12 and v.13:
```sh
tmsh modify ltm profile client-ssl ${profile} cert-key-chain replace-all-with { default { key $key cert $cert } }
```
So it ends up like this:

```bash
...
now=$(date +%Y-%m-%d)
profile=auto_${DOMAIN}
name=${DOMAIN}_${now}
cert=${name}.crt
key=${name}.key
ocsp="letsencrypt-ocsp"
tmsh install sys crypto key ${name} from-local-file ${KEYFILE}
tmsh install sys crypt cert ${name} from-local-file ${FULLCHAINFILE}
tmsh modify sys crypto cert $cert cert-validation-options { ocsp } cert-validators replace-all-with { $ocsp } issuer-cert letsencrypt_full_chain.crt
tmsh modify ltm profile client-ssl ${profile} cert-key-chain replace-all-with { default { key $key cert 
$cert } }
...
```

`$ocsp` is pre-created OCSP profile looking like this:
```sh
sys crypto cert-validator ocsp letsencrypt-ocsp {
    dns-resolver dns-resolver
    route-domain 0
    sign-hash sha1
    status-age 86400
    trusted-responders letsencrypt_full_chain.crt
}
```
`"sign-hash"` is important, it has to be changed to sha1 otherwise it fails (it defaults to sha2). This goes for a lot of other CA's as well. It costed me a lot of hours to find this tweak I can tell you!!

[letsencrypt_full_chain.crt]([https://wiki.lnxgeek.org/lib/exe/fetch.php/howtos:letsencrypt_full_chain.crt) is a CA bundle containing the issuer and root CA.

### **Config:**
Another change to the script is the config file. It has changed its name and gotten some new features. I dont' make use of them, so again it is only minor changes. I assume the hook file is in the same directory as the letsencrypt script.
```bash
########################################################
# This is the main config file for letsencrypt.sh      #
#                                                      #
# This file is looked for in the following locations:  #
# $SCRIPTDIR/config (next to this script)              #
# /usr/local/etc/letsencrypt.sh/config                 #
# /etc/letsencrypt.sh/config                           #
# ${PWD}/config (in current working-directory)         #
#                                                      #
# Default values of this config are in comments        #
########################################################

# Path to certificate authority (default: https://acme-v01.api.letsencrypt.org/directory)
#CA="https://acme-v01.api.letsencrypt.org/directory"

# Path to license agreement (default: https://letsencrypt.org/documents/LE-SA-v1.0.1-July-27-2015.pdf)
#LICENSE="https://letsencrypt.org/documents/LE-SA-v1.0.1-July-27-2015.pdf"

# Which challenge should be used? Currently http-01 and dns-01 are supported
CHALLENGETYPE="http-01"

# Path to a directory containing additional config files, allowing to override
# the defaults found in the main configuration file. Additional config files
# in this directory needs to be named with a '.sh' ending.
# default: <unset>
#CONFIG_D=

# Base directory for account key, generated certificates and list of domains (default: $SCRIPTDIR -- uses config directory if undefined)
#BASEDIR=$SCRIPTDIR

# File containing the list of domains to request certificates for (default: $BASEDIR/domains.txt)
#DOMAINS_TXT="${BASEDIR}/domains.txt"

# Output directory for generated certificates
#CERTDIR="${BASEDIR}/certs"

# Output directory for challenge-tokens to be served by webserver or deployed in HOOK (default: $BASEDIR/.acme-challenges)
#WELLKNOWN="${BASEDIR}/.acme-challenges"

# Location of private account key (default: $BASEDIR/private_key.pem)
#ACCOUNT_KEY="${BASEDIR}/private_key.pem"

# Location of private account registration information (default: $BASEDIR/private_key.json)
#ACCOUNT_KEY_JSON="${BASEDIR}/private_key.json"

# Default keysize for private keys (default: 4096)
#KEYSIZE="4096"

# Path to openssl config file (default: <unset> - tries to figure out system default)
#OPENSSL_CNF=

# Program or function called in certain situations
#
# After generating the challenge-response, or after failed challenge (in this case altname is empty)
# Given arguments: clean_challenge|deploy_challenge altname token-filename token-content
#
# After successfully signing certificate
# Given arguments: deploy_cert domain path/to/privkey.pem path/to/cert.pem path/to/fullchain.pem
#
# BASEDIR and WELLKNOWN variables are exported and can be used in an external program
# default: <unset>
HOOK="${BASEDIR}/hook.sh"

# Chain clean_challenge|deploy_challenge arguments together into one hook call per certificate (default: no)
#HOOK_CHAIN="no"

# Minimum days before expiration to automatically renew certificate (default: 30)
#RENEW_DAYS="30"

# Regenerate private keys instead of just signing new certificates on renewal (default: yes)
#PRIVATE_KEY_RENEW="yes"

# Which public key algorithm should be used? Supported: rsa, prime256v1 and secp384r1
#KEY_ALGO=rsa

# E-mail to use during the registration (default: <unset>)
#CONTACT_EMAIL=example@example.com

# Lockfile location, to prevent concurrent access (default: $BASEDIR/lock)
#LOCKFILE="${BASEDIR}/lock"

# Option to add CSR-flag indicating OCSP stapling to be mandatory (default: no)
#OCSP_MUST_STAPLE="no"
```

### **Dehydrated:**
This is now the main script. For now it is handled the same way as the old letsencrypt script.

You run it like this: `dehydrated -c`

## **Wrapper**
---
As dehydrated only should run on the active unit I've made a wrapper which is making sure this is handled. Also I like to get an email whenever the script has run so I know the status of my certificates and if any errors had occurred. Regarding the mail notification, v.13 of TMOS is horrible when it comes to the local mail function. It is based on ssmtp which is okay but it also catches a lot of other cron jobs and pollutes your inbox with lots of crap mails from jobs which shouldn't be sending emails. That is why I've stopped using the local MTA for notifications and instead I found an expect script (to my pleasure I realised that expect is installed as part of TMOS :-)) which does it for me. In the wrapper I've called it `send_mail`.

### **wrapper&#46;sh:**
```bash
#!/bin/bash

MAILRCPT="example@example.com"
MAILFROM="f5@example"
MAILSERVER="mail.example.com"
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

cd /shared/letsencrypt


ME=`echo $HOSTNAME|awk -F. '{print $1}'`
ACTIVE=$(tmsh show cm failover-status | grep ACTIVE | wc -l)

if [[ "${ACTIVE}" = "1" ]]; then
    echo "Unit is active - proceeding..."
    exec >/var/log/letsencrypt.log 2>&1
    ./dehydrated -c
    send_status_mail "Lets Encrypt Report $ME"
fi
```
### **send_mail:**
```bash
#!/usr/bin/expect
#
# sends a properly formatted file to smtp server
# usage: send_email
#
# blatantly copied from Peter Vibert’s expect script:
# http://www.petervibert.com/posts/01-11-09-expect-smtp.html
# source: http://pfautsch.com/?p=484
#
if {$argc<3} {
 send_user "sends mime formatted message file to smtp server using telnet\n"
 send_user "usage: send_email mailserver port message_file\n"
 exit
}
set mailserver [lrange $argv 0 0]
set portno [lrange $argv 1 1]
set cfile [lrange $argv 2 2]
send "$cfile\n"
set fp [open "$cfile" r]
set content [read $fp]
set hostname [exec hostname]

# extract the from address from message file
# must be in one of two forms:
# From: "Recipient Name"
# or
# From: recipient@foo.com

set from [exec grep "From:" "$cfile"]
set quoted [string match "?*<*@*.*>" "$from"]
if [expr $quoted > 0 ] {
set from [exec echo "$from" | cut -d< -f2 | tr -d '>‘]
} else {
set from [exec echo "$from" | cut -d: -f2 | tr -d \[:space:\]]
}

# extract the to address – same as from (see above)
set to [exec grep "To:" "$cfile"]
set quoted [string match "?*<*@*.*>" "$to"]
if [expr $quoted > 0 ] {
set to [exec echo "$to" | cut -d< -f2 | tr -d '>‘]
} else {
set to [exec echo "$to" | cut -d: -f2 | tr -d \[:space:\]]
}

spawn telnet $mailserver $portno
expect "failed" {
send_user "$mailserver: connect failed\n"
exit
} "2?? *" {
} "4?? *" {
exit
} "refused" {
send_user "$mailserver: connect refused\n"
exit
} "closed" {
send_user "$mailserver: connect closed\n"
exit
} timeout {
send_user "$mailserver: connect to port $portno timeout\n"
exit
}
send "HELO $hostname\r"
expect "2?? *" {
} "5?? *" {
exit
} "4?? *" {
exit
}
send "MAIL FROM: <$from>\r"
expect "2?? *" {
} "5?? *" {
exit
} "4?? *" {
exit
}
send "RCPT TO: <$to>\r"
expect "2?? *" {
} "5?? *" {
exit
} "4?? *" {
exit
}
send "DATA\r"
expect "3?? *" {
} "5?? *" {
exit
} "4?? *" {
exit
}
log_user 0
send "$content"
set timeout 1
expect "$content"
close $fp
send ".\r"
expect ".\r"
expect "2?? *" {
} "5?? *" {
exit
} "4?? *" {
exit
}
send_user "$expect_out(buffer)"
send "QUIT\r"
exit
```
## **Install an iScript**
---
We now have all the scripts and profiles in place the Let's Encrypt certificates now we only need to automate the execution.

For this we make use of iScripts which is part of the iCall framework. This enable us to run the script periodically and without having to reset cronjobs whenever we do an upgrade, with this it rides along automatically as it is part of the configuration. Another great advantage is that is it synchronized in a cluster setup so you make it once and it gets installed on all the cluster members automatically.

The iCall framework is poorly documented (at the moment) but by guessing and reading through some iApps I came up with this solution. It is basically an iScript which runs the wrapper script and a periodic handler running the script every week.

I assume the wrapper script i placed in /shared/letsencrypt so remember to change this if you have it somewhere else. Simply copy and paste the following lines into the shell:

```sh
tmsh create sys icall script letsencrypt
tmsh modify sys icall script letsencrypt definition { exec /shared/letsencrypt/wrapper.sh }
tmsh create sys icall handler periodic letsencrypt first-occurrence 2017-07-21:00:00:00 interval 604800 script letsencrypt
tmsh save sys config
```

This is what the lines do:

1. Create the iscript
1. Insert the only line needed, the execution of the wrapper script (remember to use the correct path for the script)
1. Create the handler and make it execute the iscript once a week starting on Friday 21/7-17 00:00. I use “first-occurence” to control which day of the week it should run. It is not mandatory so you could leave it out if it isn't important to you.
1. Save the configuration to disk
You should now have the following configuration:

```sh
# the iscript
> tmsh list sys icall script letsencrypt
sys icall script letsencrypt {
    app-service none
    definition {
        exec /shared/letsencrypt/wrapper.sh
    }
    description none
    events none
}
# the event handler
> tmsh list sys icall handler periodic letsencrypt
sys icall handler periodic letsencrypt {
    first-occurrence 2017-07-21:00:00:00
    interval 604800
    script letsencrypt
}
```
The iCall logic also has an event options which could make the script execute based on something coming out into the ltm logs like a certificate which is about to expire. You could also make it part of a cleanup procedure. So my example has room for enhancements ![alt text][razz]

## **Sources, References and Files**
***
Given what ever skills I possess this Let's Encrypt automation scripting on a BigIP would never have been possible without the knowledge of Lukas Schauer and David Dindorp - Thank you guys, you are amazing!!!

Original Source:
https://wiki.lnxgeek.org/doku.php/howtos:let_s_encrypt_-_how_to_issue_certificates_from_a_bigip

You can find the scripts on GitHub here: ~~https://github.com/lukas2511/letsencrypt.sh~~ https://github.com/lukas2511/dehydrated

---
[f5logo]: https://github.com/fanceg/letsencrypt-bigip/raw/master/images/logo_f5.png "F5 BigIP"

[lelogo]: https://github.com/fanceg/letsencrypt-bigip/raw/master/images/logo_le.png "Let's Encrypt"

[lol]: https://github.com/fanceg/letsencrypt-bigip/blob/master/images/icon_lol.gif "lol"

[fun]: https://github.com/fanceg/letsencrypt-bigip/blob/master/images/icon_fun.gif "fun"

[smile]: https://github.com/fanceg/letsencrypt-bigip/blob/master/images/icon_smile.gif "smile"

[razz]: https://github.com/fanceg/letsencrypt-bigip/blob/master/images/icon_razz.gif "razz"