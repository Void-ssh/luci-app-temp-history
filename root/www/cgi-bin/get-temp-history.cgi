#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# get-temp-history.cgi
# Serves temperature history as JSON.
#
# Modes (via QUERY_STRING):
#   (default)    Full payload: history (downsampled), min/max, today avg,
#                uptime, configured thresholds, schema state
#   ?live=1      Lightweight: current readings only (~200 bytes). Used by 60s poll.
#   ?flush=1     Flush RAM buffer to flash. MUTATING — see the gate below.
#   ?reset=N     Reset min/max for sensor index N.  MUTATING — see the gate below.
#
# The two MUTATING modes are a break-glass route only; they are closed by
# default whenever rpcd is working. Authentication happens over ubus instead —
# see the gate below for the full reasoning.
#
# Downsampling strategy (reduces 2880-row payload to ~450 rows):
#   Last 48 h  → all raw rows (15-min intervals)
#   48 h – 7 d → one row per hour  (keep first row in each 1-h bucket)
#   Older      → one row per 4 h   (keep first row in each 4-h bucket)

DATA_DIR="/root/website"
SENSOR_MAP="$DATA_DIR/temp-sensors.conf"
HISTORY_FILE="$DATA_DIR/temp-history.tsv"
UPTIME_FILE="$DATA_DIR/uptime-history.tsv"
RESET_FILE="$DATA_DIR/temp-reset.conf"
# Per-column min/max cutoffs for the CPU/memory series. A separate file from
# temp-reset.conf on purpose: that one is keyed by SENSOR INDEX, and a system
# column numbered 0 would silently share a cutoff with sensor 0.
SYS_RESET_FILE="$DATA_DIR/sys-reset.conf"
BUF_FILE="/tmp/temp-history-buf.log"
UPTIME_BUF="/tmp/uptime-history-buf.log"
RESET_STAMP="/tmp/temp-history-reset.stamp"
FAN_MAP="$DATA_DIR/fan-sensors.conf"
FAN_FILE="$DATA_DIR/fan-history.tsv"
FAN_BUF="/tmp/fan-history-buf.log"
SYS_FILE="$DATA_DIR/sys-history.tsv"
SYS_BUF="/tmp/sys-history-buf.log"
FAN_STALL="/tmp/temp-history-fan.stall"
FAN_SCRIPT="/usr/libexec/temp-history/fan-control.sh"
FLUSH_SCRIPT="/usr/libexec/temp-history/flush-temp-history.sh"

# Stamped at package time by tools/build-ipk.sh (and by the OpenWrt
# Makefile). Reported in the full payload so the page can tell
# the version it was SERVED from the version it is RUNNING — they differ only
# when a browser is showing a cached copy after an upgrade.
PKG_VERSION="@@PKG_VERSION@@"
case "$PKG_VERSION" in "@@"*) PKG_VERSION="dev" ;; esac

DEFAULT_WARN=65
DEFAULT_CRIT=80

QUERY="${QUERY_STRING:-}"
TAB="	"  # literal tab

# ── Response headers ───────────────────────────────────────────────────────
# No Access-Control-Allow-Origin: this endpoint is same-origin only.
emit_headers() {
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  printf 'Referrer-Policy: no-referrer\r\n'
  printf '\r\n'
}

fail() {
  printf 'Status: %s\r\n' "$1"
  emit_headers
  printf '{"error":"%s"}\n' "$2"
  exit 0
}

uci_get() {  # uci_get <option> <default>
  _ug=$(uci -q get "temp_history.main.$1" 2>/dev/null)
  case "$_ug" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$_ug" ;; esac
}

# ── Gate for mutating modes ────────────────────────────────────────────────
#
# This path is NOT where authentication happens, because a raw CGI under
# /www/cgi-bin structurally cannot do it:
#
#   a custom header     uhttpd forwards only a fixed allowlist of request
#                       headers to CGI scripts (proc_header_env[] in uhttpd's
#                       proc.c), so it is discarded before this script runs.
#   the session cookie  LuCI sets it with path=/cgi-bin/luci
#                       (dispatcher.lua: build_url()), so the browser
#                       correctly withholds it from a sibling path like this
#                       one.
#
# Both operations now run over ubus instead, authenticated by LuCI on every
# OpenWrt version: luci.temp-status (ucode, 22.03+) and luci.temp-history
# (rpcd shell plugin, all versions, including 21.02).
#
# What remains here is a break-glass route, and it is honest about that: it is
# NOT authenticated. cgi_write=auto closes it automatically whenever either
# ubus object answers — which is whenever rpcd is working — so in normal
# operation it is shut on every router. It opens only when rpcd is dead, which
# is also when you could not have logged into LuCI to reach it anyway.
#
#   auto (default)  refuse if luci.temp-status or luci.temp-history answers
#   0               always refuse
#   1               allow: POST and a matching Origin, nothing more
#
# POST-only plus the Origin check still stops a cross-site drive-by. It does
# not stop anything already on your LAN. If that matters, set cgi_write=0 and
# flush over SSH with /usr/libexec/temp-history/flush-temp-history.sh.

