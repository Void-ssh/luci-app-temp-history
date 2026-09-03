#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# collect-temp-history.sh
# Collects temperature and fan readings every 15 minutes.
#
# Data goes to a RAM buffer in /tmp; a nightly cron job (or a manual flush
# from the UI) commits it to /root/website. That is one flash write a day
# instead of ninety-six.
#
# DESIGN NOTES
#
#   • Discovery runs once and writes a stable column map. It is deliberately
#     NOT re-run automatically: a new map can have a different column count,
#     which would silently misalign every historical row. Delete the map to
#     rebuild it.
#
#   • Fan RPM is collected in this same pass — no extra cron entry, no extra
#     flash writes. Discovery pairs each hwmon tachometer (fanN_input) with
#     the pwmN of the same index in the same hwmon, and also records PWM
#     nodes with no tachometer. Writability of the pwm node is what decides
#     whether control is possible, probed once at discovery.
#
#   • -1 is the "no reading" sentinel for RPM, NOT 0. Unlike a temperature, a
#     fan reporting 0 RPM is a real and important measurement: it has
#     stopped. That distinction is carried all the way to the chart.
#
#   • Passively cooled hardware costs nothing: discovery writes an empty map
#     once and every later run short-circuits on a single [ -s ] test.
#
#   • The buffer is capped hourly (temp_history.main.max_rows) so a broken
#     flush cron cannot grow /tmp without bound. UCI is read only in that
#     hourly branch — the 15-minute path is fork-sensitive.
#
#   • Sensor names are trimmed of trailing whitespace only. `${v%%[[:space:]]*}`
#     looks like a newline strip but turns "CPU Package" into "CPU" on any
#     driver exposing a multi-word tempN_label.
#
#   • Every sensor reading zero is what a stale map looks like after hwmon
#     renumbering, so it warns to syslog (at most hourly) rather than
#     silently recording nothing.
#
# REDIRECTION ORDER MATTERS, and it is not obvious:
#   `read -r x < "$f" 2>/dev/null` does NOT silence a failed open. Shell
#   redirections are applied left to right, so `< "$f"` fails and prints
#   "can't open ...: no such file" to the still-live stderr before
#   2>/dev/null takes effect. The stderr redirect must come FIRST:
#     read -r x 2>/dev/null < "$f"
#   Verified against BusyBox ash, dash and bash.

DATA_DIR="/root/website"
SENSOR_MAP="$DATA_DIR/temp-sensors.conf"
FAN_MAP="$DATA_DIR/fan-sensors.conf"

# RAM buffers — written every 15 min; zero flash wear
BUF_FILE="/tmp/temp-history-buf.log"
UPTIME_BUF="/tmp/uptime-history-buf.log"
FAN_BUF="/tmp/fan-history-buf.log"
SYS_BUF="/tmp/sys-history-buf.log"
CPU_STATE="/tmp/temp-history-cpu.state"    # previous /proc/stat totals

WARN_STAMP="/tmp/temp-history-zero.warn"

# Watchdog state. Both live in /tmp: they describe the CURRENT state, and a
# reboot legitimately clears them.
LEVEL_STATE="/tmp/temp-history-levels.state"   # per-sensor ok/warn/crit
STALL_STATE="/tmp/temp-history-fan.stall"      # fans commanded on but not turning

# A fan is only judged stalled when it is being driven hard enough that it
# certainly ought to be turning. Below roughly a quarter duty many fans
# legitimately fail to start, and reporting that as a fault would train the
# operator to ignore the warning — which is worse than not having it.
STALL_PWM_MIN=64        # of 255, ≈25%
STALL_SAMPLES=2         # consecutive 15-min samples before it is a fault

DEFAULT_WARN=65
DEFAULT_CRIT=80

# Buffer cap, matching the flush script's retention. Read from UCI only in the
# hourly housekeeping branch below — the collector runs every 15 minutes and
# this would otherwise be a fork three times an hour for a value that almost
# never changes.
DEFAULT_MAX_ROWS=2880   # 30 days × 24 h × 4 per hour

