#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# build-ipk.sh — build the .ipk (and, where apk-tools 3 exists, the .apk)
# straight from a checkout, with no OpenWrt SDK.
#
#   sh tools/build-ipk.sh                 # -> dist/
#   sh tools/build-ipk.sh /somewhere/else
#
# The package is architecture-independent, so the result installs on any
# OpenWrt target. For an in-tree build with the SDK, use the Makefile instead.
set -e

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT="${1:-$REPO/dist}"
NAME="luci-app-temp-history"

# Single source of truth for the version: the Makefile.
VER=$(sed -n 's/^PKG_VERSION:=//p' "$REPO/Makefile")
REL=$(sed -n 's/^PKG_RELEASE:=//p' "$REPO/Makefile")
[ -n "$VER" ] || { echo "cannot read PKG_VERSION from Makefile" >&2; exit 1; }
REL="${REL:-1}"
IPKVER="$VER-$REL"      # opkg style
APKVER="$VER-r$REL"     # apk-tools 3 requires the -rN form and rejects -N
STAMP="$VER"            # what the page displays: just 1.0.0

WORK="${TMPDIR:-/tmp}/build-$NAME.$$"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
rm -rf "$WORK"; mkdir -p "$WORK/data" "$WORK/ctl" "$OUT"

# ── Payload ────────────────────────────────────────────────────────────────
cp -a "$REPO/root/." "$WORK/data/"
mkdir -p "$WORK/data/www/luci-static/resources/view/status/include"
cp -a "$REPO/htdocs/." "$WORK/data/www/"

# Stamp the version into the two files that report it. The checkout keeps the
# raw token, so a file edited in place on a router and never rebuilt reports
# itself as "dev" rather than claiming to be a release.
STAMPED=0
for f in "$WORK/data/www/cgi-bin/get-temp-history.cgi" \
         "$WORK/data/www/luci-static/resources/view/status/temperature-history.js"; do
  grep -q '@@PKG_VERSION@@' "$f" || { echo "no version token in $f" >&2; exit 1; }
  sed -i "s/@@PKG_VERSION@@/$STAMP/g" "$f"
  STAMPED=$((STAMPED + 1))
done
[ "$STAMPED" = "2" ] || { echo "expected to stamp 2 files, stamped $STAMPED" >&2; exit 1; }

# rpcd ignores a plugin without the user-execute bit, and a copy out of a
# checkout is not a mode guarantee. Set them explicitly.
chmod 0755 "$WORK/data/usr/libexec/temp-history/"*.sh \
           "$WORK/data/usr/libexec/rpcd/"* \
           "$WORK/data/www/cgi-bin/"*

# ── Control ────────────────────────────────────────────────────────────────
cat > "$WORK/ctl/control" <<EOF
Package: $NAME
Version: $IPKVER
Depends: luci-base
Architecture: all
Section: luci
Maintainer: Void
License: GPL-3.0-or-later
Description: Temperature and fan history for LuCI.
 Long-term temperature and fan monitoring with a 30-day chart, configurable
 thresholds, manual fan control, and watchdogs that report a stalled fan, a
 stopped collector or a threshold crossing rather than leaving them silent.
 Readings are buffered in RAM and committed to flash once a day.
EOF

printf '/etc/config/temp_history\n' > "$WORK/ctl/conffiles"

# Identical to the Makefile's definitions: three lines calling the shipped
# setup script, which is where the real work lives.
cat > "$WORK/ctl/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/usr/libexec/temp-history/setup.sh install
exit 0
EOF
cat > "$WORK/ctl/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/usr/libexec/temp-history/setup.sh remove
exit 0
EOF
chmod 0755 "$WORK/ctl/postinst" "$WORK/ctl/prerm"

# ── .ipk ───────────────────────────────────────────────────────────────────
printf '2.0\n' > "$WORK/debian-binary"
tar --numeric-owner --owner=0 --group=0 --mtime='@0' -czf "$WORK/data.tar.gz"    -C "$WORK/data" .
tar --numeric-owner --owner=0 --group=0 --mtime='@0' -czf "$WORK/control.tar.gz" -C "$WORK/ctl"  .
tar --numeric-owner --owner=0 --group=0 --mtime='@0' -czf "$OUT/${NAME}_${IPKVER}_all.ipk" \
    -C "$WORK" debian-binary data.tar.gz control.tar.gz
echo "built $OUT/${NAME}_${IPKVER}_all.ipk"

# ── .apk, for OpenWrt 25.12+ ───────────────────────────────────────────────
# apk-tools 3 special-cases arch "noarch" as universally compatible, and /etc
# is a BUILT-IN protected path, so the conffile behaviour comes for free.
# `apk mkpkg --help` exits 1 in apk-tools 3.0.7 (it complains about the
# missing info fields instead of printing help), so test for the subcommand by
# what it says, not by its exit status.
if command -v apk >/dev/null 2>&1 && \
   apk mkpkg 2>&1 | grep -q "required info field"; then
  apk mkpkg \
    --info "name:$NAME" \
    --info "version:$APKVER" \
    --info "arch:noarch" \
    --info "description:Temperature and fan history for LuCI" \
    --info "license:GPL-3.0-or-later" \
    --info "origin:$NAME" \
    --script "post-install:$WORK/ctl/postinst" \
    --script "pre-deinstall:$WORK/ctl/prerm" \
    --files "$WORK/data" \
    --output "$OUT/${NAME}_${APKVER}_noarch.apk"
  echo "built $OUT/${NAME}_${APKVER}_noarch.apk"
else
  echo "note: no apk-tools 3 here, skipped the .apk (build it on the router)" >&2
fi
