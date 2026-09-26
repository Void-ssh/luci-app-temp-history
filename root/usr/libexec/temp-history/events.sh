#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# events.sh
# The threshold crossings and fan stalls the collector already detects, read
# back out of the system log for the Events panel on the Temperature page.
#
# WHY THIS EXISTS
# collect-temp-history.sh has always logged the things worth knowing —
#
#   temp-history: CPU Temp reached 81.2 C  at or above crit (80 C)
#   temp-history: fan pwmfan is being driven at pwm 180 but reports 0 rpm
#
# — with `logger -t temp-history`, at daemon.err for the serious ones and
# daemon.notice for warnings and recoveries. Nobody reads syslog on a router,
# so the app did the hard part (noticing) and then put the answer somewhere
# it would never be seen. This reads it back.
#
# NOT web-reachable, and deliberately so. Reached only through ubus
# (luci.temp-status.getEvents / luci.temp-history.getEvents), which LuCI
# authenticates. The unauthenticated CGI does NOT carry events: the log is
# the one place on a router where unrelated daemons write unpredictable text,
# and /www/cgi-bin is readable by anyone who can reach port 80.
#
#   events.sh [limit]       JSON: {"supported":bool,"events":[...]}
#
# Events come back NEWEST FIRST, which is the order they are read in.

LIMIT="${1:-60}"
case "$LIMIT" in ''|*[!0-9]*) LIMIT=60 ;; esac
[ "$LIMIT" -lt 1 ] && LIMIT=1
[ "$LIMIT" -gt 500 ] && LIMIT=500

# No logread at all — a cut-down build, or syslog replaced. Not an error: the
# panel hides itself, exactly as it does for a router with nothing logged yet.
if ! command -v logread >/dev/null 2>&1; then
  printf '{"supported":false,"reason":"logread not present","events":[]}\n'
  exit 0
fi

# The whole ring buffer, filtered in awk rather than with `logread -e`: -e is
# missing from some busybox builds and silently returns nothing when it is,
# which would look exactly like a router that has never run hot.
logread 2>/dev/null | awk -v limit="$LIMIT" '
  # JSON string escaping. Verified to behave identically under busybox awk and
  # gawk: one backslash in becomes two out, a quote becomes backslash-quote.
  function jesc(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/[\001-\037]/, "", s)
    return s
  }

  # Lines look like
  #   Tue Sep  2 19:44:01 2026 daemon.err temp-history: CPU Temp reached ...
  # but the leading timestamp is formatted differently by busybox syslogd,
  # ubox logread and syslog-ng, and some builds insert a hostname. So the
  # facility.level field is found BY SHAPE and everything before it taken as
  # the timestamp, rather than counting fields from the left and breaking on
  # the first router that formats its dates differently.
  {
    fac = 0
    for (i = 1; i < NF; i++) {
      if ($i ~ /^[a-z][a-z0-9]*\.[a-z]+$/ && $(i + 1) ~ /^temp-history(\[[0-9]+\])?:$/) {
        fac = i
        break
      }
    }
    if (fac == 0) next

    lvl = $fac
    sub(/^[^.]*\./, "", lvl)

    # Built with an if rather than `ts (i > 1 ? ... )`: BusyBox awk reads an
    # identifier immediately followed by a parenthesis as a call to a function
    # that does not exist, so the neat form works everywhere except on the
    # routers this actually ships to.
    ts = ""
    for (i = 1; i < fac; i++) {
      if (ts != "") ts = ts " "
      ts = ts $i
    }

    msg = ""
    for (i = fac + 2; i <= NF; i++) {
      if (msg != "") msg = msg " "
      msg = msg $i
    }
    if (msg == "") next

    n++
    L[n] = lvl; T[n] = ts; M[n] = msg
  }

  END {
    printf "{\"supported\":true,\"events\":["
    first = n - limit + 1
    if (first < 1) first = 1
    sep = ""
    # Newest first: the last line read is the most recent event.
    for (i = n; i >= first; i--) {
      printf "%s{\"ts\":\"%s\",\"level\":\"%s\",\"msg\":\"%s\"}", \
        sep, jesc(T[i]), jesc(L[i]), jesc(M[i])
      sep = ","
    }
    printf "],\"total\":%d}\n", n + 0
  }
'
exit 0
