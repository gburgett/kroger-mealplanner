# The sandbox root filesystem. See ADR 0006 and ADR 0008.
#
# This image is BUILT, never borrowed. The host /usr holds python3, perl, tclsh,
# gawk, busybox, curl, wget, nc, socat, telnet, ssh, gcc and make. Binding it
# would hand the agent every one of them.
#
# Only the /usr tree of this image is ever exported and mounted, so anything
# outside /usr is unreachable from the sandbox. That is why there is no
# /etc/passwd for `cat /etc/passwd` to find: /etc is never exported.

FROM alpine:3.22

# The real GNU programs, not busybox applets. `git` is here on purpose: it must
# be able to TRY the network, so that "History cannot be pushed anywhere" fails
# with a network error rather than with "command not found".
#
# Not installed, and not to be added without a successor to ADR 0006:
# python3, perl (Alpine keeps git-perl separate, which is why Alpine and not
# Debian), node, ruby, tcl, curl, wget, nc, socat, ssh, gcc, make, openssl.
RUN apk add --no-cache \
      bash \
      coreutils \
      grep \
      sed \
      findutils \
      diffutils \
      gawk \
      git

RUN set -eu; \
    \
    # 1. The package manager is a network client. It goes first. \
    rm -rf /sbin/apk /usr/lib/apk /etc/apk /var/cache/apk /lib/apk; \
    \
    # 2. Busybox supplies wget, nc, telnet, ftpget, tftp, httpd, ssl_client and \
    #    nslookup as applets. `busybox wget` works with wget off PATH, so the \
    #    binary is deleted, not hidden. Every applet symlink goes with it. \
    /usr/bin/find / -xdev -type l -lname '*busybox*' -delete; \
    rm -f /bin/busybox /usr/bin/busybox /sbin/busybox /usr/sbin/busybox; \
    \
    # 3. usr-merge. The sandbox binds only $IMAGE/usr and symlinks /bin and \
    #    /lib into it, so a program outside /usr does not exist at run time. \
    mkdir -p /usr/bin /usr/lib; \
    for d in /bin /sbin /usr/sbin; do \
      if [ -d "$d" ]; then cp -a "$d"/. /usr/bin/; fi; \
    done; \
    cp -a /lib/. /usr/lib/; \
    rm -rf /usr/sbin /usr/local; \
    \
    # 4. A symlink target that leaves /usr dangles once only /usr is bound. \
    #    Alpine's coreutils links look like `[ -> ../../bin/coreutils`, which \
    #    resolves only because bubblewrap happens to add /bin -> usr/bin. Point \
    #    them at the copy that is now a neighbour instead, so the tree stands \
    #    up on its own. \
    for dir in /usr/bin /usr/lib; do \
      /usr/bin/find "$dir" -maxdepth 1 -type l -print0 \
        | while IFS= read -r -d '' link; do \
            target="$(readlink "$link")"; \
            base="${target##*/}"; \
            case "$target" in \
              */*) if [ -e "$dir/$base" ] && [ ! -L "$dir/$base" ]; then \
                     ln -sfn "$base" "$link"; \
                   fi ;; \
            esac; \
          done; \
    done; \
    #    Whatever is left with an absolute target outside /usr is remapped by \
    #    name, which is where the merge in step 3 put it. \
    /usr/bin/find /usr -type l -print0 \
      | while IFS= read -r -d '' link; do \
          target="$(readlink "$link")"; \
          case "$target" in \
            /bin/*)      ln -sfn "/usr/bin/${target#/bin/}"      "$link" ;; \
            /sbin/*)     ln -sfn "/usr/bin/${target#/sbin/}"     "$link" ;; \
            /usr/sbin/*) ln -sfn "/usr/bin/${target#/usr/sbin/}" "$link" ;; \
            /lib/*)      ln -sfn "/usr/lib/${target#/lib/}"      "$link" ;; \
          esac; \
        done; \
    \
    # 5. /bin/sh was a busybox applet and has just been deleted. bash takes it. \
    ln -sfn bash /usr/bin/sh; \
    \
    # 6. Three network clients that survive every rule above, found by reading \
    #    the finished image rather than by trusting the package list: \
    #      ssl_client   a real binary from Alpine's ssl_client package, not a \
    #                   busybox applet symlink, so step 2 does not touch it. \
    #                   It is the TLS half of `busybox wget`. \
    #      getent       named by ADR 0006. It arrives with musl-utils. \
    #      bash loadables  Alpine's bash ships /usr/lib/bash/accept, which is a \
    #                   builtin that LISTENS on a TCP port. `enable -f` would \
    #                   load it. Nothing needs any of these, so the folder goes. \
    rm -f /usr/bin/ssl_client /usr/bin/getent; \
    rm -rf /usr/lib/bash

# /bin/sh went with busybox, so the build's own shell has to move too.
SHELL ["/usr/bin/bash", "-c"]

# Fail the build rather than ship a surprise. A dangling link under /usr means
# the merge missed something; a hit in the second list means ADR 0006 is broken.
RUN set -eu; \
    dangling="$(/usr/bin/find /usr -xtype l -print)"; \
    if [ -n "$dangling" ]; then echo "dangling symlinks under /usr:"; echo "$dangling"; exit 1; fi; \
    for prog in bash sh ls cat cp mv rm mkdir touch ln head tail wc sort tr env printf \
                sleep date grep sed find awk diff git; do \
      if [ ! -x "/usr/bin/$prog" ]; then echo "missing from the image: $prog"; exit 1; fi; \
    done; \
    for prog in python3 python perl ruby node tclsh busybox curl wget nc netcat socat \
                telnet ssh gcc cc make apk openssl getent nslookup ping ssl_client; do \
      if [ -e "/usr/bin/$prog" ]; then echo "must not be in the image: $prog"; exit 1; fi; \
    done; \
    if [ -e /usr/lib/bash ]; then echo "bash loadable builtins are still present"; exit 1; fi; \
    if [ ! -x /usr/libexec/git-core/git-remote-http ]; then \
      echo "git-remote-http is missing: git push would fail with the wrong error"; exit 1; \
    fi