mkdir -p "$DATA_DIR"

# One date fork gives both the timestamp and the minute-of-hour used to
# schedule the once-an-hour housekeeping checks below.
set -- $(date '+%s %M')
TS="$1"
MINUTE="$2"
HOURLY=0
[ "$MINUTE" = "00" ] && HOURLY=1

# Trailing-whitespace trim that preserves internal spaces.
# "CPU Package \n" → "CPU Package"   (the old %%[[:space:]]* gave "CPU")
trim_trailing() {
  _tt_v="$1"
  _tt_v="${_tt_v%"${_tt_v##*[![:space:]]}"}"
  printf '%s' "$_tt_v"
}

# ── Sensor discovery (runs once, creates stable column map) ───────────────
if [ ! -f "$SENSOR_MAP" ]; then
  TMP_MAP="${SENSOR_MAP}.tmp"
  : > "$TMP_MAP"
  SEEN_DEVS=""

  for hwmon in /sys/class/hwmon/hwmon*; do
    [ -d "$hwmon" ] || continue
    # Clear first: when the redirection fails, `read` never executes and the
    # variable keeps whatever the PREVIOUS iteration left in it. That is how a
    # sensor with no tempN_label ended up inheriting the label of the sensor
    # discovered before it — invisible on hardware where no sensor has a label
    # (all empty), wrong on any mixed set.
    hw_name=""
    read -r hw_name 2>/dev/null < "$hwmon/name"
    hw_name=$(trim_trailing "$hw_name")
    [ -z "$hw_name" ] && hw_name="${hwmon##*/}"

    dev_link=$(readlink -f "$hwmon/device" 2>/dev/null)
    [ -n "$dev_link" ] && SEEN_DEVS="$SEEN_DEVS $dev_link"

    for temp_input in "$hwmon"/temp*_input; do
      [ -f "$temp_input" ] || continue
      base="${temp_input%_input}"
      label=""
      read -r label 2>/dev/null < "${base}_label"
      label=$(trim_trailing "$label")
      if [ -n "$label" ]; then
        name="$hw_name / $label"
      else
        name="$hw_name"
      fi
      printf '%s\t%s\n' "$temp_input" "$name" >> "$TMP_MAP"
    done
  done

  # thermal_zone — skip devices already covered by hwmon
  for tz in /sys/class/thermal/thermal_zone*; do
    [ -d "$tz" ] || continue
    tz_dev=$(readlink -f "$tz" 2>/dev/null)
    skip=0
    for seen in $SEEN_DEVS; do
      [ "$tz_dev" = "$seen" ] && skip=1 && break
    done
    [ "$skip" = "1" ] && continue
    [ -f "$tz/temp" ] || continue
    tz_type=""
    read -r tz_type 2>/dev/null < "$tz/type"
    tz_type=$(trim_trailing "$tz_type")
    name="${tz_type:-${tz##*/}}"
    printf '%s\t%s\n' "$tz/temp" "$name" >> "$TMP_MAP"
  done

  mv "$TMP_MAP" "$SENSOR_MAP"
fi

# ── Fan discovery (runs once) ─────────────────────────────────────────────
# Written even when nothing is found, so passively cooled hardware pays the
# scan exactly once and then short-circuits forever after.
# Format, tab separated:  tach_path <TAB> name <TAB> pwm_path <TAB> pwm_enable
# "-" means absent. A fan can have a tachometer with no PWM (monitor only), or
# PWM with no tachometer (control blind), or both.
if [ ! -f "$FAN_MAP" ]; then
  TMP_FAN="${FAN_MAP}.tmp"
  {
    printf '# tach_path\tname\tpwm_path\tpwm_enable_path   ("-" = absent)\n'
    printf '# regenerate by deleting this file; the collector rebuilds it\n'
  } > "$TMP_FAN"

  for hwmon in /sys/class/hwmon/hwmon*; do
    [ -d "$hwmon" ] || continue
    fan_hw=""
    read -r fan_hw 2>/dev/null < "$hwmon/name"
    fan_hw=$(trim_trailing "$fan_hw")
    [ -z "$fan_hw" ] && fan_hw="${hwmon##*/}"
    SEEN_PWM=""

    for tach in "$hwmon"/fan*_input; do
      [ -f "$tach" ] || continue
      fbase="${tach%_input}"
      fidx="${fbase##*/fan}"
      flabel=""
      read -r flabel 2>/dev/null < "${fbase}_label"
      flabel=$(trim_trailing "$flabel")
      fname="$fan_hw"
      [ -n "$flabel" ] && fname="$fan_hw / $flabel"

      fpwm="$hwmon/pwm$fidx"
      fpwme="$hwmon/pwm${fidx}_enable"
      # Writability is the real test: a read-only sysfs attribute is mode 444.
      [ -w "$fpwm" ]  || fpwm="-"
      [ -w "$fpwme" ] || fpwme="-"
      [ "$fpwm" != "-" ] && SEEN_PWM="$SEEN_PWM $fpwm"

      printf '%s\t%s\t%s\t%s\n' "$tach" "$fname" "$fpwm" "$fpwme" >> "$TMP_FAN"
    done

    # A PWM node with no matching tachometer still gives control, just no
    # feedback. Worth recording so the UI can offer it.
    for fpwm in "$hwmon"/pwm[0-9]; do
      [ -w "$fpwm" ] || continue
      case " $SEEN_PWM " in *" $fpwm "*) continue ;; esac
      fidx="${fpwm##*/pwm}"
      fpwme="${fpwm}_enable"
      [ -w "$fpwme" ] || fpwme="-"
      printf '%s\t%s\t%s\t%s\n' "-" "$fan_hw / pwm$fidx" "$fpwm" "$fpwme" >> "$TMP_FAN"
    done
  done

  mv "$TMP_FAN" "$FAN_MAP"
