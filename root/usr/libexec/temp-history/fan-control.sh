#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Void
# fan-control.sh
# Manual fan speed override with an automatic hand-back to the kernel.
#
# NOT web-reachable. Reached from the UI through ubus (luci.temp-status.setFan
# / luci.temp-history.setFan), which LuCI authenticates. Also usable directly
# over SSH.
#
#   fan-control.sh status              JSON: fans, current pwm, mode, expiry
#   fan-control.sh set <pct> [mins]    take manual control at <pct> speed
#   fan-control.sh auto                give control back to the kernel now
#   fan-control.sh enforce             backstop check (called by the collector)
#   fan-control.sh guard <epoch>       internal: the timeout/failsafe loop
#
# ── Why the failsafe is not optional ──────────────────────────────────────
# Taking manual control means writing pwmN_enable=1, which switches the fan
# OUT of the kernel thermal governor's hands. While we hold it, nothing else
# is regulating cooling — so this script gives it back on all of:
#
#   • the override expiring (default 30 minutes),
#   • any sensor exceeding crit_temp,
#   • the guard process exiting for any reason (trap),
#   • a reboot (pwmN_enable resets to the driver default and /tmp clears),
#   • the 15-minute collector noticing an expired override whose guard died.
#
# A minimum speed floor (fan_min_percent) stops the UI being used to stall the
# fan entirely. Setting 0% is possible only by editing UCI deliberately.

DATA_DIR="/root/website"
SENSOR_MAP="$DATA_DIR/temp-sensors.conf"
FAN_MAP="$DATA_DIR/fan-sensors.conf"

STATE="/tmp/temp-history-fan.state"     # expiry + requested percent
SAVED="/tmp/temp-history-fan.saved"     # original pwm_enable values
GUARD_PID="/tmp/temp-history-fan.pid"

PWM_MAX=255
PROC_DIR="/proc"
TAB="	"

DEFAULT_MIN_PCT=25
DEFAULT_MINUTES=30
DEFAULT_CRIT=80

uci_num() {  # uci_num <option> <default>
  _un=$(uci -q get "temp_history.main.$1" 2>/dev/null)
  case "$_un" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$_un" ;; esac
}

control_enabled() {
  case "$(uci -q get temp_history.main.fan_control 2>/dev/null)" in
    0) return 1 ;;
    *) return 0 ;;
  esac
}

now() { date +%s; }

# kill -0 is not a liveness test: it succeeds for a zombie and for a reused
# pid belonging to something else entirely. Confirm the process really is one
# of our guards by looking at its command line.
guard_alive() {  # guard_alive <pid>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q 'fan-control\.sh' && return 0
    return 1
  fi
  kill -0 "$1" 2>/dev/null
}

guard_pid() {
  _gpv=""
  [ -s "$GUARD_PID" ] && read -r _gpv 2>/dev/null < "$GUARD_PID"
  case "$_gpv" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$_gpv" ;; esac
}

state_field() {  # state_field <key>
  [ -f "$STATE" ] || return 1
  _sfv=""
  while IFS='=' read -r _sfk _sfval; do
    [ "$_sfk" = "$1" ] && _sfv="$_sfval"
  done < "$STATE"
  [ -n "$_sfv" ] || return 1
  printf '%s' "$_sfv"
}

# ── Fan map helpers ───────────────────────────────────────────────────────
# Emits: tach<TAB>name<TAB>pwm<TAB>pwm_enable   for each real entry
fan_rows() {
  [ -f "$FAN_MAP" ] || return 0
  while IFS="$TAB" read -r t n p e; do
    case "$t" in ''|'#'*) continue ;; esac
    printf '%s\t%s\t%s\t%s\n' "$t" "$n" "${p:--}" "${e:--}"
  done < "$FAN_MAP"
}

controllable_count() {
  fan_rows | awk -F'\t' '$3!="-"{n++} END{print n+0}'
}

