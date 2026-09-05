#!/usr/bin/env bash
#
# Build the sandbox root filesystem, the seccomp filter and the manifest.
#
#   ./sandbox-image/build.sh
#
# Docker is used to resolve Alpine packages and nothing else: the product does
# not run containers. What the sandbox mounts is the plain directory this script
# leaves in sandbox-image/rootfs, which is not committed. The manifest is.
#
# See ADR 0006 (what is in the image and why) and ADR 0008 (why bubblewrap).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tag="mealplan-sandbox:latest"
rootfs="$here/rootfs"
manifest="$here/manifest.txt"
filter="$here/seccomp/filter.bpf"
cli="${MEALPLAN_BINARY:-$here/../cli/target/x86_64-unknown-linux-musl/release/mealplan}"

# --- the root filesystem ---------------------------------------------------

echo "building $tag" >&2
docker build --quiet --tag "$tag" --file "$here/Dockerfile" "$here" >/dev/null

echo "exporting /usr to $rootfs" >&2
container="$(docker create "$tag" /usr/bin/true)"
trap 'docker rm --force "$container" >/dev/null 2>&1 || true' EXIT

rm -rf "$rootfs"
mkdir -p "$rootfs"
# Only usr. Everything else in the image — /etc above all — stays behind, so
# there is no /etc/passwd in the sandbox to read. Extracting the whole export
# would also need root, because it holds device nodes.
docker export "$container" | tar --extract --directory "$rootfs" usr

# The check in the Dockerfile runs with /bin and /lib still present, so a link
# out of /usr resolves there and looks fine. Only the exported tree can answer
# whether /usr stands up alone, which is the tree the sandbox actually mounts.
dangling=""
while IFS= read -r link; do
  target="$(readlink "$link")"
  case "$target" in
    /*) resolved="$rootfs$target" ;;
    *) resolved="$(dirname "$link")/$target" ;;
  esac
  [ -e "$resolved" ] || dangling+="  ${link#"$rootfs"} -> $target"$'\n'
done < <(find "$rootfs/usr" -type l)
if [ -n "$dangling" ]; then
  echo "symlinks that do not resolve inside the exported /usr:" >&2
  printf '%s' "$dangling" >&2
  exit 1
fi

# --- the mealplan command --------------------------------------------------

if [ -f "$cli" ]; then
  install -m 0755 "$cli" "$rootfs/usr/bin/mealplan"
  echo "staged $cli" >&2
else
  echo "note: no mealplan binary at $cli — build it with cli/build.sh first" >&2
  echo "      the image is usable, but 'mealplan' will not be found in it" >&2
fi

# --- the seccomp filter ----------------------------------------------------

node "$here/seccomp/generate.ts" "$filter"

# --- the manifest ----------------------------------------------------------

SANDBOX_ROOT="$rootfs" bash "$here/enumerate.sh" >"$manifest"
echo "$(wc -l <"$manifest") programs in the image, $(du -sh "$rootfs" | cut -f1) on disk" >&2

if git -C "$here" diff --quiet -- "$manifest" 2>/dev/null; then
  :
else
  echo >&2
  echo "manifest.txt changed. Read the diff before committing it: a new program" >&2
  echo "in the image is a change to the decision in ADR 0006." >&2
fi

# --- the microsandbox session-layer image (opt-in) -----------------------
#
# `./sandbox-image/build.sh --microsandbox` also writes sandbox-image/oci.tar,
# the rootfs the microsandbox backend boots one microVM per tenant from
# (ADR 0027). Opt-in, and additive: the bubblewrap path above is untouched.
#
# It is the SAME image as above with three differences a microVM needs and a
# bind-mounted /usr does not:
#   * `mealplan` is baked in rather than staged into rootfs/ afterwards, because
#     msb clones a whole image, not a directory;
#   * /etc/passwd and /etc/group are cut to root only — the guest agent needs
#     to resolve uid 0, and nothing else in /etc should look like a real host;
#   * /home, /root/*, /media, /mnt, /opt and /srv go, so a walk out of
#     /workspace lands on nothing.
# The /usr tree — every program `enumerate.sh` lists — is byte-for-byte the
# bubblewrap image's, so manifest.txt still describes it.

if [ "${1:-}" = "--microsandbox" ] || [ "${MEALPLAN_BUILD_MICROSANDBOX:-}" = "1" ]; then
  msb_tag="mealplan-sandbox:msb"
  oci="$here/oci.tar"

  if [ ! -f "$cli" ]; then
    echo "--microsandbox needs the mealplan binary at $cli — run cli/build.sh first" >&2
    exit 1
  fi

  echo "building $msb_tag (microsandbox session-layer image, ADR 0027)" >&2
  msb_dir="$(mktemp -d)"
  install -m 0755 "$cli" "$msb_dir/mealplan"
  cat >"$msb_dir/Dockerfile" <<DOCKER
FROM $tag
COPY mealplan /usr/bin/mealplan
RUN set -eu; \\
    printf 'root:x:0:0:root:/workspace:/usr/bin/bash\\n' > /etc/passwd; \\
    printf 'root:x:0:\\n' > /etc/group; \\
    rm -f /etc/shadow /etc/passwd- /etc/group- /etc/shadow-; \\
    rm -rf /home /root /media /mnt /opt /srv /var/cache /var/log; \\
    mkdir -p /root /run/mealplan
DOCKER

  docker build --quiet --tag "$msb_tag" "$msb_dir" >/dev/null
  docker save "$msb_tag" -o "$oci"
  rm -rf "$msb_dir"
  echo "wrote $oci ($(du -h "$oci" | cut -f1)). The server runs 'msb load' on it at boot." >&2
fi
