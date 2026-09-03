#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# flush-temp-history.sh
# Commits the RAM buffers to permanent storage in /root/website.
#
# Called by the nightly cron job (01:05), by the ubus methods
# luci.temp-status.flush and luci.temp-history.flush, and — only where ubus
# is unavailable — by get-temp-history.cgi?flush=1.
#
# DESIGN NOTES
#
#   • SELF-DESCRIBING FILES. The first line of each series records which
#     source produced each column:
#         #th1<TAB>path0<TAB>path1...      temperatures
#         #fh1<TAB>path0<TAB>path1...      fan RPM
#     Before appending, the header is compared against the live map. If they
#     differ the old file is ROTATED ASIDE rather than appended to, because
#     mixing two column layouts in one file silently corrupts every
#     historical row with no way to tell afterwards which rows meant what.
#     A file with no header (written before this existed) is migrated in
#     place when its column count matches, and rotated when it does not.
#
#   • NO LOST UPDATES. The buffer is renamed aside before being read, so a
#     concurrent collector append cannot fall into the gap between "cat" and
#     "truncate". Rename is atomic within /tmp. Measured before the fix: 19
#     rows lost in 1500.
#
#   • An mkdir-based lock stops a manual flush overlapping the nightly cron.
#
#   • Both series share one implementation: prepare_series() and flush_one()
#     take their file, tag and layout as parameters rather than reading
#     globals.
#
#   • No CGI headers are emitted here; the caller owns those.

DATA_DIR="/root/website"
HISTORY_FILE="$DATA_DIR/temp-history.tsv"
UPTIME_FILE="$DATA_DIR/uptime-history.tsv"
SENSOR_MAP="$DATA_DIR/temp-sensors.conf"
FAN_MAP="$DATA_DIR/fan-sensors.conf"
FAN_FILE="$DATA_DIR/fan-history.tsv"
# Never trimmed, by design — see roll_daily().
DAILY_FILE="$DATA_DIR/temp-daily.tsv"
BUF_FILE="/tmp/temp-history-buf.log"
UPTIME_BUF="/tmp/uptime-history-buf.log"
FAN_BUF="/tmp/fan-history-buf.log"
# CPU and memory. Fixed three columns that never depend on the hardware, so
# unlike the sensor and fan series this one needs no schema header and can
# never rotate: there is nothing about it that a changed router could
# invalidate.
SYS_FILE="$DATA_DIR/sys-history.tsv"
SYS_BUF="/tmp/sys-history-buf.log"
LOCK_DIR="/tmp/temp-history-flush.lock"

TAB="	"  # literal tab

TEMP_TAG="#th1"
FAN_TAG="#fh1"

MAX_ROWS=$(uci -q get temp_history.main.max_rows 2>/dev/null)
case "$MAX_ROWS" in ''|*[!0-9]*) MAX_ROWS=2880 ;; esac
[ "$MAX_ROWS" -lt 10 ] && MAX_ROWS=10

mkdir -p "$DATA_DIR"

FLUSHED_TEMP=0
FLUSHED_UPTIME=0
FLUSHED_SYS=0
FLUSHED_FAN=0
ROTATED=""

# ── Lock ───────────────────────────────────────────────────────────────────
# A stale lock (killed mid-flush) would otherwise wedge the flush forever, so
# a lock older than 5 minutes is broken. A real flush takes milliseconds.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || {
      printf '{"status":"busy","flushed_temp":0,"flushed_uptime":0}\n'
      exit 0
    }
  else
    printf '{"status":"busy","flushed_temp":0,"flushed_uptime":0}\n'
    exit 0
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM HUP

# ── Column layout of a map file, as a tab-joined path list ────────────────
map_paths() {  # map_paths <map-file>
  [ -f "$1" ] || return 0
  # Field 1 identifies the column. In the fan map a PWM-only entry has "-"
  # there, so fall back to its pwm path to keep the identity unique.
  awk 'BEGIN{FS="\t";sep=""} /^#/{next} NF>=1 && $1!="" {printf "%s%s",sep,($1=="-" && NF>=3 ? $3 : $1); sep="\t"}' "$1"
}
map_count() {  # map_count <map-file>
  [ -f "$1" ] || { printf '0'; return 0; }
  awk 'BEGIN{FS="\t";n=0} /^#/{next} NF>=1 && $1!="" {n++} END{print n+0}' "$1"
}

