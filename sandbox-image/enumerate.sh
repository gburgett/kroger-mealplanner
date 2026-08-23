# Print every program the sandbox can execute, one per line, sorted.
#
# This file is the single definition of "what is in the image". It is read by
# `build.sh`, which writes the result to `manifest.txt`, and by the @security
# scenario, which runs it INSIDE the sandbox and compares. Both sides therefore
# enumerate the same way by construction, which is the only reason the
# comparison means anything.
#
# Libraries are not listed. A patch release of Alpine renames
# libssl.so.3.5.1 to libssl.so.3.5.2 and nothing about the decision in ADR 0006
# has changed. A new program is a different matter, and that is what this
# catches.
#
# Set SANDBOX_ROOT to enumerate an unmounted root filesystem on the host. Inside
# the sandbox it is empty, and the paths are already absolute.

root="${SANDBOX_ROOT:-}"

for dir in /usr/bin /usr/sbin /usr/libexec; do
  [ -d "$root$dir" ] || continue
  find "$root$dir" -type f -perm -u+x -printf '%p\n'
  find "$root$dir" -type l -printf '%p -> %l\n'
done | sed "s|^$root||" | LC_ALL=C sort