fi

# ── Read current temperatures ──────────────────────────────────────────────
# Accumulate raw millidegree integers in a space-separated string; a single
# awk call at the end converts all of them to °C — N awk forks → 1 per run.
TAB="	"  # literal tab — avoids $(printf '\t') subshell each iteration
RAWS=""
SEP=""
NONZERO=0
NAMES=""
NSEP=""

while IFS="$TAB" read -r path _name; do
  [ -z "$path" ] && continue
  case "$path" in '#'*) continue ;; esac
  # Names are carried along for the threshold log lines: "45.2 °C" tells you
  # nothing without knowing which sensor it was.
  NAMES="${NAMES}${NSEP}${_name}"
  NSEP="$TAB"
  if read -r raw 2>/dev/null < "$path"; then
    raw="${raw%%[[:space:]]*}"
  else
    raw=""
  fi
  # Validate as a non-negative integer; default to 0 if unreadable or invalid
  case "$raw" in
    ''|*[!0-9]*) raw=0 ;;
    *) [ "$raw" != "0" ] && NONZERO=1 ;;
  esac
  RAWS="${RAWS}${SEP}${raw}"
  SEP=" "
done < "$SENSOR_MAP"

[ -z "$RAWS" ] && exit 0

# Every sensor unreadable usually means the map is stale — hwmon devices get
# renumbered across kernel upgrades. Deliberately NOT auto-regenerated: a new
# map can have a different column count, which would silently misalign every
# historical row. Warn instead, at most once an hour, and let the operator
# delete temp-sensors.conf when they are ready to start a fresh series.
if [ "$NONZERO" = "0" ]; then
  if [ "$HOURLY" = "1" ] || [ ! -f "$WARN_STAMP" ]; then
    logger -t temp-history -p daemon.warning \
      "all sensors read 0 — $SENSOR_MAP may be stale (hwmon renumbering?)"
    : > "$WARN_STAMP"
  fi
elif [ -f "$WARN_STAMP" ]; then
  rm -f "$WARN_STAMP"
fi

