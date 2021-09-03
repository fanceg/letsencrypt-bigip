#!/usr/bin/env bash

# Installer for letsencrypt-bigip
#
# Originally written by Gavin Fance 
#
# This script is licensed under The MIT License (see LICENSE for more information).

# Create a datagroup for the domain list.
tmsh create sys file data-group letsencrypt-domains.txt separator ":=" source-path file:/shared/letsencrypt/domains.txt.test type string

# Create datagroup for ACME challenge
tmsh create ltm data-group internal acme_responses type string

# Install an icall to our script
tmsh create sys icall script letsencrypt
tmsh modify sys icall script letsencrypt definition { exec /shared/letsencrypt/wrapper.sh }
tmsh create sys icall handler periodic letsencrypt first-occurrence 2017-07-21:00:00:00 interval 604800 script letsencrypt

#Save and goodbye
tmsh save sys config
