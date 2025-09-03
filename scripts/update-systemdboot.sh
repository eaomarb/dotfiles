#!/bin/bash

entries_dir="/efi/loader/entries"
loader_conf="/efi/loader/loader.conf"

# find most recent entry that isn't LTS
latest=$(ls "$entries_dir" | grep -v lts | sort | tail -n1)

# update loader.conf
if [ -n "$latest" ]; then
    sudo sed -i "s|^default .*|default $latest|" "$loader_conf"
fi
