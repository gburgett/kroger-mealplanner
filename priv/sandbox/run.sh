#!/usr/bin/env bash
#
# The exec wrapper for one sandbox command. See lib/mealplan/sandbox/runner.ex.
#
# Erlang ports cannot pass an arbitrary file descriptor to a spawned program,
# and they merge stdout and stderr. This wrapper solves both: it opens the
# seccomp filter on fd 3 with a shell redirection (which the whole
# systemd-run -> prlimit -> env -i -> bwrap exec chain inherits, exactly as the
# TypeScript server passed it through the child's stdio array), and it sends the
# two streams to two files the runner reads back with its own byte cap.
#
#   run.sh OUT ERR FILTER INPUT -- <argv...>
#
# FILTER is "-" when the image has no seccomp filter; INPUT is "-" when the
# command has nothing on stdin.

set -u

out="$1"; err="$2"; filter="$3"; input="$4"
shift 4
[ "${1:-}" = "--" ] && shift

if [ "$filter" != "-" ]; then
  exec 3< "$filter" || exit 127
fi

if [ "$input" != "-" ]; then
  exec "$@" > "$out" 2> "$err" < "$input"
else
  exec "$@" > "$out" 2> "$err" < /dev/null
fi
