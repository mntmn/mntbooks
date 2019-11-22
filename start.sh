#!/bin/bash

export HOME=/home/mntbooks

cd /home/mntbooks/mntbooks
source ./secrets.sh

rackup -p 4567