TEMP_PATHS=$(map_paths "$SENSOR_MAP"); TEMP_COUNT=$(map_count "$SENSOR_MAP")
# Names, for the daily rollup: a row saying "sensor 3" ages far worse than one
# saying "CPU Temp", and this file outlives every other in the package.
TEMP_NAMES=$(awk 'BEGIN{FS="\t";sep=""} /^#/{next} NF>=2 {printf "%s%s", sep, $2; sep="\t"}' "$SENSOR_MAP" 2>/dev/null)
FAN_PATHS=$(map_paths "$FAN_MAP");     FAN_COUNT=$(map_count "$FAN_MAP")
case "$TEMP_COUNT" in ''|*[!0-9]*) TEMP_COUNT=0 ;; esac
case "$FAN_COUNT"  in ''|*[!0-9]*) FAN_COUNT=0  ;; esac

# ── Reconcile a data file with the current layout ─────────────────────────
# prepare_series <data-file> <tag> <paths> <count> <label>
# Outcome: the file carries a matching header and is safe to append to, or the
# old file is rotated aside and a fresh one started. Never appends across two
# layouts — mixing them corrupts every historical row with no way to tell
# afterwards which rows meant what.
prepare_series() {
  _ps_f="$1"; _ps_tag="$2"; _ps_paths="$3"; _ps_n="$4"; _ps_label="$5"
  [ -n "$_ps_paths" ] || return 0        # no map yet — nothing to check

  if [ ! -s "$_ps_f" ]; then
    printf '%s\t%s\n' "$_ps_tag" "$_ps_paths" > "$_ps_f"
    return 0
  fi

  _ps_first=""
  read -r _ps_first 2>/dev/null < "$_ps_f"

  case "$_ps_first" in
    "$_ps_tag"*)
      _ps_old="${_ps_first#*	}"
      [ "$_ps_old" = "$_ps_paths" ] && return 0
      rotate_series "$_ps_f" "$_ps_tag" "$_ps_paths" "$_ps_label layout changed"
      return 0
      ;;
  esac

  # No header: written before schema headers existed. Those rows came from
  # whatever layout was current at the time, which cannot be recovered — but
  # the column count of the last row catches the case that actually matters
  # (entries added or removed).
  _ps_cols=$(awk -v tag="$_ps_tag" '
    index($0, tag)==1 {next}
    NF>0 {c=NF}
    END{print c+0}' FS='\t' "$_ps_f")

  if [ "$_ps_cols" -eq "$(( _ps_n + 1 ))" ]; then
    {
      printf '%s\t%s\n' "$_ps_tag" "$_ps_paths"
      cat "$_ps_f"
    } > "${_ps_f}.mig" && mv "${_ps_f}.mig" "$_ps_f"
    logger -t temp-history -p daemon.notice \
      "migrated $_ps_f to schema $_ps_tag ($_ps_n $_ps_label)"
  else
    rotate_series "$_ps_f" "$_ps_tag" "$_ps_paths" \
      "column count $_ps_cols does not match $_ps_n $_ps_label"
  fi
}

rotate_series() {  # rotate_series <file> <tag> <paths> <reason>
  _rs_f="$1"; _rs_tag="$2"; _rs_paths="$3"; _rs_why="$4"
  _rot="${_rs_f}.$(date +%Y%m%d%H%M%S).old"
  mv "$_rs_f" "$_rot" 2>/dev/null
  printf '%s\t%s\n' "$_rs_tag" "$_rs_paths" > "$_rs_f"
  ROTATED="$_rot"
  logger -t temp-history -p daemon.warning \
    "$_rs_why — previous data kept as $_rot, started a fresh series"
}