ubus_backend_present() {
  ubus -t 1 list luci.temp-status  >/dev/null 2>&1 && return 0
  ubus -t 1 list luci.temp-history >/dev/null 2>&1 && return 0
  return 1
}

require_mutating_request() {
  [ "${REQUEST_METHOD:-GET}" = "POST" ] || \
    fail "405 Method Not Allowed" "this operation requires POST"

  # Origin is one of the headers uhttpd does forward, and is what it is for.
  if [ -n "${HTTP_ORIGIN:-}" ]; then
    _org="${HTTP_ORIGIN#*://}"
    [ "$_org" = "${HTTP_HOST:-}" ] || \
      fail "403 Forbidden" "cross-origin request refused"
  fi

  case "$(uci -q get temp_history.main.cgi_write 2>/dev/null)" in
    0) fail "403 Forbidden" "disabled by cgi_write=0" ;;
    1) return 0 ;;
    *) ubus_backend_present && \
         fail "403 Forbidden" "disabled — use the authenticated ubus method (luci.temp-status or luci.temp-history)"
       return 0 ;;
  esac
}

# ── Flush mode ─────────────────────────────────────────────────────────────
case "$QUERY" in
  *flush=1*)
    require_mutating_request
    emit_headers
    if [ -x "$FLUSH_SCRIPT" ]; then
      "$FLUSH_SCRIPT"
    else
      printf '{"error":"flush helper missing at %s"}\n' "$FLUSH_SCRIPT"
    fi
    exit 0
    ;;
esac

# ── Reset mode — pure shell, no sed/grep forks for parsing ────────────────
case "$QUERY" in
  *reset=*)
    require_mutating_request
    SENSOR_IDX="${QUERY#*reset=}"
    SENSOR_IDX="${SENSOR_IDX%%&*}"
    # reset=sysN targets a CPU/memory column; reset=N a temperature sensor.
    SYS_COL=""
    case "$SENSOR_IDX" in
      sys*) SYS_COL="${SENSOR_IDX#sys}"; SYS_COL="${SYS_COL%%[!0-9]*}"
            [ -n "$SYS_COL" ] || fail "400 Bad Request" "invalid system column"
            [ "$SYS_COL" -le 2 ] 2>/dev/null || fail "400 Bad Request" "invalid system column"
            ;;
    esac
    SENSOR_IDX="${SENSOR_IDX%%[!0-9]*}"
    [ -n "$SENSOR_IDX" ] || [ -n "$SYS_COL" ] || fail "400 Bad Request" "invalid sensor index"

    NOW_R=$(date +%s)

    # Rate limit. Each reset rewrites a file in /root/website, i.e. a flash
    # write, so a stuck or malicious client must not be able to loop on it.
    LAST_R=0
    read -r LAST_R 2>/dev/null < "$RESET_STAMP" || LAST_R=0
    case "$LAST_R" in ''|*[!0-9]*) LAST_R=0 ;; esac
    if [ "$(( NOW_R - LAST_R ))" -lt 3 ]; then
      fail "429 Too Many Requests" "reset rate limited, try again shortly"
    fi
    printf '%s\n' "$NOW_R" > "$RESET_STAMP"

    mkdir -p "$DATA_DIR"
    TMP_R="/tmp/th_reset_$$.tmp"
    trap 'rm -f "$TMP_R"' EXIT INT TERM HUP
    if [ -n "$SYS_COL" ]; then
      grep -v "^${SYS_COL}${TAB}" "$SYS_RESET_FILE" 2>/dev/null > "$TMP_R" || true
      printf '%s\t%s\n' "$SYS_COL" "$NOW_R" >> "$TMP_R"
      mv "$TMP_R" "$SYS_RESET_FILE"
      emit_headers
      printf '{"status":"ok","sys":%s,"reset_ts":%s}\n' "$SYS_COL" "$NOW_R"
      exit 0
    fi
    grep -v "^${SENSOR_IDX}${TAB}" "$RESET_FILE" 2>/dev/null > "$TMP_R" || true
    printf '%s\t%s\n' "$SENSOR_IDX" "$NOW_R" >> "$TMP_R"
    mv "$TMP_R" "$RESET_FILE"

    emit_headers
    printf '{"status":"ok","sensor":%s,"reset_ts":%s}\n' "$SENSOR_IDX" "$NOW_R"
    exit 0
    ;;
esac