# Single awk pass: millidegrees → °C, AND threshold-crossing detection.
#
# warn/crit as colours on a page are no use at 3am, so a crossing is also a
# syslog line — a thermal event leaves a trace that outlives the browser tab.
# Only TRANSITIONS are logged — ok→warn,
# warn→crit, and every recovery — so a router sitting above warn for a week
# produces one line, not 672.
#
# Doing it inside the existing conversion awk keeps the whole thing at one
# fork: awk reads the previous levels itself and rewrites them itself.
WARN_T=$(uci -q get temp_history.main.warn_temp 2>/dev/null)
CRIT_T=$(uci -q get temp_history.main.crit_temp 2>/dev/null)
case "$WARN_T" in ''|*[!0-9]*) WARN_T="$DEFAULT_WARN" ;; esac
case "$CRIT_T" in ''|*[!0-9]*) CRIT_T="$DEFAULT_CRIT" ;; esac

AWK_OUT=$(awk -v raws="$RAWS" -v names="$NAMES" -v warn="$WARN_T" -v crit="$CRIT_T" \
              -v state="$LEVEL_STATE" 'BEGIN {
  FS = "\t"
  n  = split(raws, a, " ")
  split(names, nm, "\t")

  while ((getline line < state) > 0) {
    split(line, p, "\t")
    prev[p[1]+0] = p[2]
  }
  close(state)

  vals = ""
  for (i = 1; i <= n; i++) {
    c = a[i] / 1000
    # The separator MUST be hoisted: written inline as `vals (...)`, BusyBox
    # 1.33 parses it as a call to a user function named vals and aborts the
    # whole program — which here would mean no temperatures collected at all.
    vsep = (i > 1) ? "\t" : ""
    vals = vals vsep sprintf("%.1f", c)

    was = (i in prev) ? prev[i] : "ok"
    # 0 means the sensor could not be read, not that it is cold. Carry the
    # previous level rather than reporting a recovery that did not happen.
    if (a[i] == 0)      lvl = was
    else if (c >= crit) lvl = "crit"
    else if (c >= warn) lvl = "warn"
    else                lvl = "ok"

    if (lvl != was)
      printf "LOG\t%s\t%s\t%s\t%.1f\n", lvl, was, nm[i], c

    printf "%d\t%s\n", i, lvl > state
  }
  printf "VALS\t%s\n", vals
}')

# Read the awk output back in the CURRENT shell. A `printf | while` pipeline
# would put the loop in a subshell, where every assignment it makes is
# discarded — VALS would come back empty and no row would ever be written.
# A here-document keeps it here, and costs no fork.
VALS=""
while IFS="$TAB" read -r _tag _rest; do
  case "$_tag" in
    VALS) VALS="$_rest" ;;
    LOG)
      _lvl="${_rest%%"$TAB"*}";  _r="${_rest#*"$TAB"}"
      _was="${_r%%"$TAB"*}";     _r="${_r#*"$TAB"}"
      _sname="${_r%%"$TAB"*}";   _stemp="${_r#*"$TAB"}"
      # crit is an error, warn and every recovery a notice, so `logread` can
      # be filtered down to the events that actually matter.
      if [ "$_lvl" = "crit" ]; then
        logger -t temp-history -p daemon.err \
          "$_sname reached ${_stemp}°C — at or above crit (${CRIT_T}°C)"
      elif [ "$_lvl" = "warn" ] && [ "$_was" = "ok" ]; then
        logger -t temp-history -p daemon.notice \
          "$_sname reached ${_stemp}°C — at or above warn (${WARN_T}°C)"
      else
        logger -t temp-history -p daemon.notice \
          "$_sname is ${_stemp}°C — ${_was} → ${_lvl}"
      fi
      ;;
  esac
done <<AWK_EOF
$AWK_OUT
AWK_EOF

# ── Read uptime (zero forks: shell built-in + string trimming) ────────────
# /proc/uptime format: "12345.67 23456.78"  →  integer seconds = "12345"
if read -r _uptime_raw _ 2>/dev/null < /proc/uptime; then
  UPTIME_SECS="${_uptime_raw%%.*}"