# ── flush_one <buffer> <destination> <has_header> ─────────────────────────
# Echoes the number of rows committed. Renames the buffer aside before
# reading it so the collector can never lose an append to the truncate.
flush_one() {
  _fb="$1"; _fd="$2"; _fh="$3"; _fp="${1}.flushing"
  _fn=0

  # Recover a .flushing file left behind by an interrupted previous run
  # before creating a new one, otherwise the mv below would discard it.
  if [ -s "$_fp" ]; then
    cat "$_fp" >> "$_fd" && : > "$_fp"
  fi

  if [ -s "$_fb" ]; then
    mv "$_fb" "$_fp" 2>/dev/null || { printf '0'; return; }
    set -- $(wc -l < "$_fp" 2>/dev/null)
    _fn=${1:-0}
    cat "$_fp" >> "$_fd"
  fi
  rm -f "$_fp"

  if [ -s "$_fd" ]; then
    set -- $(wc -l < "$_fd" 2>/dev/null)
    _total=${1:-0}
    _data=$_total
    [ "$_fh" = "1" ] && _data=$(( _total - 1 ))
    if [ "$_data" -gt "$MAX_ROWS" ]; then
      if [ "$_fh" = "1" ]; then
        # Keep the schema header; trim only the data rows beneath it.
        {
          head -n 1 "$_fd"
          tail -n +2 "$_fd" | tail -n "$MAX_ROWS"
        } > "${_fd}.tmp" && mv "${_fd}.tmp" "$_fd"
      else
        tail -n "$MAX_ROWS" "$_fd" > "${_fd}.tmp" && mv "${_fd}.tmp" "$_fd"
      fi
    fi
  fi

  printf '%s' "$_fn"
}

prepare_series "$HISTORY_FILE" "$TEMP_TAG" "$TEMP_PATHS" "$TEMP_COUNT" "sensors"
[ "$FAN_COUNT" -gt 0 ] && \
  prepare_series "$FAN_FILE" "$FAN_TAG" "$FAN_PATHS" "$FAN_COUNT" "fans"

FLUSHED_TEMP=$(flush_one "$BUF_FILE" "$HISTORY_FILE" 1)
FLUSHED_UPTIME=$(flush_one "$UPTIME_BUF" "$UPTIME_FILE" 0)
FLUSHED_SYS=$(flush_one "$SYS_BUF" "$SYS_FILE" 0)
# Only touches flash when there is actually something to write, so a fanless
# router never creates fan-history.tsv at all.
if [ -s "$FAN_BUF" ] || [ -s "$FAN_FILE" ]; then
  FLUSHED_FAN=$(flush_one "$FAN_BUF" "$FAN_FILE" 1)
fi

