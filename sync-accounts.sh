#!/bin/bash

export HOME=/home/mntbooks

cd /home/mntbooks/mntbooks
source ./secrets.sh

ruby bank.rb
ruby paypal.rb