read_file() {  # read_file <path> -> value or empty
  _rfv=""
  [ -n "$1" ] && [ "$1" != "-" ] && read -r _rfv 2>/dev/null < "$1"
  printf '%s' "${_rfv%%[[:space:]]*}"
}

# ── Crit failsafe ─────────────────────────────────────────────────────────
# True when any temperature sensor is at or above crit_temp.
any_sensor_critical() {
  _crit=$(uci_num crit_temp "$DEFAULT_CRIT")
  _critm=$(( _crit * 1000 ))
  [ -f "$SENSOR_MAP" ] || return 1
  while IFS="$TAB" read -r _p _n; do
    case "$_p" in ''|'#'*) continue ;; esac
    _v=""
    read -r _v 2>/dev/null < "$_p" || continue
    _v="${_v%%[[:space:]]*}"
    case "$_v" in ''|*[!0-9]*) continue ;; esac
    [ "$_v" -ge "$_critm" ] && return 0
  done < "$SENSOR_MAP"
  return 1
}

# ── Restore kernel control ────────────────────────────────────────────────
restore_auto() {
  if [ -s "$SAVED" ]; then
    while IFS="$TAB" read -r _ep _ev; do
      [ -n "$_ep" ] && [ "$_ep" != "-" ] || continue
      case "$_ev" in ''|*[!0-9]*) _ev=2 ;; esac
      printf '%s\n' "$_ev" > "$_ep" 2>/dev/null
    done < "$SAVED"
  fi
  rm -f "$SAVED" "$STATE"
  return 0
}

# ── The guard: enforces expiry and the crit failsafe ─────────────────────
# Runs detached. The trap is what makes "the guard died" safe rather than
# leaving the fan pinned: any exit path restores kernel control.
# Runs on every exit path of the guard, including SIGTERM. Restores kernel
# control ONLY if this guard still owns the fan: a guard stopped by a newer
# `set` must not hand the fan back a moment after the user asked for a
# different speed. Signals are delivered between commands, so that delay is
# entirely realistic. Idempotent — it can run twice (TERM then EXIT).
guard_exit() {
  _ge_cur=$(state_field gen 2>/dev/null)
  if [ ! -f "$STATE" ] || [ "$_ge_cur" = "$GUARD_GEN" ]; then
    restore_auto
    rm -f "$GUARD_PID"
  fi
  exit 0
}

do_guard() {
  _expiry="$1"
  GUARD_GEN="$2"
  case "$_expiry" in ''|*[!0-9]*) exit 1 ;; esac
  printf '%s\n' "$$" > "$GUARD_PID"
  trap guard_exit INT TERM HUP EXIT

  # Poll in short steps. The loop body is what reacts to crit_temp, and a long
  # sleep would both delay that failsafe and defer signal handling until it
  # returned — a 15s sleep meant up to 15s before a stop took effect.
  while :; do
    [ -f "$STATE" ] || break                       # someone ran `auto`
    [ "$(state_field gen)" = "$GUARD_GEN" ] || exit 0   # superseded
    [ "$(now)" -ge "$_expiry" ] && break            # override expired
    if any_sensor_critical; then
      logger -t temp-history -p daemon.warning \
        "fan override cancelled: a sensor reached crit_temp — returning control to the kernel"
      break
    fi
    sleep 3
  done
  exit 0
}

