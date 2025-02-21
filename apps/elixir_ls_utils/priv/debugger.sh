#!/bin/sh
# Launches the debugger. This script must be in the same directory as the compiled .ez archives.

readlink_f () {
  cd "$(dirname "$1")" > /dev/null || exit 1
  filename="$(basename "$1")"
  if [ -h "$filename" ]; then
    readlink_f "$(readlink "$filename")"
  else
    echo "$(pwd -P)/$filename"
  fi
}

if [ -z "${ELS_INSTALL_PREFIX}" ]; then
  dir="$(dirname "$(readlink_f "$0")")"
  >&2 echo "running ${dir}/launch.sh"
else
  dir=${ELS_INSTALL_PREFIX}
  >&2 echo "ELS_INSTALL_PREFIX is set, running ${ELS_INSTALL_PREFIX}/launch.sh"
fi

export ELS_MODE=debugger
export ELS_SCRIPT="ElixirLS.Debugger.CLI.main()"

exec "${dir}/launch.sh"
