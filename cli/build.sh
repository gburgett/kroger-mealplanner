#!/usr/bin/env bash
#
# Build the mealplan command as one static musl binary, per ADR 0007, and stage
# it into the sandbox image.
#
#   ./cli/build.sh
#
# The binary is the whole interface between the two languages: a command line
# and an exit status. There is no shared library and no shared type.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="x86_64-unknown-linux-musl"

export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || {
  echo "cargo is not installed. See ADR 0007: rustup, then rustup target add $target" >&2
  exit 1
}

cargo build --release --target "$target" --manifest-path "$here/Cargo.toml"

binary="$here/target/$target/release/mealplan"
# One static binary is the whole point of the musl target: the sandbox image is
# small and a dynamically linked command would need things it does not have.
head -c 4 "$binary" | od -An -tx1 | tr -d ' \n' | grep -qx '7f454c46' \
  || { echo "$binary is not an ELF binary" >&2; exit 1; }
if command -v ldd >/dev/null && ldd "$binary" 2>&1 | grep -qv 'not a dynamic executable\|statically linked'; then
  echo "warning: $binary appears to be dynamically linked" >&2
fi

echo "built $binary ($(du -h "$binary" | cut -f1))" >&2

rootfs="$here/../sandbox-image/rootfs"
if [ -d "$rootfs/usr/bin" ]; then
  install -m 0755 "$binary" "$rootfs/usr/bin/mealplan"
  echo "staged into $rootfs/usr/bin/mealplan" >&2
  echo "note: rerun ./sandbox-image/build.sh to refresh manifest.txt" >&2
fi