# ── Actions ───────────────────────────────────────────────────────────────
do_set() {
  _pct="$1"; _mins="$2"

  control_enabled || {
    printf '{"status":"error","error":"fan control disabled (uci fan_control=0)"}\n'; return 0; }

  case "$_pct" in ''|*[!0-9]*) printf '{"status":"error","error":"percent must be 0-100"}\n'; return 0 ;; esac
  [ "$_pct" -le 100 ] || { printf '{"status":"error","error":"percent must be 0-100"}\n'; return 0; }

  _min=$(uci_num fan_min_percent "$DEFAULT_MIN_PCT")
  [ "$_min" -gt 100 ] && _min=100
  # Floor, not a rejection: asking for less than the floor gets the floor,
  # so the UI cannot be used to stall the fan.
  [ "$_pct" -lt "$_min" ] && _pct="$_min"

  case "$_mins" in ''|*[!0-9]*) _mins=$(uci_num fan_override_minutes "$DEFAULT_MINUTES") ;; esac
  [ "$_mins" -lt 1 ]    && _mins=1
  [ "$_mins" -gt 1440 ] && _mins=1440

  if any_sensor_critical; then
    printf '{"status":"error","error":"refused: a sensor is at or above crit_temp"}\n'
    return 0
  fi

  _n=$(controllable_count)
  [ "${_n:-0}" -gt 0 ] || {
    printf '{"status":"error","error":"no controllable fan on this device"}\n'; return 0; }

  # Stop any running guard before changing state, so its EXIT trap cannot
  # restore-over the new setting.
  stop_guard

  _raw=$(( _pct * PWM_MAX / 100 ))
  [ "$_raw" -gt "$PWM_MAX" ] && _raw=$PWM_MAX

  # Record what we are about to overwrite, so `auto` puts back exactly what
  # the driver had rather than assuming a value.
  #
  # The PWM VALUE is saved unconditionally. Not every driver has a pwmN_enable
  # — the mainline pwm-fan does not — and on those the saved pwm is the only
  # thing restore_auto can put back. Saving only pwm_enable made "back to
  # automatic" a silent no-op on exactly that hardware, leaving the fan pinned
  # wherever the override left it.
  #
  # Order matters: pwm is written to SAVED first so restore_auto puts the
  # speed back BEFORE handing control to the governor. Writing pwm after
  # pwm_enable=2 would either be rejected or flip the driver straight back
  # into manual mode.
  : > "$SAVED"
  fan_rows | while IFS="$TAB" read -r t n p e; do
    [ "$p" != "-" ] || continue

    _origp=$(read_file "$p")
    case "$_origp" in
      ''|*[!0-9]*) : ;;
      *) printf '%s\t%s\n' "$p" "$_origp" >> "$SAVED" ;;
    esac

    if [ "$e" != "-" ]; then
      _orig=$(read_file "$e")
      case "$_orig" in ''|*[!0-9]*) _orig=2 ;; esac
      printf '%s\t%s\n' "$e" "$_orig" >> "$SAVED"
      printf '1\n' > "$e" 2>/dev/null      # 1 = manual control
    fi
    printf '%s\n' "$_raw" > "$p" 2>/dev/null
  done

  _exp=$(( $(now) + _mins * 60 ))
  _gen="$(now).$$"
  {
    printf 'expiry=%s\n' "$_exp"
    printf 'percent=%s\n' "$_pct"
    printf 'started=%s\n' "$(now)"
    printf 'gen=%s\n' "$_gen"
  } > "$STATE"

  start_guard "$_exp" "$_gen"

  printf '{"status":"ok","percent":%s,"pwm":%s,"minutes":%s,"expires":%s}\n' \
    "$_pct" "$_raw" "$_mins" "$_exp"
}

stop_guard() {
  _gp=$(guard_pid)
  [ -n "$_gp" ] || { rm -f "$GUARD_PID"; return 0; }
  kill "$_gp" 2>/dev/null
  # Wait for it to actually go. The guard handles signals between commands, so
  # this can take up to one poll interval.
  _w=0
  while [ "$_w" -lt 50 ] && guard_alive "$_gp"; do
    _w=$(( _w + 1 ))
    sleep 0.1 2>/dev/null || sleep 1
  done
  guard_alive "$_gp" && kill -9 "$_gp" 2>/dev/null
  rm -f "$GUARD_PID"
}

