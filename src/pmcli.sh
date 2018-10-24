#!/bin/bash

# TODO: in Arch PKGBUILD replace following with
# MPV_SCRIPT="/usr/share/local/lua/5.2/pmcli/mpv_script.lua"
# since it does not use luarocks

# SCRIPT FILE LOCATION
MPV_SCRIPT="$(luarocks-5.2 show pmcli | grep mpv_script | sed -n -e 's/.*(\([^)]*\)).*/\1/p')"

# TODO arguments might need to include an stty --save call if i can't figure out a way to sanitize terminal IO from within mpv

# ARGUMENT PARSING
# rationale: just pass everything, let the script sort it out
# encoding:
#	option=true if present and doesn't need argument
#	option=argument if present with argument
#	option=false if present and should have arugment but does not
SCRIPT_OPTS=""
function script_opts_enqueue {
# N.B. No validation!!
# but substring will kill everything up to the last dash
	SCRIPT_OPTS="${SCRIPT_OPTS} --script-opts=pmcli-${1##*-}=${2}"
}
while [[ $# -gt 0 ]]; do
	case "${1}" in
	--help|--login)
	# options that don't require a following parameter
		script_opts_enqueue "${1}" "true"
		;;
	--config)
	# options that do require a following parameter
		if [ -n "${2}" ]; then
			script_opts_enqueue "${1}" "${2}"
			shift
		else
			script_opts_enqueue "${1}" "false"
		fi
		;;
	*)
	# unrecognized
		script_opts_enqueue "${1}" "false"
		;;
	esac
	shift
done

echo mpv --script "${MPV_SCRIPT}" "${SCRIPT_OPTS}" --idle
