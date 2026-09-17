#!/bin/sh
hexdump -v -n 16 -e '"%08x"' /dev/random > /etc/machine-id