start_guard() {
  _e="$1"; _g="$2"
  # Detach from the caller's stdout: rpcd waits on its plugin's stdout, so a
  # child inheriting it would hang the ubus call for the whole override.
  # Redirecting all three descriptors is what actually achieves that; setsid
  # is only used to also leave the process group where it exists.
  if command -v setsid >/dev/null 2>&1; then
    setsid "$0" guard "$_e" "$_g" >/dev/null 2>&1 </dev/null &
  else
    "$0" guard "$_e" "$_g" >/dev/null 2>&1 </dev/null &
  fi
  # The GUARD writes the pid file, not this function. Writing $! here as well
  # created two writers for one file: setsid forks, so $! is the wrapper and
  # not the guard, and this write could land AFTER the guard had already
  # recorded its own $$ — leaving a pid that was never the guard. The startup
  # window where no pid file exists yet is covered by the `started=` grace
  # period in do_enforce instead.
}

do_auto() {
  stop_guard
  restore_auto
  printf '{"status":"ok","mode":"auto"}\n'
}

# Backstop: called every 15 minutes by the collector. Handles the case where
# the guard was killed outright (OOM, kill -9) and its trap never ran.
do_enforce() {
  [ -f "$STATE" ] || return 0
  _exp=""; _started=0
  while IFS='=' read -r _k _v; do
    case "$_k" in
      expiry)  _exp="$_v" ;;
      started) _started="$_v" ;;
    esac
  done < "$STATE"
  case "$_exp"     in ''|*[!0-9]*) _exp=0 ;; esac
  case "$_started" in ''|*[!0-9]*) _started=0 ;; esac

  _alive=0
  _gp=$(guard_pid)
  [ -n "$_gp" ] && guard_alive "$_gp" && _alive=1

  # Grace period: never call a guard dead within 60s of the override being
  # issued, so a slow start cannot look like a crash.
  _fresh=0
  [ "$(( $(now) - _started ))" -lt 60 ] && _fresh=1
  [ "$_fresh" = "1" ] && _alive=1

  if [ "$(now)" -ge "$_exp" ] || [ "$_alive" = "0" ] || any_sensor_critical; then
    [ "$_alive" = "0" ] && [ "$(now)" -lt "$_exp" ] && \
      logger -t temp-history -p daemon.warning \
        "fan override guard is gone before expiry — restoring kernel control"
    stop_guard
    restore_auto
  fi
}

# ── External fan controllers ────────────────────────────────────────
# GL.iNet firmware ships gl_fan: a userspace daemon that polls a thermal zone
# once a second and drives this same pwm.
#
#   /usr/bin/gl_fan -T /sys/.../thermal_zone0/temp -D 1000 -t 50
#
# It matters because such a daemon can be the ONLY controller in normal
# operation: on at least one board the thermal zone's trip points start at
# 85°C, so the kernel governor does not touch the fan below that at all. A
# manual override then holds only until the daemon next changes state, and the
# UI should say so instead of blaming a governor that is not involved.
#
# It is detected and REPORTED, never stopped. Below 85°C it is this router's
# entire thermal protection; taking it out for the duration of an override
# would buy exclusive control at a price not worth paying.
#
# One grep over /proc rather than a fork per process. grep can match its own
# cmdline, so candidates are re-checked.
external_controller() {   # prints:  name <TAB> threshold   (threshold may be "")
  _ec_hits=$(grep -l gl_fan "$PROC_DIR"/[0-9]*/cmdline 2>/dev/null)
  [ -n "$_ec_hits" ] || return 0

  for _ec_f in $_ec_hits; do
    _ec_cl=$(tr '\0' ' ' < "$_ec_f" 2>/dev/null)
    case "$_ec_cl" in
      *grep*)   continue ;;   # the search process itself
      *gl_fan*) ;;
      *)        continue ;;
    esac

    _ec_t=""
    case "$_ec_cl" in
      *" -t "*) _ec_t="${_ec_cl##* -t }"; _ec_t="${_ec_t%% *}" ;;
    esac
    # The daemon's own config is the fallback: an init script may start it
    # without an explicit -t.
    case "$_ec_t" in
      ''|*[!0-9]*) _ec_t=$(uci -q get glfan.globals.temperature 2>/dev/null) ;;
    esac
    case "$_ec_t" in ''|*[!0-9]*) _ec_t="" ;; esac

    printf 'gl_fan\t%s\n' "$_ec_t"
    return 0
  done
  return 0
}

