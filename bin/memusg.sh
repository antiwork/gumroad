#!/usr/bin/env bash
# memusg -- Measure memory usage of processes
# Usage: memusg COMMAND [ARGS]...
#
# Author: Jaeho Shin <netj@sparcs.org>
# Created: 2010-08-16
############################################################################
# Copyright 2010 Jaeho Shin.                                               #
#                                                                          #
# Licensed under the Apache License, Version 2.0 (the "License");          #
# you may not use this file except in compliance with the License.         #
# You may obtain a copy of the License at                                  #
#                                                                          #
#     http://www.apache.org/licenses/LICENSE-2.0                           #
#                                                                          #
# Unless required by applicable law or agreed to in writing, software      #
# distributed under the License is distributed on an "AS IS" BASIS,        #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. #
# See the License for the specific language governing permissions and      #
# limitations under the License.                                           #
############################################################################
set -um

# check input
[[ $# -gt 0 ]] || { sed -n '2,/^#$/ s/^# //p' <"$0"; exit 1; }

# TODO support more options: peak, footprint, sampling rate, etc.

pgid=$(ps -o pgid= $$)
# make sure we're in a separate process group
if [[ "$pgid" == "$(ps -o pgid= $(ps -o ppid= $$))" ]]; then
    cmd=
    set -- "$0" "$@"
    for a; do cmd+="'${a//"'"/"'\\''"}' "; done
    exec bash -i -c "$cmd"
fi

# detect operating system and prepare measurement
case $(uname) in
    Darwin|*BSD) sizes() { /bin/ps -o rss= -g $1; } ;;
    Linux) sizes() { /bin/ps -o rss= -$1; } ;;
    *) echo "$(uname): unsupported operating system" >&2; exit 2 ;;
esac

# monitor the memory usage in the background.
(
peak=0
while sizes=$(sizes $pgid)
do
    set -- $sizes
    sample=$((${@/#/+}))
    let peak="sample > peak ? sample : peak"
    sleep 0.1
done
echo "memusg: peak=$peak" >&2
) &
monpid=$!


# run the given command
exec "$@"