# ── Export mode ──────────────────────────────────────────────────────
# Hands back one of the raw TSVs for spreadsheet work. Read-only, and strictly
# no more exposed than the JSON already is: the name selects from a FIXED list
# of four files, so nothing the caller sends is ever used to build a path.
case "$QUERY" in
  *export=*)
    _ex="${QUERY#*export=}"
    _ex="${_ex%%&*}"
    case "$_ex" in
      temp)   _exf="$HISTORY_FILE" ;;
      fan)    _exf="$FAN_FILE" ;;
      uptime) _exf="$UPTIME_FILE" ;;
      daily)  _exf="$DATA_DIR/temp-daily.tsv" ;;
      *)      fail "400 Bad Request" "unknown export" ;;
    esac
    if [ ! -f "$_exf" ]; then
      fail "404 Not Found" "no such series on this router"
    fi
    printf 'Content-Type: text/tab-separated-values; charset=utf-8\r\n'
    printf 'Content-Disposition: attachment; filename="%s"\r\n' "${_exf##*/}"
    printf 'Cache-Control: no-store\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf '\r\n'
    cat "$_exf"
    exit 0
    ;;
esac

# ── Read-only modes ────────────────────────────────────────────────────────
emit_headers

if [ ! -f "$SENSOR_MAP" ]; then
  printf '{"error":"sensor map not found — run collect-temp-history.sh first"}\n'
  exit 0
fi

# ── Single awk pass: sensor names (JSON-escaped) + current temps + paths ───
# Reads SENSOR_MAP once. For each sensor, reads the hardware sysfs file via
# getline — no per-sensor awk or sed subshell fork.
#
# Output is newline-separated rather than pipe-separated: a pipe-separated
# format assumes a sensor name can never contain "|", which is only true
# until someone names one "CPU|GPU" in temp-sensors.conf. Names come from a
# line-based file, so a newline genuinely cannot occur in one.
SENSOR_INFO=$(awk '
function esc(s) {
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
  gsub(/\t/, " ", s);    gsub(/\r/, "", s)
  # Strip control characters — invalid raw inside a JSON string
  gsub(/[\001-\037]/, "", s)
  return s
}
BEGIN { FS="\t"; s=""; c=""; p=""; sep=""; psep=""; n=0 }
/^#/ { next }
NF>=2 {
  path=$1; name=esc($2)
  raw=0
  if ((getline val < path) > 0) raw=val+0
  close(path)
  t=(raw>0)?sprintf("%.1f",raw/1000):"0.0"
  s=s sep "\"" name "\""; c=c sep t; sep=","
  p=p psep path; psep="\t"
  n++
}
END { printf "%d\n%s\n%s\n%s\n", n, s, c, p }' "$SENSOR_MAP")

{
  read -r NUM_SENSORS
  read -r SENSOR_NAMES_JSON
  read -r CURRENT_JSON
  read -r SENSOR_PATHS
} <<SENSOR_EOF
$SENSOR_INFO
SENSOR_EOF
case "$NUM_SENSORS" in ''|*[!0-9]*) NUM_SENSORS=0 ;; esac

# ── Fan names + current RPM ───────────────────────────────────────────────
# Same single-awk-pass shape as the sensors. Cheap enough for the 60s live
# poll: sysfs reads via getline, no per-fan fork. On passively cooled hardware
# the map holds only comments and this produces empty arrays.
#
# -1 in the map means "no tachometer"; it is emitted as JSON null. 0 is NOT a
# missing reading for a fan — it means the fan has stopped, which is exactly
# the thing you would want to see.
FAN_N=0; FAN_NAMES_JSON=""; FAN_RPM_JSON=""; FAN_PATHS=""; FAN_BROKEN=0
if [ -f "$FAN_MAP" ]; then
  FAN_INFO=$(awk '
  function esc(s) {
    gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
    gsub(/\t/, " ", s);    gsub(/\r/, "", s)
    gsub(/[\001-\037]/, "", s)
    return s
  }
  BEGIN { FS="\t"; s=""; r=""; p=""; sep=""; psep=""; n=0 }
  /^#/ { next }
  NF>=2 {
    tach=$1; name=esc($2)
    if (tach=="-") { v="null" }
    else {
      v="null"
      if ((getline raw < tach) > 0) { if (raw ~ /^[0-9]+$/) v=raw+0 }
      close(tach)
    }
    s=s sep "\"" name "\""; r=r sep v; sep=","
    # The parenthesised expression MUST be hoisted into a variable. Written
    # inline as `p psep (...)`, BusyBox awk on 21.02 parses `psep (` as a call
    # to a user function named psep and aborts the whole program at runtime
    # with "Call to undefined function" — which is how this router reported
    # zero fans while its map listed one. gawk, mawk and BusyBox 1.36 all
    # concatenate happily, so it cannot be reproduced off the router.
    fp = (tach=="-" && NF>=3 ? $3 : tach)
    p = p psep fp; psep="\t"
    n++
  }
  END { printf "%d\n%s\n%s\n%s\n", n, s, r, p }' "$FAN_MAP")
  {
    read -r FAN_N
    read -r FAN_NAMES_JSON
    read -r FAN_RPM_JSON
    read -r FAN_PATHS
  } <<FAN_EOF
$FAN_INFO
FAN_EOF
  case "$FAN_N" in ''|*[!0-9]*) FAN_N=0 ;; esac

  # A successful run of that awk ALWAYS prints four lines, because END is
  # unconditional. So an empty result means the awk itself died — which is
  # what a BusyBox-only parse difference looks like from out here. Say so.
  # Left unreported, it is indistinguishable from "this router has no fan",
  # and it did exactly that on real hardware for three releases.
  [ -n "$FAN_INFO" ] || FAN_BROKEN=1
