#!/bin/bash
# Per-user part of desktop_extras: ~/Transfer and a Desktop link to the
# Guacamole drive. xrdp mounts it at ~/thinclient_drives/GUACFS only while a
# session is open, so the links dangle otherwise; drive-name ("Transfer") is
# only what the Guacamole menu shows.
for link in "${HOME}/Transfer" "${HOME}/Desktop/Transfer"; do
    mkdir -p "$(dirname "${link}")"
    if [ ! -e "${link}" ] || [ -L "${link}" ]; then
        ln -sfn "${HOME}/thinclient_drives/GUACFS" "${link}"
    fi
done
