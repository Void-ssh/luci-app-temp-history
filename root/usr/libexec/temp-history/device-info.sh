#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# device-info.sh
# What this router is, for the line at the foot of the Temperature page.
#
# NOT web-reachable. Reached through ubus (luci.temp-status.getDevice /
# luci.temp-history.getDevice), which LuCI authenticates.
#
# Deliberately NOT added to the CGI payload, even though it is read-only and
# would have been one less round trip. /www/cgi-bin is unauthenticated by
# construction, and a firmware version is the first thing worth knowing if you
# are looking for a router with a published CVE. The page can afford one ubus
# call for something it draws once.
#
#   device-info.sh          JSON: model, GL firmware fields, OpenWrt, kernel
#
# Every field is independently optional. A vanilla OpenWrt box has none of the
# /etc/version.* files and no /proc/gl-hw-info; it still gets a model and a
# distribution string, and the page simply draws the parts that exist.

# JSON string escaping. These come from files a vendor writes, not from us:
# /etc/version.date has spaces on some builds, and a stray quote would produce
# a payload that parses as nothing at all rather than as a slightly wrong
# version. Backslash first, or it escapes the escapes.
jstr() {
  printf '%s' "$1" \
    | tr -d '\r\n' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g'
}

# Reads one line from a file, or nothing. Never errors: an absent file here is
# the normal case on anything that is not GL.iNet firmware.
slurp() {
  [ -r "$1" ] || return 0
  _s=""
  read -r _s 2>/dev/null < "$1"
  printf '%s' "$_s"
}

# The friendly board name. /tmp/sysinfo/model is the OpenWrt convention and is
# what every other LuCI page shows, so prefer it and stay consistent with them.
# /proc/gl-hw-info/model is the GL fallback, but it holds a short code
# (a short model code) rather than a name, so it is only used when the standard file is
# missing.
model() {
  _m=$(slurp /tmp/sysinfo/model)
  [ -n "$_m" ] || _m=$(slurp /proc/gl-hw-info/model)
  [ -n "$_m" ] || _m=$(slurp /tmp/sysinfo/board_name)
  printf '%s' "$_m"
}

# DISTRIB_DESCRIPTION, without sourcing /etc/openwrt_release. Sourcing it runs
# whatever is in it as shell; this file is written by the build system and is
# not hostile, but reading a value does not need code execution.
distrib() {
  [ -r /etc/openwrt_release ] || return 0
  sed -n "s/^DISTRIB_DESCRIPTION=[\"']\{0,1\}\(.*\)/\1/p" /etc/openwrt_release 2>/dev/null \
    | sed -e "s/[\"']$//" | head -n 1
}

GL_VER=$(slurp /etc/glversion)
GL_TYPE=$(slurp /etc/version.type)
GL_BUILD=$(slurp /etc/version.build)
GL_DATE=$(slurp /etc/version.date)

printf '{"model":"%s","gl_version":"%s","gl_type":"%s","gl_build":"%s","gl_date":"%s","openwrt":"%s","kernel":"%s"}\n' \
  "$(jstr "$(model)")" \
  "$(jstr "$GL_VER")" \
  "$(jstr "$GL_TYPE")" \
  "$(jstr "$GL_BUILD")" \
  "$(jstr "$GL_DATE")" \
  "$(jstr "$(distrib)")" \
  "$(jstr "$(uname -r 2>/dev/null)")"
exit 0