fi

# ── Current CPU and memory ─────────────────────────────────────────────────
# On BOTH payloads, because the cards show them live and the chart needs the
# same units on the full reload.
#
# Memory is a reading. CPU is not: /proc/stat counts jiffies since boot, so a
# percentage only exists relative to a previous sample. Two ways to get one,
# and the choice matters more than it looks:
#
#   sample twice with a sleep in between — self-contained, but it puts a sleep
#     inside a CGI request, and BusyBox sleep does not always take a fractional
#     argument, so the fallback is a whole second of latency on every poll.
#   subtract a stored baseline — no sleep, and the window is the gap since the
#     last poll, which is the 60 seconds the page actually cares about.
#
# So: a baseline of our own in /tmp, distinct from the collector's. Sharing the
# collector's would corrupt the 15-minute series, and reading it would give a
# window of "however long since the last collection", which is 0 seconds right
# after one and 15 minutes just before the next.
#
# This means an unauthenticated endpoint writes a file. It is two integers in
# /tmp derived from /proc/stat, and the worst an attacker gains by polling is a
# shorter averaging window for whoever else is looking at the page. Weighed
# against a one-second sleep on every 60-second poll, that is the better trade.
CPU_LIVE_STATE="/tmp/temp-history-cpu-live.state"
CPU_NOW="null"
if [ -r /proc/stat ]; then
  _cl=""
  read -r _cl 2>/dev/null < /proc/stat
  case "$_cl" in
    cpu\ *)
      set -- $_cl
      shift
      _ct=0; _ci=0; _cx=0
      for _cf in "$@"; do
        case "$_cf" in ''|*[!0-9]*) continue ;; esac
        _ct=$(( _ct + _cf ))
        [ "$_cx" = 3 ] && _ci=$(( _ci + _cf ))
        [ "$_cx" = 4 ] && _ci=$(( _ci + _cf ))
        _cx=$(( _cx + 1 ))
      done
      _pt=0; _pi=0
      [ -r "$CPU_LIVE_STATE" ] && read -r _pt _pi 2>/dev/null < "$CPU_LIVE_STATE"
      case "$_pt" in ''|*[!0-9]*) _pt=0 ;; esac
      case "$_pi" in ''|*[!0-9]*) _pi=0 ;; esac
      printf '%s %s\n' "$_ct" "$_ci" > "$CPU_LIVE_STATE" 2>/dev/null
      _cd=$(( _ct - _pt )); _id=$(( _ci - _pi ))
      if [ "$_pt" -gt 0 ] && [ "$_cd" -gt 0 ] && [ "$_id" -ge 0 ]; then
        _cb=$(( _cd - _id )); [ "$_cb" -lt 0 ] && _cb=0
        _c10=$(( ( _cb * 1000 + _cd / 2 ) / _cd ))
        [ "$_c10" -gt 1000 ] && _c10=1000
        CPU_NOW=$(printf '%d.%d' "$(( _c10 / 10 ))" "$(( _c10 % 10 ))")
      fi
      ;;
  esac
fi

MEM_NOW="null"
MEM_NOW_C="null"
MEM_TOTAL_KB="null"
if [ -r /proc/meminfo ]; then
  _mt=0; _mf=0; _ma=0; _mb=0; _mc=0
  while read -r _mk _mv _mrest; do
    case "$_mk" in
      MemTotal:)     _mt="$_mv" ;;
      MemFree:)      _mf="$_mv" ;;
      MemAvailable:) _ma="$_mv" ;;
      Buffers:)      _mb="$_mv" ;;
      Cached:)       _mc="$_mv" ;;
    esac
  done < /proc/meminfo
  case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
  case "$_mf" in ''|*[!0-9]*) _mf=0 ;; esac
  case "$_ma" in ''|*[!0-9]*) _ma=0 ;; esac
  [ "$_ma" = 0 ] && _ma=$(( _mf + _mb + _mc ))
  if [ "$_mt" -gt 0 ]; then
    [ "$_ma" -gt "$_mt" ] && _ma="$_mt"
    _mu=$(( ( ( _mt - _ma ) * 1000 + _mt / 2 ) / _mt ))
    MEM_NOW=$(printf '%d.%d' "$(( _mu / 10 ))" "$(( _mu % 10 ))")
    _mk2=$(( ( ( _mt - _mf ) * 1000 + _mt / 2 ) / _mt ))
    MEM_NOW_C=$(printf '%d.%d' "$(( _mk2 / 10 ))" "$(( _mk2 % 10 ))")
    MEM_TOTAL_KB="$_mt"
  fi
fi