else
  UPTIME_SECS=0
fi
case "$UPTIME_SECS" in ''|*[!0-9]*) UPTIME_SECS=0 ;; esac

# ── Read fan tachometers ──────────────────────────────────────────────────
# On passively cooled hardware the map holds only its two comment lines, so
# this loop finds nothing, FAN_VALS stays empty, and no row is written.
FAN_VALS=""
STALL_NEW=""          # fans currently counting toward a stall
STALL_LOG=""          # transitions to announce, once the loop is done
if [ -s "$FAN_MAP" ]; then
  FSEP=""

  # Previous stall counters, read once. Format: name <TAB> count <TAB> since
  STALL_PREV=""
  if [ -f "$STALL_STATE" ]; then
    while IFS="$TAB" read -r _sn _sc _ss _sv; do
      [ -n "$_sn" ] || continue
      STALL_PREV="${STALL_PREV}${_sn}=${_sc}=${_ss}
"
    done < "$STALL_STATE"
  fi

  while IFS="$TAB" read -r ftach fname fpwm fpwme; do
    case "$ftach" in ''|'#'*) continue ;; esac
    if [ "$ftach" = "-" ]; then
      frpm=-1                       # PWM-only fan: nothing to measure
    elif read -r frpm 2>/dev/null < "$ftach"; then
      frpm="${frpm%%[[:space:]]*}"
    else
      frpm=""
    fi
    # -1 means "no reading". 0 is a real measurement: the fan has stopped.
    case "$frpm" in
      ''|*[!0-9]*) [ "$frpm" = "-1" ] || frpm=-1 ;;
    esac
    FAN_VALS="${FAN_VALS}${FSEP}${frpm}"
    FSEP="$TAB"

    # ── Stall watchdog ──────────────────────────────────────────────
    # A fan being driven hard that reports no rotation is blocked, seized, or
    # unplugged. Nothing else in this package would ever notice: the chart
    # would simply show a flat line at zero, which is also what a healthy idle
    # fan looks like. The difference is whether it was told to spin.
    [ "$ftach" = "-" ] && continue          # no tachometer: nothing to judge
    [ "$fpwm" = "-" ]  && continue          # no pwm: never commanded by us
    read -r _fpwmv 2>/dev/null < "$fpwm" || _fpwmv=""
    case "$_fpwmv" in ''|*[!0-9]*) continue ;; esac

    _prevc=0; _prevs=0
    case "$STALL_PREV" in
      *"${fname}="*)
        _p="${STALL_PREV#*${fname}=}"; _p="${_p%%
*}"
        _prevc="${_p%%=*}"; _prevs="${_p#*=}"
        ;;
    esac
    case "$_prevc" in ''|*[!0-9]*) _prevc=0 ;; esac
    case "$_prevs" in ''|*[!0-9]*) _prevs=0 ;; esac

    if [ "$_fpwmv" -ge "$STALL_PWM_MIN" ] && [ "$frpm" = "0" ]; then
      _c=$(( _prevc + 1 ))
      [ "$_prevs" = "0" ] && _prevs="$TS"
      # The fourth field is the verdict, so the CGI does not have to know
      # STALL_SAMPLES: one definition of "stalled", here, where it is decided.
      if [ "$_c" -ge "$STALL_SAMPLES" ]; then _st="stalled"; else _st="counting"; fi
      STALL_NEW="${STALL_NEW}${fname}${TAB}${_c}${TAB}${_prevs}${TAB}${_st}
"
      [ "$_c" = "$STALL_SAMPLES" ] && \
        STALL_LOG="${STALL_LOG}stall${TAB}${fname}${TAB}${_fpwmv}
"
    elif [ "$_prevc" -ge "$STALL_SAMPLES" ]; then
      STALL_LOG="${STALL_LOG}clear${TAB}${fname}${TAB}${frpm}
