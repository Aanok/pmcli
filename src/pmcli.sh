#!/bin/bash

# TODO discriminate luarocks/luarocks-5.2 if on arch or not
# protip: check "command -v luarocks-5.2"
MPV_SCRIPT="$(luarocks-5.2 show pmcli | grep mpv_script | sed -n -e 's/.*(\([^)]*\)).*/\1/p')"

# TODO argument parsing
# this might need to include an stty --save call if i can't figure out a way to sanitize terminal IO from within mpv
mpv --script "$MPV_SCRIPT" --idle