# ── Daily rollup ────────────────────────────────────────────────────
# max_rows caps the 15-minute series at 30 days, so everything older is gone
# for good — which makes the one question this data is really good for
# unanswerable: is this router running hotter than it did six months ago?
#
# One row per sensor per day, min/max/mean, appended to a file that is NEVER
# trimmed. Five sensors is ~1800 rows a year, tens of kilobytes.
#
# Long format (day, sensor index, name, min, max, mean) rather than a wide
# row per day, because the sensor set can change: a wide layout would need
# the same rotate-on-change machinery as the main series, and a changed
# sensor set would orphan every historical column. In long format a new
# sensor is simply new rows.
#
# TODAY IS DELIBERATELY EXCLUDED. Its average is not yet an average of
# anything, and rewriting the same day's row on every manual flush would be a
# flash write per flush for a number that keeps changing.
roll_daily() {
  [ -s "$HISTORY_FILE" ] || return 0

  _rd_tmp="$DATA_DIR/temp-daily.tsv.tmp"
  _rd_today=$(date '+%Y-%m-%d')

  # One awk pass over the history and the existing rollup. Days already
  # recorded are kept as they are: history rows for them may since have been
  # trimmed away, so recomputing would silently narrow their range.
  awk -F'\t' -v names="$TEMP_NAMES" -v today="$_rd_today" \
      -v daily="$DAILY_FILE" 'BEGIN {
    nn = split(names, nm, "\t")
    while ((getline line < daily) > 0) {
      if (substr(line, 1, 1) == "#") { hdr = line; continue }
      split(line, f, "\t")
      seen[f[1] "\t" f[2]] = 1
      keep[++nk] = line
    }
    close(daily)
  }
  /^#/ { next }
  {
    day = strftime("%Y-%m-%d", $1 + 0)
    if (day == today) next
    for (i = 2; i <= NF; i++) {
      si = i - 1
      v = $i + 0
      if (v <= 0) continue           # 0.0 means unreadable, not cold
      k = day "\t" si
      if (!(k in cnt) || v < mn[k]) mn[k] = v
      if (!(k in cnt) || v > mx[k]) mx[k] = v
      sum[k] += v; cnt[k]++
    }
  }
  END {
    out = ""
    for (k in cnt) {
      if (k in seen) continue        # already recorded; never rewritten
      split(k, kf, "\t")
      out = out sprintf("%s\t%s\t%s\t%.1f\t%.1f\t%.1f\n",
                        kf[1], kf[2], (kf[2]+0 <= nn ? nm[kf[2]+0] : "sensor " kf[2]),
                        mn[k], mx[k], sum[k]/cnt[k])
      n_new++
    }
    if (n_new == 0) { print "NONE"; exit }
    print "#tdh1\tday\tsensor\tname\tmin\tmax\tmean"
    for (i = 1; i <= nk; i++) print keep[i]
    printf "%s", out
  }' "$HISTORY_FILE" > "$_rd_tmp" 2>/dev/null

  if [ ! -s "$_rd_tmp" ]; then
    rm -f "$_rd_tmp"; return 0
  fi
  if [ "$(head -n 1 "$_rd_tmp")" = "NONE" ]; then
    rm -f "$_rd_tmp"; return 0
  fi

  # Sort by day then sensor so the file stays readable by eye and by awk.
  # BusyBox sort supports -k with -t; if it ever fails, keep the unsorted
  # file rather than losing the rollup.
  if sort -t"$TAB" -k1,1 -k2,2n "$_rd_tmp" -o "$_rd_tmp.s" 2>/dev/null; then
    { printf '#tdh1\tday\tsensor\tname\tmin\tmax\tmean\n'
      grep -v '^#' "$_rd_tmp.s"; } > "$_rd_tmp"
    rm -f "$_rd_tmp.s"
  fi

  mv "$_rd_tmp" "$DAILY_FILE"
  DAILY_ROWS=$(grep -vc '^#' "$DAILY_FILE" 2>/dev/null)
  case "$DAILY_ROWS" in ''|*[!0-9]*) DAILY_ROWS=0 ;; esac
}

DAILY_ROWS=0
roll_daily

case "$FLUSHED_TEMP"   in ''|*[!0-9]*) FLUSHED_TEMP=0   ;; esac
case "$FLUSHED_UPTIME" in ''|*[!0-9]*) FLUSHED_UPTIME=0 ;; esac
case "$FLUSHED_FAN"    in ''|*[!0-9]*) FLUSHED_FAN=0    ;; esac
case "$FLUSHED_SYS"    in ''|*[!0-9]*) FLUSHED_SYS=0    ;; esac

if [ -n "$ROTATED" ]; then
  printf '{"status":"ok","flushed_temp":%d,"flushed_uptime":%d,"flushed_fan":%d,"flushed_sys":%d,"daily_rows":%d,"rotated":"%s"}\n' \
    "$FLUSHED_TEMP" "$FLUSHED_UPTIME" "$FLUSHED_FAN" "$FLUSHED_SYS" "$DAILY_ROWS" "$ROTATED"
else
  printf '{"status":"ok","flushed_temp":%d,"flushed_uptime":%d,"flushed_fan":%d,"flushed_sys":%d,"daily_rows":%d}\n' \
    "$FLUSHED_TEMP" "$FLUSHED_UPTIME" "$FLUSHED_FAN" "$FLUSHED_SYS" "$DAILY_ROWS"
fi