SYS_NOW_JSON=$(printf '{"cpu":%s,"mem":%s,"mem_cached":%s,"mem_total_kb":%s}' \
  "$CPU_NOW" "$MEM_NOW" "$MEM_NOW_C" "$MEM_TOTAL_KB")

# Live uptime, for the line above the uptime chart. Read here rather than
# derived from the newest recorded sample plus elapsed time: that derivation is
# correct right up until the router reboots, and then it confidently reports
# days of uptime for a machine that came up two minutes ago — which is the one
# moment anybody is looking.
#
# `read` rather than `cut`: this is on the 60-second live path, and a fork per
# poll for one field of one file is exactly the cost the live payload exists to
# avoid. /proc/uptime is a fraction ("1234.56"); ash has no floats, so the
# whole-second part is taken with a string chop.
UP_NOW=""
read -r UP_NOW _ 2>/dev/null < /proc/uptime
UP_NOW="${UP_NOW%%.*}"
case "$UP_NOW" in ''|*[!0-9]*) UP_NOW=null ;; esac

# ── Live mode (60-second card-only poll) ───────────────────────────────────
# Deliberately does NOT read UCI: this runs every 60 seconds and the
# thresholds cannot change between polls. The frontend caches warn/crit from
# the full payload, which it reloads every 10 minutes.
case "$QUERY" in
  *live=1*)
    printf '{"sensors":[%s],"current":[%s],"fans":[%s],"fan_rpm":[%s],"sys_now":%s,"uptime_now":%s}\n' \
      "$SENSOR_NAMES_JSON" "$CURRENT_JSON" "$FAN_NAMES_JSON" "$FAN_RPM_JSON" \
      "$SYS_NOW_JSON" "$UP_NOW"
    exit 0
    ;;
esac

# ── Full mode ──────────────────────────────────────────────────────────────
WARN_T=$(uci_get warn_temp "$DEFAULT_WARN")
CRIT_T=$(uci_get crit_temp "$DEFAULT_CRIT")
MAX_R=$(uci_get max_rows 2880)
[ "$CRIT_T" -gt "$WARN_T" ] 2>/dev/null || CRIT_T=$(( WARN_T + 1 ))
[ "$MAX_R" -ge 10 ] 2>/dev/null || MAX_R=10

# One date call for all components; strip leading zeros with ${var#0} before
# shell arithmetic — avoids BusyBox ash octal error on "08"/"09".
set -- $(date '+%s %H %M %S')
NOW=$1; _H="${2#0}"; _M="${3#0}"; _S="${4#0}"
MIDNIGHT=$(( NOW - ${_H:-0}*3600 - ${_M:-0}*60 - ${_S:-0} ))
RANGE_48H=$(( NOW - 172800 ))
RANGE_7D=$(( NOW - 604800 ))

if [ "$NUM_SENSORS" -eq 0 ]; then
  printf '{"sensors":[],"current":[],"min":[],"max":[],"min_ts":[],"max_ts":[],"avg_today":[],"history":[],"uptime":[],"fans":[],"fan_rpm":[],"fan_history":[],"sys_history":[],"sys_min":[],"sys_max":[],"sys_min_ts":[],"sys_max_ts":[],"sys_avg_today":[],"sys_now":null,"fan_state":null,"buf_rows":0,"total_rows":0,"warn":%s,"crit":%s,"max_rows":%s,"schema":"empty","fan_schema":"ok"}\n' \
    "$WARN_T" "$CRIT_T" "$MAX_R"
  exit 0
fi

# ── Per-sensor reset timestamps ────────────────────────────────────────────
RESET_TS_STR=""
[ -f "$RESET_FILE" ] && \
  RESET_TS_STR=$(awk 'BEGIN{FS="\t";ORS=" "} NF>=2{print $1":"$2}' "$RESET_FILE")

SYS_RESET_STR=""
[ -f "$SYS_RESET_FILE" ] && \
  SYS_RESET_STR=$(awk 'BEGIN{FS="\t";ORS=" "} NF>=2{print $1":"$2}' "$SYS_RESET_FILE")

# ── Fan stall ────────────────────────────────────────────────────────
# The collector decides what counts as stalled — how many consecutive samples,
# and at what duty — and writes its verdict in the fourth field. Re-deciding
# it here would be a second definition to keep in step with the first.
FAN_STALL_JSON=""
if [ -f "$FAN_STALL" ]; then
  _fssep=""
  while IFS="$TAB" read -r _fsn _fsc _fss _fsv; do
    [ "$_fsv" = "stalled" ] || continue
    case "$_fss" in ''|*[!0-9]*) _fss=0 ;; esac
    FAN_STALL_JSON="${FAN_STALL_JSON}${_fssep}{\"name\":\"${_fsn}\",\"since\":${_fss}}"
    _fssep=","
  done < "$FAN_STALL"
fi