"
    fi
  done < "$FAN_MAP"

  # Rewrite the state, then announce. Announcing first would risk logging a
  # stall whose counter never got persisted, and repeating it every run.
  if [ -n "$STALL_NEW" ]; then
    printf '%s' "$STALL_NEW" > "$STALL_STATE"
  else
    rm -f "$STALL_STATE"
  fi

  while IFS="$TAB" read -r _ev _n _v; do
    [ -n "$_ev" ] || continue
    if [ "$_ev" = "stall" ]; then
      logger -t temp-history -p daemon.err \
        "fan $_n is being driven at pwm $_v but reports 0 rpm — blocked, seized or unplugged"
    else
      logger -t temp-history -p daemon.notice "fan $_n is turning again ($_v rpm)"
    fi
  done <<STALL_EOF
$STALL_LOG
STALL_EOF
fi

# ── CPU and memory ────────────────────────────────────────────────────────
# So that "it was hot" can be told apart from "it was hot AND working".
#
# CPU is a DELTA, not a reading. /proc/stat counts jiffies since boot, so the
# only meaningful number is how many of them were busy since the previous
# sample — the average utilisation across the whole interval. That is exactly
# the window the temperature beside it was measured in, which is the entire
# point of plotting them together. It also means brief spikes are averaged
# away: a 15-minute mean of 4% can contain one very busy minute.
#
# THE BASELINE LIVES IN /tmp ON PURPOSE. The counters reset at boot and so does
# /tmp, so a reboot cannot produce a delta against a pre-reboot baseline — that
# would be a large negative number or a nonsense spike right where someone is
# most likely to be looking. The cost is that the first sample after a reboot
# has nothing to subtract from and records -1; the next one, 15 minutes later,
# is the first real reading.
#
# -1 is the sentinel for "not available", the same convention the fan series
# uses. 0 is a real value: an idle router.
CPU_PCT="-1"
if [ -r /proc/stat ]; then
  _cpu_l=""
  read -r _cpu_l 2>/dev/null < /proc/stat
  case "$_cpu_l" in
    cpu\ *)
      # shellcheck disable=SC2086
      set -- $_cpu_l
      shift                       # drop the "cpu" label
      _tot=0; _idle=0; _i=0
      for _f in "$@"; do
        case "$_f" in ''|*[!0-9]*) continue ;; esac
        _tot=$(( _tot + _f ))
        # user nice system idle iowait irq softirq steal ...
        # Fields 3 and 4 (0-based) are idle and iowait. Both count as not
        # busy: a router blocked on flash is waiting, not working.
        [ "$_i" = 3 ] && _idle=$(( _idle + _f ))
        [ "$_i" = 4 ] && _idle=$(( _idle + _f ))
        _i=$(( _i + 1 ))
      done

      _ptot=0; _pidle=0
      [ -r "$CPU_STATE" ] && read -r _ptot _pidle 2>/dev/null < "$CPU_STATE"
      case "$_ptot"  in ''|*[!0-9]*) _ptot=0 ;; esac
      case "$_pidle" in ''|*[!0-9]*) _pidle=0 ;; esac
      printf '%s %s\n' "$_tot" "$_idle" > "$CPU_STATE"

      _dt=$(( _tot - _ptot ))
      _di=$(( _idle - _pidle ))
      if [ "$_ptot" -gt 0 ] && [ "$_dt" -gt 0 ] && [ "$_di" -ge 0 ]; then
        _busy=$(( _dt - _di ))
        [ "$_busy" -lt 0 ] && _busy=0
        _t10=$(( ( _busy * 1000 + _dt / 2 ) / _dt ))
        [ "$_t10" -gt 1000 ] && _t10=1000
        CPU_PCT=$(printf '%d.%d' "$(( _t10 / 10 ))" "$(( _t10 % 10 ))")
      fi
      ;;
  esac
fi

