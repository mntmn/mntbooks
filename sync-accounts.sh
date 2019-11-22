#!/bin/bash

export HOME=/home/mntbooks

cd /home/mntbooks/mntbooks
source ./secrets.sh

python3 bank-psd2.py
ruby paypal.rb