# ── Resolve input files (substitute /dev/null for missing files) ───────────
_uf1="$UPTIME_FILE";  [ -f "$_uf1" ] || _uf1="/dev/null"
_uf2="$UPTIME_BUF";   [ -f "$_uf2" ] || _uf2="/dev/null"
_tf1="$HISTORY_FILE"; [ -f "$_tf1" ] || _tf1="/dev/null"
_tf2="$BUF_FILE";     [ -f "$_tf2" ] || _tf2="/dev/null"
_ff1="$FAN_FILE";     [ -f "$_ff1" ] || _ff1="/dev/null"
_ff2="$FAN_BUF";      [ -f "$_ff2" ] || _ff2="/dev/null"
_sf1="$SYS_FILE";     [ -f "$_sf1" ] || _sf1="/dev/null"
_sf2="$SYS_BUF";      [ -f "$_sf2" ] || _sf2="/dev/null"

# ── Single combined awk pass over all four data files ─────────────────────
# File order: uptime_flash  uptime_buf  temp_flash  temp_buf
#
# temp-history.tsv carries a schema header as its first line —
#   #th1<TAB>path0<TAB>path1...
# recording which sensor produced each column. Header lines are skipped and
# excluded from total_rows, and the recorded paths are compared against the
# live sensor map so a changed temp-sensors.conf is reported rather than
# silently misread. "legacy" means the file carries no header at all; its
# rows are assumed to match the current layout, which is the assumption
# every headerless file was written under anyway.
BODY=$(awk \
  -v n="$NUM_SENSORS" \
  -v midnight="$MIDNIGHT" \
  -v r48="$RANGE_48H" \
  -v r7d="$RANGE_7D" \
  -v reset_str="$RESET_TS_STR" \
  -v sys_reset_str="$SYS_RESET_STR" \
  -v buffile="$BUF_FILE" \
  -v uf1="$_uf1" \
  -v uf2="$_uf2" \
  -v tf1="$_tf1" \
  -v ff1="$_ff1" \
  -v ff2="$_ff2" \
  -v sf1="$_sf1" \
  -v sf2="$_sf2" \
  -v fn="$FAN_N" \
  -v fanpaths="$FAN_PATHS" \
  -v fanbad="$FAN_BROKEN" \
  -v curpaths="$SENSOR_PATHS" \
'
# -1 is the collector sentinel for "no reading" (the first sample after a
# reboot has no CPU baseline to subtract from). 0 is a REAL value: an idle
# router. So only a negative number becomes null.
function jnum(v) {
  if (v=="" || v+0<0) return "null"
  return v+0
}

BEGIN {
  FS="\t"
  last_bkt_h=-1; last_bkt_4h=-1; hlen=0
  u_first=1; u_last_bkt_h=-1; u_last_bkt_4h=-1
  buf_rows=0; trows=0; uj=""
  schema="legacy"; saw_flash_row=0
  fan_schema="ok"; fan_saw=0; fhlen=0; last_ts=0
  f_last_h=-1; f_last_4h=-1
  shlen=0; s_last_h=-1; s_last_4h=-1
  n_parts=split(reset_str, parts, " ")
  for (p=1; p<=n_parts; p++) {
    if (parts[p]=="") continue
    split(parts[p], kv, ":")
    reset_ts[kv[1]+0] = kv[2]+0
  }
  n_sparts=split(sys_reset_str, sparts, " ")
  for (p=1; p<=n_sparts; p++) {
    if (sparts[p]=="") continue
    split(sparts[p], skv, ":")
    sys_reset_ts[skv[1]+0] = skv[2]+0
  }
}

# ── Schema header (temperature flash file only) ───────────────────────────
FILENAME==tf1 && /^#th1\t/ {
  hdr=substr($0, index($0, "\t")+1)
  schema=(hdr==curpaths) ? "ok" : "mismatch"
  next
}

# Must sit ABOVE the generic comment skip below, or the header line is
# swallowed by it and the schema check silently never runs.
FILENAME==ff1 && /^#fh1\t/ {
  fhdr=substr($0, index($0, "\t")+1)
  fan_schema=(fhdr==fanpaths) ? "ok" : "mismatch"
  next
}
/^#/ { next }

# ── Fan records ───────────────────────────────────────────────────────────
# Downsampled on the same buckets as the temperature series so the two charts
# share an x-axis.
FILENAME==ff1 || FILENAME==ff2 {
  ts=$1+0; if (ts==0) next
  if (FILENAME==ff1) fan_saw=1
  inc=0
  if      (ts>=r48)  { inc=1 }
  else if (ts>=r7d)  { b=int(ts/3600);  if(b!=f_last_h)  { f_last_h=b;  inc=1 } }
  else               { b=int(ts/14400); if(b!=f_last_4h) { f_last_4h=b; inc=1 } }
  if (!inc) next
  fhts[fhlen]=ts
  for(i=0;i<fn;i++) fhval[fhlen,i]=$(i+2)
  fhlen++
  next
}