do_status() {
  _min=$(uci_num fan_min_percent "$DEFAULT_MIN_PCT")
  _defmins=$(uci_num fan_override_minutes "$DEFAULT_MINUTES")
  _enabled=0; control_enabled && _enabled=1
  _nctl=$(controllable_count); case "$_nctl" in ''|*[!0-9]*) _nctl=0 ;; esac

  _mode="auto"; _exp=0; _pct=0
  if [ -f "$STATE" ]; then
    while IFS='=' read -r _k _v; do
      case "$_k" in expiry) _exp="$_v" ;; percent) _pct="$_v" ;; esac
    done < "$STATE"
    case "$_exp" in ''|*[!0-9]*) _exp=0 ;; esac
    case "$_pct" in ''|*[!0-9]*) _pct=0 ;; esac
    [ "$(now)" -lt "$_exp" ] && _mode="manual"
  fi
  _remain=0
  [ "$_mode" = "manual" ] && _remain=$(( _exp - $(now) ))

  _ext="null"
  _extline=$(external_controller)
  if [ -n "$_extline" ]; then
    _extname="${_extline%%	*}"
    _extthr="${_extline#*	}"
    case "$_extthr" in
      ''|*[!0-9]*) _ext=$(printf '{"name":"%s","threshold":null}' "$_extname") ;;
      *)           _ext=$(printf '{"name":"%s","threshold":%s}' "$_extname" "$_extthr") ;;
    esac
  fi

  printf '{"controllable":%s,"control_enabled":%s,"mode":"%s","percent":%s,"expires":%s,"remaining":%s,"min_percent":%s,"default_minutes":%s,"external":%s,"fans":[' \
    "$_nctl" "$_enabled" "$_mode" "$_pct" "$_exp" "$_remain" "$_min" "$_defmins" "$_ext"

  fan_rows | awk -F'\t' -v pmax="$PWM_MAX" '
  function esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
  function slurp(p,   v, r) { v=""; if (p!="-" && (getline r < p) > 0) v=r; close(p); return v }
  {
    rpm = ($1=="-") ? "null" : slurp($1)
    if (rpm == "") rpm = "null"
    pwm = ($3=="-") ? "null" : slurp($3)
    if (pwm == "") pwm = "null"
    pct = (pwm=="null") ? "null" : sprintf("%d", (pwm*100+pmax/2)/pmax)
    en  = ($4=="-") ? "null" : slurp($4)
    if (en == "") en = "null"
    # No pwmN_enable means the driver cannot be disengaged from the kernel
    # thermal governor at all: a manual speed is written straight to pwm and
    # the governor may re-assert its own value at any time. The UI says so
    # rather than implying the setting is permanent.
    printf "%s{\"name\":\"%s\",\"rpm\":%s,\"pwm\":%s,\"percent\":%s,\"pwm_enable\":%s,\"has_enable\":%s,\"controllable\":%s}",
           (NR>1 ? "," : ""), esc($2), rpm, pwm, pct, en,
           ($4=="-" ? "false" : "true"), ($3=="-" ? "false" : "true")
  }'
  printf ']}\n'
}

case "$1" in
  status)  do_status ;;
  set)     do_set "$2" "$3" ;;
  auto)    do_auto ;;
  enforce) do_enforce ;;
  guard)   do_guard "$2" "$3" ;;
  *)
    printf 'usage: %s {status|set <percent> [minutes]|auto|enforce}\n' "${0##*/}" >&2
    exit 1
    ;;
esac
exit 0