# Two memory figures, because on Linux they answer different questions and
# neither alone is honest. Excluding cache (MemTotal-MemAvailable) is what
# "memory pressure" actually means. Including cache (MemTotal-MemFree) is what
# most tools show and sits near full almost always, because a kernel with
# spare RAM caches with it — useful only next to the other line.
MEM_PCT="-1"
MEM_PCT_C="-1"
if [ -r /proc/meminfo ]; then
  _mt=0; _mf=0; _ma=0; _mb=0; _mc=0
  while read -r _k _v _rest; do
    case "$_k" in
      MemTotal:)     _mt="$_v" ;;
      MemFree:)      _mf="$_v" ;;
      MemAvailable:) _ma="$_v" ;;
      Buffers:)      _mb="$_v" ;;
      Cached:)       _mc="$_v" ;;   # SwapCached: is a different key, not matched
    esac
  done < /proc/meminfo
  case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
  case "$_mf" in ''|*[!0-9]*) _mf=0 ;; esac
  case "$_ma" in ''|*[!0-9]*) _ma=0 ;; esac
  # MemAvailable arrived in Linux 3.14. Older kernels get the approximation
  # everything used before it existed.
  [ "$_ma" = 0 ] && _ma=$(( _mf + _mb + _mc ))
  if [ "$_mt" -gt 0 ]; then
    [ "$_ma" -gt "$_mt" ] && _ma="$_mt"
    _u10=$(( ( ( _mt - _ma ) * 1000 + _mt / 2 ) / _mt ))
    MEM_PCT=$(printf '%d.%d' "$(( _u10 / 10 ))" "$(( _u10 % 10 ))")
    _c10=$(( ( ( _mt - _mf ) * 1000 + _mt / 2 ) / _mt ))
    MEM_PCT_C=$(printf '%d.%d' "$(( _c10 / 10 ))" "$(( _c10 % 10 ))")
  fi
fi

# ── Append to RAM buffers (no flash write) ────────────────────────────────
printf '%s\t%s\n' "$TS" "$VALS"        >> "$BUF_FILE"
printf '%s\t%s\n' "$TS" "$UPTIME_SECS" >> "$UPTIME_BUF"
[ -n "$FAN_VALS" ] && printf '%s\t%s\n' "$TS" "$FAN_VALS" >> "$FAN_BUF"
printf '%s\t%s\t%s\t%s\n' "$TS" "$CPU_PCT" "$MEM_PCT" "$MEM_PCT_C" >> "$SYS_BUF"

# ── Backstop for an expired manual fan override ───────────────────────────
# The guard process started by fan-control.sh is what normally enforces the
# timeout. This catches the case where it was killed (OOM, a stray kill -9)
# and the fan would otherwise be stuck at a manual speed indefinitely.
[ -x /usr/libexec/temp-history/fan-control.sh ] && \
  /usr/libexec/temp-history/fan-control.sh enforce >/dev/null 2>&1

# ── Hourly housekeeping: keep the RAM buffer bounded ──────────────────────
# If the nightly flush cron is missing or failing, these files would otherwise
# grow forever in RAM. Trimming to MAX_ROWS loses nothing the flash file could
# have kept anyway — it caps at the same number.
if [ "$HOURLY" = "1" ]; then
  MAX_ROWS=$(uci -q get temp_history.main.max_rows 2>/dev/null)
  case "$MAX_ROWS" in ''|*[!0-9]*) MAX_ROWS=$DEFAULT_MAX_ROWS ;; esac
  [ "$MAX_ROWS" -lt 10 ] && MAX_ROWS=10

  for _bf in "$BUF_FILE" "$UPTIME_BUF" "$FAN_BUF" "$SYS_BUF"; do
    [ -s "$_bf" ] || continue
    set -- $(wc -l < "$_bf" 2>/dev/null)
    if [ "${1:-0}" -gt "$MAX_ROWS" ]; then
      tail -n "$MAX_ROWS" "$_bf" > "${_bf}.trim" && mv "${_bf}.trim" "$_bf"
      logger -t temp-history -p daemon.warning \
        "RAM buffer $_bf exceeded $MAX_ROWS rows — is the nightly flush running?"
    fi
  done
fi

exit 0