# ── System records: CPU % and the two memory figures ──────────────────────
# Downsampled on the same buckets as everything else so all the charts share
# one x-axis. -1 is the sentinel for "not available", which is a real state on
# the first sample after a reboot: the CPU delta has nothing to subtract from
# yet.
FILENAME==sf1 || FILENAME==sf2 {
  ts=$1+0; if (ts==0) next

  # Min, max and today average, over EVERY row rather than the downsampled
  # ones — the same order the temperature block uses, and for the same reason:
  # a peak that fell in a bucket we did not keep is still a peak that happened.
  #
  # The skip test is v<0, NOT v<=0 as the temperatures use. There 0.0 means an
  # unreadable sensor; here 0 is a real and extremely common reading, an idle
  # CPU, and dropping it would report a minimum that never occurred.
  for (j=0;j<3;j++) {
    sv=$(j+2)
    if (sv=="") continue
    sv=sv+0
    if (sv<0) continue
    if (ts>=midnight) { s_avg_sum[j]+=sv; s_avg_cnt[j]++ }
    # The cutoff applies to the records only, never to today average — the
    # same order the temperature block uses. Resetting the record for a column
    # should not rewrite what today actually averaged.
    if ((j in sys_reset_ts) && ts<sys_reset_ts[j]) continue
    if (!(j in s_min) || sv<s_min[j]) { s_min[j]=sv; s_min_ts[j]=ts }
    if (!(j in s_max) || sv>s_max[j]) { s_max[j]=sv; s_max_ts[j]=ts }
  }

  inc=0
  if      (ts>=r48)  { inc=1 }
  else if (ts>=r7d)  { b=int(ts/3600);  if(b!=s_last_h)  { s_last_h=b;  inc=1 } }
  else               { b=int(ts/14400); if(b!=s_last_4h) { s_last_4h=b; inc=1 } }
  if (!inc) next
  shts[shlen]=ts
  shc[shlen]=$2
  shm[shlen]=$3
  shk[shlen]=$4
  shlen++
  next
}

# ── Uptime records (exact path match, not a substring test) ───────────────
FILENAME==uf1 || FILENAME==uf2 {
  ts=$1+0; if (ts==0) next
  inc=0
  if      (ts>=r48)  { inc=1 }
  else if (ts>=r7d)  { b=int(ts/3600);  if(b!=u_last_bkt_h)  { u_last_bkt_h=b;  inc=1 } }
  else               { b=int(ts/14400); if(b!=u_last_bkt_4h) { u_last_bkt_4h=b; inc=1 } }
  if (!inc) next
  if (!u_first) uj=uj ","
  uj=uj sprintf("{\"ts\":%d,\"u\":%d}", ts, $2+0)
  u_first=0
  next
}

# ── Temperature records ────────────────────────────────────────────────────
{
  ts=$1+0
  if (ts==0) next
  trows++
  if (FILENAME==buffile) buf_rows++
  if (FILENAME==tf1) saw_flash_row=1
  if (ts > last_ts) last_ts = ts

  for (i=0; i<n; i++) {
    v=$(i+2)+0
    if (v<=0) continue
    if (ts>=midnight) { avg_sum[i]+=v; avg_cnt[i]++ }
    if ((i in reset_ts) && ts<reset_ts[i]) continue
    if (!(i in minv) || v<minv[i]) { minv[i]=v; mints[i]=ts }
    if (!(i in maxv) || v>maxv[i]) { maxv[i]=v; maxts[i]=ts }
  }

  inc=0
  if      (ts>=r48)  { inc=1 }
  else if (ts>=r7d)  { b=int(ts/3600);  if(b!=last_bkt_h)  { last_bkt_h=b;  inc=1 } }
  else               { b=int(ts/14400); if(b!=last_bkt_4h) { last_bkt_4h=b; inc=1 } }
  if (inc) { hts[hlen]=ts; for(i=0;i<n;i++) hval[hlen,i]=$(i+2)+0; hlen++ }
}

