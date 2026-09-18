#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# reset-history.sh  daily | all
#
# Starts a fresh series, from the Settings panel or over SSH.
#
#   daily   Sets the daily rollup aside. Nearly free: roll_daily rebuilds
#           every complete day still present in temp-history.tsv on the next
#           flush, so this is a REPAIR, not a loss — which is why the page
#           offers it without ceremony.
#
#   all     Sets every series aside as well: temperatures, fan, CPU/memory,
#           uptime and the rollup. Nothing rebuilds these. This is the one
#           irreversible action in the package.
#
# NOTHING IS DELETED. Each file is renamed to <name>.<timestamp>.old, exactly
# as flush-temp-history.sh already does when a sensor set changes ("previous
# data kept as ..., started a fresh series"). A mis-click therefore costs a
# `mv` over SSH rather than six months of readings. The cost is one stale file
# per use; the paths are reported so they can be removed deliberately.
#
# NOT web-reachable. Reached through ubus (luci.temp-status.resetHistory /
# luci.temp-history.resetHistory), which LuCI authenticates — a destructive
# operation has no business on the unauthenticated CGI.

# stdout is the JSON result and nothing else; see the same note in
# flush-temp-history.sh for why this is enforced rather than reviewed.
exec 3>&1 1>&2

DATA_DIR="/root/website"
HISTORY_FILE="$DATA_DIR/temp-history.tsv"
UPTIME_FILE="$DATA_DIR/uptime-history.tsv"
FAN_FILE="$DATA_DIR/fan-history.tsv"
SYS_FILE="$DATA_DIR/sys-history.tsv"
DAILY_FILE="$DATA_DIR/temp-daily.tsv"
RESET_FILE="$DATA_DIR/temp-reset.conf"
SYS_RESET_FILE="$DATA_DIR/sys-reset.conf"
BUF_FILE="/tmp/temp-history-buf.log"
UPTIME_BUF="/tmp/uptime-history-buf.log"
FAN_BUF="/tmp/fan-history-buf.log"
SYS_BUF="/tmp/sys-history-buf.log"
LOCK_DIR="/tmp/temp-history-flush.lock"

SCOPE="${1:-}"
case "$SCOPE" in
  daily|all) ;;
  *) printf '{"status":"error","error":"scope must be daily or all"}\n' >&3
     exit 0 ;;
esac

# The SAME lock the flush takes. Renaming a series out from under a running
# flush would let it append to a file that is no longer the current one, and
# the row counts it reports would describe a file nobody will ever read again.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf '{"status":"busy","error":"a flush is running, try again shortly"}\n' >&3
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM HUP

STAMP=$(date +%Y%m%d%H%M%S)
ROTATED=""
N_ROT=0
ROWS=0

# Counts DATA rows, so the reported figure matches what the page shows rather
# than being one higher wherever a schema header exists.
rows_in() {
  [ -f "$1" ] || { printf '0'; return 0; }
  _ri=$(grep -vc '^#' "$1" 2>/dev/null)
  case "$_ri" in ''|*[!0-9]*) _ri=0 ;; esac
  printf '%s' "$_ri"
}

# JSON string escaping — these are paths this script builds, but a DATA_DIR
# with a quote in it would otherwise produce a payload that parses as nothing.
jstr() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

rotate() {
  [ -f "$1" ] || return 0
  _n=$(rows_in "$1")
  if mv "$1" "$1.$STAMP.old" 2>/dev/null; then
    ROWS=$(( ROWS + _n ))
    N_ROT=$(( N_ROT + 1 ))
    [ -n "$ROTATED" ] && ROTATED="$ROTATED,"
    ROTATED="$ROTATED\"$(jstr "$1.$STAMP.old")\""
    logger -t temp-history -p daemon.warning \
      "reset ($SCOPE): $1 set aside as $1.$STAMP.old ($_n rows)"
  fi
}

rotate "$DAILY_FILE"

if [ "$SCOPE" = "all" ]; then
  rotate "$HISTORY_FILE"
  rotate "$FAN_FILE"
  rotate "$SYS_FILE"
  rotate "$UPTIME_FILE"

  # The RAM buffers too. Leaving them would let the very next flush append
  # readings from before the reset onto the fresh series, which is precisely
  # the mixing the schema header exists to prevent.
  rm -f "$BUF_FILE" "$UPTIME_BUF" "$FAN_BUF" "$SYS_BUF" 2>/dev/null

  # Per-sensor min/max cutoffs. They name a moment to ignore readings before;
  # with no readings left they can only hide the new series from itself.
  rm -f "$RESET_FILE" "$SYS_RESET_FILE" 2>/dev/null
fi

printf '{"status":"ok","scope":"%s","rotated_files":%d,"rotated_rows":%d,"rotated":[%s]}\n' \
  "$SCOPE" "$N_ROT" "$ROWS" "$ROTATED" >&3
exit 0
