#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# setup.sh install | remove
#
# Everything the package's postinst and prerm need to do, in a file that ships
# WITH the package rather than living only inside packaging metadata. Three
# reasons that matters:
#
#   • One copy of the truth. The OpenWrt Makefile and tools/build-ipk.sh both
#     produce control scripts that are three lines long and call this.
#   • It can be re-run. If the crontab is wiped — an uninstall, a restore, a
#     firmware upgrade that keeps /etc but not /etc/crontabs — then
#     `setup.sh install` puts collection back without reinstalling anything.
#   • It can be tested, and is.

HELPER_DIR="/usr/libexec/temp-history"
COLLECT="$HELPER_DIR/collect-temp-history.sh"
FLUSH="$HELPER_DIR/flush-temp-history.sh"
FANCTL="$HELPER_DIR/fan-control.sh"
SETPOINTS="$HELPER_DIR/glfan-setpoints.sh"
DEVINFO="$HELPER_DIR/device-info.sh"
CGI="/www/cgi-bin/get-temp-history.cgi"
RPCD_PLUGIN="/usr/libexec/rpcd/luci.temp-history"
DATA_DIR="/root/website"

do_install() {
  # rpcd SKIPS any file in /usr/libexec/rpcd without the user-execute bit
  # (plugin.c: !(s.st_mode & S_IXUSR) -> continue), so this chmod is what
  # makes the authenticated flush/reset methods exist at all.
  chmod 0755 "$COLLECT" "$FLUSH" "$FANCTL" "$SETPOINTS" "$DEVINFO" "$CGI" "$RPCD_PLUGIN" 2>/dev/null

  mkdir -p "$DATA_DIR"

  # The collector and flush helpers used to live in /www/cgi-bin, which made
  # both callable over HTTP by anyone who could reach the web port. Remove
  # old copies on upgrade: leaving them would keep an unauthenticated flush
  # endpoint alive next to the fixed one.
  rm -f /www/cgi-bin/collect-temp-history.sh /www/cgi-bin/flush-temp-history.sh
  rm -f /www/luci-static/resources/svg/temperature.svg

  # ── UCI defaults ────────────────────────────────────────────────────────
  # /etc/config/temp_history ships with the package and is a conffile, so an
  # upgrade preserves edits. This only fills in what is MISSING, which covers
  # a config deleted by hand and any option added in a later release.
  [ -f /etc/config/temp_history ] || touch /etc/config/temp_history
  uci -q get temp_history.main >/dev/null 2>&1 || \
    uci -q set temp_history.main='temp-history'
  # glfan_ui_patch defaults to 0: the setpoint feature changes gl_fan's own
  # configuration out of the box and leaves GL's admin bundles alone. Patching
  # those is the risky half and is opted into from the Settings panel.
  for pair in warn_temp=65 crit_temp=80 max_rows=2880 cgi_write=auto \
              fan_control=1 fan_min_percent=25 fan_override_minutes=30 \
              glfan_ui_patch=0; do
    opt="${pair%%=*}"; val="${pair#*=}"
    [ -n "$(uci -q get "temp_history.main.$opt")" ] || \
      uci -q set "temp_history.main.$opt=$val"
  done
  uci -q commit temp_history

  # Rewrite the crontab in ONE pass. Doing it as three piped `crontab -`
  # calls leaves a window where the entries are missing entirely, and costs
  # three flash writes instead of one.
  {
    crontab -l 2>/dev/null | grep -v 'collect-temp-history\|flush-temp-history'
    echo "*/15 * * * * $COLLECT"
    echo "5 1 * * * $FLUSH"
  } | crontab - 2>/dev/null

  # Nothing collects if cron is not running, and cron is one of the first
  # services stripped from a debloated build — which otherwise leaves the
  # page showing "No data yet" forever with no clue why.
  /etc/init.d/cron enable  >/dev/null 2>&1
  /etc/init.d/cron restart >/dev/null 2>&1

  # One collection immediately, so the page has something to show.
  "$COLLECT" >/dev/null 2>&1 &

  # rpcd must reload for the ACL scope and the ubus methods to register.
  # Until it does the frontend falls back to the CGI, so a missed reload
  # degrades rather than breaks.
  /etc/init.d/rpcd reload >/dev/null 2>&1 || true

  rm -f /tmp/luci-indexcache* 2>/dev/null
  rm -rf /tmp/luci-modulecache 2>/dev/null
  return 0
}

do_remove() {
  # Commit whatever is in the RAM buffer before the helper that knows how is
  # removed, so uninstalling does not silently discard up to a day of
  # readings. Data files in $DATA_DIR are intentionally left behind.
  [ -x "$FLUSH" ] && "$FLUSH" >/dev/null 2>&1

  # Never leave the fan pinned by an override whose guard is about to be
  # deleted. Kernel control is restored before anything is removed.
  [ -x "$FANCTL" ] && "$FANCTL" auto >/dev/null 2>&1

  crontab -l 2>/dev/null \
    | grep -v 'collect-temp-history\|flush-temp-history' \
    | crontab - 2>/dev/null || true

  rm -f /tmp/temp-history-buf.log /tmp/uptime-history-buf.log \
        /tmp/fan-history-buf.log /tmp/sys-history-buf.log \
        /tmp/temp-history-cpu.state /tmp/temp-history-cpu-live.state \
        /tmp/temp-history-cpu-widget.state \
        /tmp/temp-history-zero.warn /tmp/temp-history-reset.stamp \
        /tmp/temp-history-levels.state /tmp/temp-history-fan.stall \
        /tmp/temp-history-fan.state /tmp/temp-history-fan.saved \
        /tmp/temp-history-fan.pid
  rmdir /tmp/temp-history-flush.lock 2>/dev/null
  return 0
}

case "$1" in
  install) do_install ;;
  remove)  do_remove ;;
  *)
    printf 'usage: %s {install|remove}\n' "${0##*/}" >&2
    exit 1
    ;;
esac
exit 0
