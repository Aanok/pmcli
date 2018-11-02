#!/bin/bash

# TODO: in Arch PKGBUILD replace following with
# ARGS=("/usr/share/local/lua/5.2/pmcli/mpv_script.lua")
# since it does not use luarocks

# SCRIPT FILE LOCATION
MPV_SCRIPT="$(luarocks-5.2 show pmcli | grep mpv_script | sed -n -e 's/.*(\([^)]*\)).*/\1/p')"

# TODO arguments might need to include an stty --save call if i can't figure out a way to sanitize terminal IO from within mpv


# ARGUMENT PARSING
# encoding:
#	option=yes if standalone
#	option=argument if present with argument

# Conveniency function printing help/usage information
function usage {
	echo "Usage:"
	echo "pmcli [ --login ] [ --config configuration_file ]"
	echo "pmcli [ --help ]"
}

# Conveniency function to populate mpv argument list
SCRIPT_OPTS=""
function script_opts_enqueue {
# N.B. No validation!!
# but substring will kill everything up to the last dash
	if [ -z "${SCRIPT_OPTS}" ]; then
		SCRIPT_OPTS="--script-opts=pmcli-${1##*-}=${2}"
	else
		SCRIPT_OPTS="${SCRIPT_OPTS},pmcli-${1##*-}=${2}"
	fi
}
while [[ $# -gt 0 ]]; do
	case "${1}" in
	--login)
		script_opts_enqueue "${1}" "yes"
	;;
	--help)
	# print message and exit
		usage
		exit
	;;
	--config)
	# needs following argument
		if [ -n "${2}" ]; then
			script_opts_enqueue "${1}" "${2}"
			shift
		else
			echo "[!!!] --config requires a following file name" >&2
			exit 1
		fi
	;;
	*)
	# unrecognized
		echo "[!!!] unrecognized argument '${1}'" >&2
		usage
		exit 1
	;;
	esac
	shift
done

# discriminate because mpv doesn't like an empty string argument: it thinks it's a file
if [[ -n "${SCRIPT_OPTS}" ]] ; then
	mpv --script "${MPV_SCRIPT}" "${SCRIPT_OPTS}" --idle
else
	mpv --script "${MPV_SCRIPT}" --idle
fi
