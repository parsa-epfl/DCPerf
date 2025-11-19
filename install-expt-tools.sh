#!/bin/bash
set -e

apt-get update
apt-get install -y linux-tools-common linux-tools-$(uname -r) python-is-python3 vim

pip3 install -r requirements.txt