END {
  # A flash file with no rows at all has no layout to disagree about.
  if (schema=="legacy" && !saw_flash_row) schema="ok"
  printf "\"uptime\":[%s]", uj
  printf ",\"min\":["
  for(i=0;i<n;i++){if(i>0)printf","; printf "%s",(i in minv?minv[i]:"null")}
  printf "],\"max\":["
  for(i=0;i<n;i++){if(i>0)printf","; printf "%s",(i in maxv?maxv[i]:"null")}
  printf "],\"min_ts\":["
  for(i=0;i<n;i++){if(i>0)printf","; printf "%s",(i in mints?mints[i]:"null")}
  printf "],\"max_ts\":["
  for(i=0;i<n;i++){if(i>0)printf","; printf "%s",(i in maxts?maxts[i]:"null")}
  printf "],\"avg_today\":["
  for(i=0;i<n;i++){if(i>0)printf","; if(avg_cnt[i]>0)printf"%.1f",avg_sum[i]/avg_cnt[i];else printf"null"}
  printf "],\"history\":["
  for(h=0;h<hlen;h++){
    if(h>0)printf","
    printf"{\"ts\":%d,\"t\":[",hts[h]
    for(i=0;i<n;i++){if(i>0)printf","; printf"%s",hval[h,i]}
    printf"]}"
  }
  printf "],\"fan_history\":["
  for(h=0;h<fhlen;h++){
    if(h>0)printf","
    printf"{\"ts\":%d,\"r\":[",fhts[h]
    for(i=0;i<fn;i++){
      if(i>0)printf","
      v=fhval[h,i]
      # -1 is the sentinel the collector writes for "no tachometer or
      # unreadable"; 0 is a real reading meaning the fan stopped, so only
      # a negative value becomes null.
      if(v=="" || v+0<0) printf"null"; else printf"%d", v+0
    }
    printf"]}"
  }
  printf "],\"sys_history\":["
  for(h=0;h<shlen;h++){
    if(h>0)printf","
    printf"{\"ts\":%d,\"c\":%s,\"m\":%s,\"k\":%s}", shts[h], jnum(shc[h]), jnum(shm[h]), jnum(shk[h])
  }
  printf "]"
  printf ",\"sys_min\":["
  for(j=0;j<3;j++){if(j>0)printf","; printf "%s",(j in s_min?s_min[j]:"null")}
  printf "],\"sys_max\":["
  for(j=0;j<3;j++){if(j>0)printf","; printf "%s",(j in s_max?s_max[j]:"null")}
  printf "],\"sys_min_ts\":["
  for(j=0;j<3;j++){if(j>0)printf","; printf "%s",(j in s_min_ts?s_min_ts[j]:"null")}
  printf "],\"sys_max_ts\":["
  for(j=0;j<3;j++){if(j>0)printf","; printf "%s",(j in s_max_ts?s_max_ts[j]:"null")}
  printf "],\"sys_avg_today\":["
  for(j=0;j<3;j++){
    if(j>0)printf","
    if(s_avg_cnt[j]>0) printf"%.1f", s_avg_sum[j]/s_avg_cnt[j]
    else printf"null"
  }
  printf "]"
  # fanbad wins: if the fan map could not be parsed at all, reporting a
  # schema verdict about it would be a guess dressed as a fact.
  fs = (fanbad+0 ? "unreadable" : (fan_saw ? fan_schema : "ok"))
  printf ",\"fan_schema\":\"%s\"", fs
  printf ",\"buf_rows\":%d,\"total_rows\":%d,\"schema\":\"%s\"", buf_rows, trows, schema
  # The newest sample actually recorded. The page compares it against
  # the router clock (see "now" below) to tell "nothing is happening" apart
  # from "nothing is being recorded" — a dead cron looks exactly like a quiet
  # router otherwise, and this package has already had its crontab removed
  # once by an uninstall.
  printf ",\"last_sample\":%d", last_ts
}' "$_uf1" "$_uf2" "$_ff1" "$_ff2" "$_sf1" "$_sf2" "$_tf1" "$_tf2")

# Fan control state comes from the helper so there is one implementation of
# the mode/expiry logic. Only on the full payload — the 60s live poll must not
# pay for a fork.
FAN_STATE='null'
if [ "$FAN_N" -gt 0 ] && [ -x "$FAN_SCRIPT" ]; then
  _fs=$("$FAN_SCRIPT" status 2>/dev/null)
  case "$_fs" in '{'*) FAN_STATE="$_fs" ;; esac
fi

# If the body awk died, splicing an empty $BODY produces `...,}` — invalid
# JSON, which the page reports as a parse failure with nothing to act on.
# Emit a well-formed payload that names the problem instead.
if [ -z "$BODY" ]; then
  BODY='"min":[],"max":[],"min_ts":[],"max_ts":[],"avg_today":[],"history":[],"uptime":[],"fan_history":[],"sys_history":[],"sys_min":[],"sys_max":[],"sys_min_ts":[],"sys_max_ts":[],"sys_avg_today":[],"fan_schema":"unreadable","buf_rows":0,"total_rows":0,"schema":"unreadable"'
fi

# "now" is the ROUTER's clock. The page needs it to judge sample freshness:
# comparing against the browser's clock would report a stalled collector on
# any machine whose time is a few minutes out, which is most of them.
printf '{"sensors":[%s],"current":[%s],"fans":[%s],"fan_rpm":[%s],"fan_state":%s,"fan_stall":[%s],"sys_now":%s,"warn":%s,"crit":%s,"max_rows":%s,"version":"%s","now":%s,"uptime_now":%s,%s}\n' \
  "$SENSOR_NAMES_JSON" "$CURRENT_JSON" "$FAN_NAMES_JSON" "$FAN_RPM_JSON" "$FAN_STATE" \
  "$FAN_STALL_JSON" "$SYS_NOW_JSON" "$WARN_T" "$CRIT_T" "$MAX_R" "$PKG_VERSION" "$NOW" "$UP_NOW" "$BODY"
